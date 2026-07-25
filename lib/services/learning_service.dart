import 'package:sqflite/sqflite.dart';
import '../models/user_word_record.dart';
import 'database_service.dart';

class DailyStats {
  final int wrongWordCount;
  final int dueReviewCount;
  final int todayLearnedCount;
  final int todayReviewedCount;

  DailyStats({
    required this.wrongWordCount,
    required this.dueReviewCount,
    required this.todayLearnedCount,
    required this.todayReviewedCount,
  });
}

class LearningService {
  static String _todayStr() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  // ─── 每日统计 ──────────────────────────────────────

  static Future<DailyStats> getDailyStats() async {
    final db = await DatabaseService.database;
    final today = _todayStr();

    // 今日错词本中待处理的词数
    final wrongCount =
        Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM wrong_words WHERE scheduled_date <= ?',
            [today],
          ),
        ) ??
        0;

    // 到期正常复习词数（不含已掌握，且不在错词本中）
    final dueCount =
        Sqflite.firstIntValue(
          await db.rawQuery(
            '''
        SELECT COUNT(*) FROM user_word_records r
        WHERE r.is_mastered = 0
          AND r.next_review_date IS NOT NULL
          AND r.next_review_date <= ?
          AND r.word NOT IN (
            SELECT w.word FROM wrong_words w WHERE w.scheduled_date <= ?
          )
      ''',
            [today, today],
          ),
        ) ??
        0;

    // 今日已学习数量（created_at 为今天）
    final learnedCount =
        Sqflite.firstIntValue(
          await db.rawQuery(
            "SELECT COUNT(*) FROM user_word_records WHERE created_at >= ? || 'T00:00:00'",
            [today],
          ),
        ) ??
        0;

    // 今日已复习数量（last_reviewed_at 为今天）
    final reviewedCount =
        Sqflite.firstIntValue(
          await db.rawQuery(
            "SELECT COUNT(*) FROM user_word_records WHERE last_reviewed_at >= ? || 'T00:00:00'",
            [today],
          ),
        ) ??
        0;

    return DailyStats(
      wrongWordCount: wrongCount,
      dueReviewCount: dueCount,
      todayLearnedCount: learnedCount,
      todayReviewedCount: reviewedCount,
    );
  }

  // ─── 获取待处理队列（按优先级） ──────────────────

  /// 获取今日错词本中的词（最高优先级）
  static Future<List<String>> getTodayWrongWords() async {
    final db = await DatabaseService.database;
    final today = _todayStr();
    final maps = await db.rawQuery(
      '''
      SELECT w.word FROM wrong_words w
      WHERE w.scheduled_date <= ?
      ORDER BY w.created_at ASC
    ''',
      [today],
    );
    return maps.map((m) => m['word'] as String).toList();
  }

  /// 获取到期正常复习词（次高优先级）
  static Future<List<String>> getDueReviews() async {
    final db = await DatabaseService.database;
    final today = _todayStr();
    final maps = await db.rawQuery(
      '''
      SELECT r.word FROM user_word_records r
      WHERE r.is_mastered = 0
        AND r.next_review_date IS NOT NULL
        AND r.next_review_date <= ?
        AND r.word NOT IN (
          SELECT w.word FROM wrong_words w WHERE w.scheduled_date <= ?
        )
      ORDER BY r.next_review_date ASC
    ''',
      [today, today],
    );
    return maps.map((m) => m['word'] as String).toList();
  }

  /// 获取可学新词（最低优先级）：从词书中取未在 user_word_records 中的词
  static Future<List<String>> getNewWords(int bookId, {int limit = 10}) async {
    final db = await DatabaseService.database;
    final maps = await db.rawQuery(
      '''
      SELECT e.word FROM word_book_entries e
      WHERE e.book_id = ?
        AND e.word NOT IN (
          SELECT r.word FROM user_word_records r
        )
      ORDER BY e.id ASC
      LIMIT ?
    ''',
      [bookId, limit],
    );
    return maps.map((m) => m['word'] as String).toList();
  }

  /// 检查是否还有未完成的错词/复习任务
  static Future<bool> hasPendingTasks() async {
    final stats = await getDailyStats();
    return stats.wrongWordCount > 0 || stats.dueReviewCount > 0;
  }

  /// 获取所有待复习词（已合并优先级）：错词在前，正常到期在后
  static Future<List<String>> getAllDueWords() async {
    final wrong = await getTodayWrongWords();
    final due = await getDueReviews();
    return [...wrong, ...due];
  }

  /// 将单词标记为已掌握
  static Future<void> markAsMastered(String word) async {
    final db = await DatabaseService.database;
    final cleaned = word.trim().toLowerCase();
    final now = DateTime.now().toIso8601String();

    await db.update(
      'user_word_records',
      {'is_mastered': 1, 'last_reviewed_at': now},
      where: 'word = ?',
      whereArgs: [cleaned],
    );

    // 从错词本中移除
    await db.delete('wrong_words', where: 'word = ?', whereArgs: [cleaned]);
  }

  // ─── 第一遍学习流程 ──────────────────────────────

  /// 处理第一遍完成：创建学习记录，stage=0，明天必考
  static Future<void> processFirstPass(String word) async {
    final db = await DatabaseService.database;
    final now = DateTime.now().toIso8601String();

    final nextDate = UserWordRecord(
      word: word,
      stage: 0,
    ).computeNextReviewDate();

    await db.insert('user_word_records', {
      'word': word.trim().toLowerCase(),
      'stage': 0,
      'is_weak': 0,
      'is_mastered': 0,
      'next_review_date': nextDate,
      'last_reviewed_at': now,
      'review_count': 0,
      'created_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ─── 第二遍学习流程 ──────────────────────────────

  /// 处理【完全忘记】：不进入复习队列，退回第一遍
  static Future<void> processSecondPassForgot(String word) async {
    final db = await DatabaseService.database;
    // 删除已有记录（重置）
    await db.delete(
      'user_word_records',
      where: 'word = ?',
      whereArgs: [word.trim().toLowerCase()],
    );
    // 同时从错词本中移除
    await db.delete(
      'wrong_words',
      where: 'word = ?',
      whereArgs: [word.trim().toLowerCase()],
    );
  }

  /// 处理【回忆吃力/模糊】：stage=0, isWeak=1, 明天必考
  static Future<void> processSecondPassHard(String word) async {
    final db = await DatabaseService.database;
    final now = DateTime.now().toIso8601String();
    final cleaned = word.trim().toLowerCase();
    final nextDate = UserWordRecord(
      word: cleaned,
      stage: 0,
    ).computeNextReviewDate();

    // 使用 replace 以覆盖第一遍创建的记录
    await db.insert('user_word_records', {
      'word': cleaned,
      'stage': 0,
      'is_weak': 1,
      'is_mastered': 0,
      'next_review_date': nextDate,
      'last_reviewed_at': now,
      'review_count': 0,
      'created_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 处理【轻松记住】：stage=0, isWeak=0, 明天必考
  static Future<void> processSecondPassEasy(String word) async {
    final db = await DatabaseService.database;
    final now = DateTime.now().toIso8601String();
    final cleaned = word.trim().toLowerCase();
    final nextDate = UserWordRecord(
      word: cleaned,
      stage: 0,
    ).computeNextReviewDate();

    // 使用 replace 以覆盖第一遍创建的记录
    await db.insert('user_word_records', {
      'word': cleaned,
      'stage': 0,
      'is_weak': 0,
      'is_mastered': 0,
      'next_review_date': nextDate,
      'last_reviewed_at': now,
      'review_count': 0,
      'created_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ─── 复习流程 ──────────────────────────────────

  /// 获取指定单词的学习记录
  static Future<UserWordRecord?> getRecord(String word) async {
    final db = await DatabaseService.database;
    final maps = await db.query(
      'user_word_records',
      where: 'word = ?',
      whereArgs: [word.trim().toLowerCase()],
    );
    if (maps.isEmpty) return null;
    return UserWordRecord.fromMap(maps.first);
  }

  /// 复习评级【轻松记住】
  static Future<void> processReviewEasy(String word) async {
    final db = await DatabaseService.database;
    final cleaned = word.trim().toLowerCase();
    final record = await getRecord(cleaned);
    if (record == null) return;

    final now = DateTime.now().toIso8601String();

    if (record.isWeak) {
      // A. 有薄弱标记 → 移除标记，梯级不变
      final nextDate = UserWordRecord(
        word: cleaned,
        stage: record.stage,
      ).computeNextReviewDate();

      await db.update(
        'user_word_records',
        {
          'is_weak': 0,
          'next_review_date': nextDate,
          'last_reviewed_at': now,
          'review_count': record.reviewCount + 1,
        },
        where: 'word = ?',
        whereArgs: [cleaned],
      );
    } else {
      // B. 正常标记 → 梯级+1
      final newStage = record.stage + 1;

      if (newStage > 5) {
        // 梯级5 + 轻松记住 → 已掌握
        await db.update(
          'user_word_records',
          {
            'stage': 5,
            'is_mastered': 1,
            'last_reviewed_at': now,
            'review_count': record.reviewCount + 1,
          },
          where: 'word = ?',
          whereArgs: [cleaned],
        );
      } else {
        final nextDate = UserWordRecord(
          word: cleaned,
          stage: newStage,
        ).computeNextReviewDate();

        await db.update(
          'user_word_records',
          {
            'stage': newStage,
            'next_review_date': nextDate,
            'last_reviewed_at': now,
            'review_count': record.reviewCount + 1,
          },
          where: 'word = ?',
          whereArgs: [cleaned],
        );
      }
    }

    // 从错词本中移除（如果存在）
    await db.delete('wrong_words', where: 'word = ?', whereArgs: [cleaned]);
  }

  /// 复习评级【回忆吃力/模糊】
  static Future<void> processReviewHard(String word) async {
    final db = await DatabaseService.database;
    final cleaned = word.trim().toLowerCase();
    final record = await getRecord(cleaned);
    if (record == null) return;

    final now = DateTime.now().toIso8601String();
    final today = _todayStr();

    // 梯级不变，强制加入错词本
    await db.update(
      'user_word_records',
      {'last_reviewed_at': now, 'review_count': record.reviewCount + 1},
      where: 'word = ?',
      whereArgs: [cleaned],
    );

    // 强制加入错词本，明天必须出现
    try {
      await db.insert('wrong_words', {
        'word': cleaned,
        'scheduled_date': today,
        'created_at': now,
      });
    } catch (e) {
      // 已存在则更新日期
      await db.update(
        'wrong_words',
        {'scheduled_date': today},
        where: 'word = ?',
        whereArgs: [cleaned],
      );
    }
  }

  /// 复习评级【忘记/错误】
  static Future<void> processReviewForgot(String word) async {
    final db = await DatabaseService.database;
    final cleaned = word.trim().toLowerCase();
    final record = await getRecord(cleaned);
    if (record == null) return;

    final now = DateTime.now().toIso8601String();
    final today = _todayStr();

    // 梯级回退1级（边界保护：不低于0）
    final newStage = record.stage > 0 ? record.stage - 1 : 0;
    final nextDate = UserWordRecord(
      word: cleaned,
      stage: newStage,
    ).computeNextReviewDate();

    await db.update(
      'user_word_records',
      {
        'stage': newStage,
        'next_review_date': nextDate,
        'last_reviewed_at': now,
        'review_count': record.reviewCount + 1,
      },
      where: 'word = ?',
      whereArgs: [cleaned],
    );

    // 强制加入错词本
    try {
      await db.insert('wrong_words', {
        'word': cleaned,
        'scheduled_date': today,
        'created_at': now,
      });
    } catch (e) {
      await db.update(
        'wrong_words',
        {'scheduled_date': today},
        where: 'word = ?',
        whereArgs: [cleaned],
      );
    }
  }
}
