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

    final wrongCount =
        Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM wrong_words WHERE scheduled_date <= ?',
            [today],
          ),
        ) ??
        0;

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

    final learnedCount =
        Sqflite.firstIntValue(
          await db.rawQuery(
            "SELECT COUNT(*) FROM user_word_records WHERE created_at >= ? || 'T00:00:00'",
            [today],
          ),
        ) ??
        0;

    final reviewedCount =
        Sqflite.firstIntValue(
          await db.rawQuery(
            "SELECT COUNT(*) FROM user_word_records WHERE last_reviewed_at >= ? || 'T00:00:00' AND created_at < ? || 'T00:00:00'",
            [today, today],
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

  static Future<bool> hasPendingTasks() async {
    final stats = await getDailyStats();
    return stats.wrongWordCount > 0 || stats.dueReviewCount > 0;
  }

  static Future<List<String>> getAllDueWords() async {
    final wrong = await getTodayWrongWords();
    final due = await getDueReviews();
    return [...wrong, ...due];
  }

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

    await db.delete('wrong_words', where: 'word = ?', whereArgs: [cleaned]);
  }

  // ─── 批量保存学习/复习结果 ─────────────────────

  /// 批量保存学习结果（学习/复习完成后一次性写入）
  /// results: word → result ("easy" | "hard" | "forgot" | "mastered")
  ///
  /// 区分新增（学习）和更新（复习）：
  /// - 已存在的记录（复习）：使用 UPDATE，保留 created_at，递增 review_count
  /// - 不存在的记录（学习）：使用 INSERT，创建完整新行
  static Future<void> saveLearningBatchResults(
    Map<String, String> results,
  ) async {
    final db = await DatabaseService.database;
    final now = DateTime.now().toIso8601String();

    await db.transaction((txn) async {
      for (final entry in results.entries) {
        final word = entry.key.trim().toLowerCase();
        final result = entry.value;

        if (result == 'mastered') {
          await txn.update(
            'user_word_records',
            {'is_mastered': 1, 'last_reviewed_at': now},
            where: 'word = ?',
            whereArgs: [word],
          );
          await txn.delete('wrong_words', where: 'word = ?', whereArgs: [word]);
        } else if (result == 'forgot') {
          await txn.delete(
            'user_word_records',
            where: 'word = ?',
            whereArgs: [word],
          );
          await txn.delete('wrong_words', where: 'word = ?', whereArgs: [word]);
        } else {
          final isWeak = result == 'hard' ? 1 : 0;
          final nextDate = UserWordRecord(
            word: word,
            stage: 0,
          ).computeNextReviewDate();

          // 查询是否已存在记录（区分新增学习 vs 复习）
          final existing = await txn.query(
            'user_word_records',
            columns: ['review_count', 'created_at'],
            where: 'word = ?',
            whereArgs: [word],
          );

          if (existing.isNotEmpty) {
            // 已有记录 → 复习场景：更新而非替换，保留 created_at
            final old = existing.first;
            final oldReviewCount = (old['review_count'] as int?) ?? 0;

            await txn.update(
              'user_word_records',
              {
                'stage': 0,
                'is_weak': isWeak,
                'is_mastered': 0,
                'next_review_date': nextDate,
                'last_reviewed_at': now,
                'review_count': oldReviewCount + 1,
              },
              where: 'word = ?',
              whereArgs: [word],
            );
          } else {
            // 新记录 → 学习场景：插入完整新行
            await txn.insert('user_word_records', {
              'word': word,
              'stage': 0,
              'is_weak': isWeak,
              'is_mastered': 0,
              'next_review_date': nextDate,
              'last_reviewed_at': now,
              'review_count': 0,
              'created_at': now,
            });
          }
        }
      }
    });
  }

  // ─── 第一遍学习流程 ──────────────────────────────

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

  static Future<void> processSecondPassForgot(String word) async {
    final db = await DatabaseService.database;
    await db.delete(
      'user_word_records',
      where: 'word = ?',
      whereArgs: [word.trim().toLowerCase()],
    );
    await db.delete(
      'wrong_words',
      where: 'word = ?',
      whereArgs: [word.trim().toLowerCase()],
    );
  }

  static Future<void> processSecondPassHard(String word) async {
    final db = await DatabaseService.database;
    final now = DateTime.now().toIso8601String();
    final cleaned = word.trim().toLowerCase();
    final nextDate = UserWordRecord(
      word: cleaned,
      stage: 0,
    ).computeNextReviewDate();

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

  static Future<void> processSecondPassEasy(String word) async {
    final db = await DatabaseService.database;
    final now = DateTime.now().toIso8601String();
    final cleaned = word.trim().toLowerCase();
    final nextDate = UserWordRecord(
      word: cleaned,
      stage: 0,
    ).computeNextReviewDate();

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

  static Future<void> processReviewEasy(String word) async {
    final db = await DatabaseService.database;
    final cleaned = word.trim().toLowerCase();
    final record = await getRecord(cleaned);
    if (record == null) return;

    final now = DateTime.now().toIso8601String();

    if (record.isWeak) {
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
      final newStage = record.stage + 1;

      if (newStage > 5) {
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

    await db.delete('wrong_words', where: 'word = ?', whereArgs: [cleaned]);
  }

  static Future<void> processReviewHard(String word) async {
    final db = await DatabaseService.database;
    final cleaned = word.trim().toLowerCase();
    final record = await getRecord(cleaned);
    if (record == null) return;

    final now = DateTime.now().toIso8601String();
    final today = _todayStr();

    await db.update(
      'user_word_records',
      {'last_reviewed_at': now, 'review_count': record.reviewCount + 1},
      where: 'word = ?',
      whereArgs: [cleaned],
    );

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

  static Future<void> processReviewForgot(String word) async {
    final db = await DatabaseService.database;
    final cleaned = word.trim().toLowerCase();
    final record = await getRecord(cleaned);
    if (record == null) return;

    final now = DateTime.now().toIso8601String();
    final today = _todayStr();

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
