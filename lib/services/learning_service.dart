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

  // ─── 全局随机干扰项池 ──────────────────────────

  /// 从已学单词（user_word_records）中随机取 count 个词作为干扰项池，
  /// 排除 excludeWords 中的词。返回 Map<word, firstMeaning>。
  /// 用于选择题阶段生成干扰项，保证干扰项是用户见过的词。
  static Future<Map<String, String>> getRandomDistractors({
    required List<String> excludeWords,
    int count = 10,
  }) async {
    final db = await DatabaseService.database;
    final placeholders = excludeWords.map((_) => '?').join(',');
    final maps = await db.rawQuery(
      '''
      SELECT r.word FROM user_word_records r
      WHERE r.word NOT IN ($placeholders)
      ORDER BY RANDOM()
      LIMIT ?
    ''',
      [...excludeWords, count],
    );

    final result = <String, String>{};
    for (final m in maps) {
      final word = m['word'] as String;
      // 释义后续由页面异步加载，此处只返回 word 列表
      result[word] = '';
    }
    return result;
  }

  // ─── 打卡与统计数据 ──────────────────────────

  /// 记录/更新今日活动
  static Future<void> recordDailyActivity({
    int wordsLearned = 0,
    int wordsReviewed = 0,
    int correctCount = 0,
    int wrongCount = 0,
    bool completed = false,
  }) async {
    final db = await DatabaseService.database;
    final today = _todayStr();

    // 先查询今日是否存在记录
    final existing = await db.query(
      'daily_activity',
      columns: [
        'words_learned',
        'words_reviewed',
        'correct_count',
        'wrong_count',
        'completed',
      ],
      where: 'date = ?',
      whereArgs: [today],
    );

    if (existing.isNotEmpty) {
      final row = existing.first;
      await db.update(
        'daily_activity',
        {
          'words_learned': (row['words_learned'] as int?)! + wordsLearned,
          'words_reviewed': (row['words_reviewed'] as int?)! + wordsReviewed,
          'correct_count': (row['correct_count'] as int?)! + correctCount,
          'wrong_count': (row['wrong_count'] as int?)! + wrongCount,
          'completed': completed ? 1 : (row['completed'] as int?)!,
        },
        where: 'date = ?',
        whereArgs: [today],
      );
    } else {
      await db.insert('daily_activity', {
        'date': today,
        'words_learned': wordsLearned,
        'words_reviewed': wordsReviewed,
        'correct_count': correctCount,
        'wrong_count': wrongCount,
        'completed': completed ? 1 : 0,
      });
    }
  }

  /// 获取连续打卡天数（从昨天往前数，连续 completed=1 的天数）
  static Future<int> getStreak() async {
    final db = await DatabaseService.database;
    final now = DateTime.now();
    final today = _todayStr();

    // 检查今天是否已完成
    final todayRow = await db.query(
      'daily_activity',
      columns: ['completed'],
      where: 'date = ?',
      whereArgs: [today],
    );

    int streak = 0;
    // 如果今天已完成，从今天开始；否则从昨天开始
    final startDay = (todayRow.isNotEmpty && todayRow.first['completed'] == 1)
        ? DateTime(now.year, now.month, now.day)
        : DateTime(
            now.year,
            now.month,
            now.day,
          ).subtract(const Duration(days: 1));

    for (int i = 0; i < 365; i++) {
      final date = startDay.subtract(Duration(days: i));
      final dateStr =
          '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
      final row = await db.query(
        'daily_activity',
        columns: ['completed'],
        where: 'date = ? AND completed = 1',
        whereArgs: [dateStr],
      );
      if (row.isNotEmpty) {
        streak++;
      } else {
        break;
      }
    }
    return streak;
  }

  /// 获取最近7天的每日复习数（用于图表展示）
  static Future<List<Map<String, dynamic>>> getWeeklyActivity() async {
    final db = await DatabaseService.database;
    final now = DateTime.now();
    final results = <Map<String, dynamic>>[];

    for (int i = 6; i >= 0; i--) {
      final date = now.subtract(Duration(days: i));
      final dateStr =
          '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

      final row = await db.query(
        'daily_activity',
        columns: [
          'words_learned',
          'words_reviewed',
          'correct_count',
          'wrong_count',
          'completed',
        ],
        where: 'date = ?',
        whereArgs: [dateStr],
      );

      if (row.isNotEmpty) {
        results.add({
          'date': dateStr,
          'words_learned': row.first['words_learned'] ?? 0,
          'words_reviewed': row.first['words_reviewed'] ?? 0,
          'correct_count': row.first['correct_count'] ?? 0,
          'wrong_count': row.first['wrong_count'] ?? 0,
          'completed': row.first['completed'] ?? 0,
        });
      } else {
        results.add({
          'date': dateStr,
          'words_learned': 0,
          'words_reviewed': 0,
          'correct_count': 0,
          'wrong_count': 0,
          'completed': 0,
        });
      }
    }
    return results;
  }

  // ─── 复习计划（所有未掌握的已安排复习的单词） ─────

  /// 获取所有未掌握且有复习计划的单词，按复习时间由近及远排序
  /// 返回列表，每个元素为 {word, next_review_date}
  static Future<List<Map<String, dynamic>>> getReviewPlan() async {
    final db = await DatabaseService.database;
    final maps = await db.rawQuery('''
      SELECT r.word, r.next_review_date FROM user_word_records r
      WHERE r.is_mastered = 0
        AND r.next_review_date IS NOT NULL
      ORDER BY r.next_review_date ASC
      ''');
    return maps
        .map(
          (m) => {
            'word': m['word'] as String,
            'next_review_date': m['next_review_date'] as String,
          },
        )
        .toList();
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
  ///
  /// 改进：对 easy/hard 不再硬编码 stage=0，而是参考原 stage 做递进或降级，
  ///       与 processReviewEasy/processReviewForgot 逻辑对齐。
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
          // 忘记 → 完全删除记录，从头学起
          await txn.delete(
            'user_word_records',
            where: 'word = ?',
            whereArgs: [word],
          );
          await txn.delete('wrong_words', where: 'word = ?', whereArgs: [word]);
        } else {
          final isWeak = result == 'hard' ? 1 : 0;

          // 查询是否已存在记录（区分新增学习 vs 复习）
          final existing = await txn.query(
            'user_word_records',
            columns: ['review_count', 'created_at', 'stage', 'is_weak'],
            where: 'word = ?',
            whereArgs: [word],
          );

          if (existing.isNotEmpty) {
            // ── 复习场景 ──
            final old = existing.first;
            final oldReviewCount = (old['review_count'] as int?) ?? 0;
            final oldStage = (old['stage'] as int?) ?? 0;
            final oldIsWeak = (old['is_weak'] as int?) == 1;

            int newStage;
            if (result == 'hard') {
              // hard: 降一级（最低0）
              newStage = oldStage > 0 ? oldStage - 1 : 0;
            } else {
              // easy: 递进
              if (oldIsWeak) {
                // 之前标记为 weak，先清除 weak 标记，stage 不变
                newStage = oldStage;
              } else {
                newStage = oldStage + 1;
              }
            }

            final nextDate = UserWordRecord(
              word: word,
              stage: newStage,
            ).computeNextReviewDate();

            final updateFields = <String, dynamic>{
              'stage': newStage,
              'is_weak': isWeak,
              'is_mastered': 0,
              'next_review_date': nextDate,
              'last_reviewed_at': now,
              'review_count': oldReviewCount + 1,
            };

            // 如果 easy 且加完 stage > 5，标记 mastered
            if (result == 'easy' && newStage > 5) {
              updateFields['is_mastered'] = 1;
            }

            await txn.update(
              'user_word_records',
              updateFields,
              where: 'word = ?',
              whereArgs: [word],
            );

            // hard 或 easy 但未掌握：如已有 wrong_words 记录则删除
            if (result == 'easy' && newStage <= 5) {
              await txn.delete(
                'wrong_words',
                where: 'word = ?',
                whereArgs: [word],
              );
            }
          } else {
            // ── 新记录（学习场景） ──
            // 新词首次学习：不管 easy/hard 都从 stage=0 开始
            final nextDate = UserWordRecord(
              word: word,
              stage: 0,
            ).computeNextReviewDate();

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

    // hard: 降一级（最低0），重新安排复习
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

    // 加入 today 的错词队列，稍后重做
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
