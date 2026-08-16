import 'package:sqflite/sqflite.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

/// 待复习单词分组（按词书）
class DueWordsGroup {
  /// 词书 ID；未分类（单词不属于任何词书）时为 null
  final int? bookId;
  final String bookTitle;

  /// 该词书中的待复习单词
  final List<String> words;

  DueWordsGroup({this.bookId, required this.bookTitle, required this.words});
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
          await db.rawQuery('SELECT COUNT(*) FROM wrong_sentences'),
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

  /// 获取全部待复习单词，并按词书分组。
  /// 一个单词可能同时属于多本词书，此时会出现在每本词书的
  /// 分组中；不属于任何词书的单词（如词书已删除）归入
  /// 「未分类」分组，避免遗漏复习任务。
  static Future<List<DueWordsGroup>> getDueWordsGroupedByBook() async {
    final allDueWords = await getAllDueWords();
    if (allDueWords.isEmpty) return [];

    final db = await DatabaseService.database;

    // 只查询待复习单词涉及的词书条目，而非全表扫描
    final cleanedDueWords = allDueWords
        .map((w) => w.trim().toLowerCase())
        .toSet()
        .toList();
    final placeholders = cleanedDueWords.map((_) => '?').join(',');
    final maps = await db.rawQuery('''
      SELECT e.word, e.book_id, b.title FROM word_book_entries e
      JOIN word_books b ON b.id = e.book_id
      WHERE LOWER(e.word) IN ($placeholders)
    ''', cleanedDueWords);
    final wordBooksMap = <String, List<Map<String, dynamic>>>{};
    for (final m in maps) {
      final word = (m['word'] as String).toLowerCase();
      wordBooksMap.putIfAbsent(word, () => []).add(m);
    }

    // 按词书聚合
    final groupMap = <int, DueWordsGroup>{};
    final uncategorized = <String>[];
    final seen = <String>{};

    for (final word in allDueWords) {
      final cleaned = word.trim().toLowerCase();
      if (seen.contains(cleaned)) continue;
      seen.add(cleaned);

      final bookMaps = wordBooksMap[cleaned];
      if (bookMaps == null || bookMaps.isEmpty) {
        uncategorized.add(word);
        continue;
      }
      for (final m in bookMaps) {
        final bookId = m['book_id'] as int;
        final title = m['title'] as String;
        groupMap
            .putIfAbsent(
              bookId,
              () => DueWordsGroup(bookId: bookId, bookTitle: title, words: []),
            )
            .words
            .add(word);
      }
    }

    // 按词书创建时间排序（保持稳定顺序）
    final bookOrder = await db.query(
      'word_books',
      columns: ['id'],
      orderBy: 'created_at ASC',
    );
    final idOrder = bookOrder.map((m) => m['id'] as int).toList();
    final groups = <DueWordsGroup>[];
    for (final id in idOrder) {
      final g = groupMap[id];
      if (g != null) groups.add(g);
    }
    // 补充未在 word_books 中（理论上不会发生）的分组
    for (final g in groupMap.values) {
      if (!groups.contains(g)) groups.add(g);
    }

    if (uncategorized.isNotEmpty) {
      groups.add(
        DueWordsGroup(bookId: null, bookTitle: '未分类', words: uncategorized),
      );
    }

    return groups;
  }

  // ─── 全局随机干扰项池 ──────────────────────────

  /// 从已学单词（user_word_records）中随机取 count 个词作为干扰项池，
  /// 排除 excludeWords 中的词。若已学词不足 count 个，则从词书条目
  /// （word_book_entries）中随机补充缺失数量，保证首次学习时也有足够的
  /// 真实干扰项可用。
  /// 返回「词 → 释义」的 Map（释义由调用方后续加载）。
  static Future<Map<String, String>> getRandomDistractors({
    required List<String> excludeWords,
    int count = 10,
  }) async {
    final db = await DatabaseService.database;
    final result = <String, String>{};
    if (count <= 0) return result;

    // 第 1 层：从已学单词中随机取
    if (excludeWords.isNotEmpty) {
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
      for (final m in maps) {
        result[m['word'] as String] = '';
      }
    }

    // 第 2 层：已学词不足时，从词书条目中随机补充
    if (result.length < count) {
      final need = count - result.length;
      final excluded = [...excludeWords, ...result.keys];
      if (excluded.isNotEmpty) {
        final placeholders = excluded.map((_) => '?').join(',');
        final maps = await db.rawQuery(
          '''
          SELECT e.word FROM word_book_entries e
          WHERE e.word NOT IN ($placeholders)
          ORDER BY RANDOM()
          LIMIT ?
        ''',
          [...excluded, need],
        );
        for (final m in maps) {
          result[m['word'] as String] = '';
        }
      }
    }

    return result;
  }

  /// 从词书条目（word_book_entries）中随机取一个词作为干扰项，
  /// 排除 excludeWords 中的词。用于极端情况下补充干扰项池。
  /// 返回 null 表示词书中没有其他可选词。
  static Future<String?> getRandomDistractorWord(
    List<String> excludeWords,
  ) async {
    final db = await DatabaseService.database;
    final excluded = excludeWords.map((w) => w.trim().toLowerCase()).toSet();
    if (excluded.isEmpty) {
      final maps = await db.rawQuery(
        'SELECT e.word FROM word_book_entries e ORDER BY RANDOM() LIMIT 1',
      );
      if (maps.isEmpty) return null;
      return maps.first['word'] as String;
    }
    final placeholders = excluded.map((_) => '?').join(',');
    final maps = await db.rawQuery('''
      SELECT e.word FROM word_book_entries e
      WHERE LOWER(e.word) NOT IN ($placeholders)
      ORDER BY RANDOM()
      LIMIT 1
    ''', excluded.toList());
    if (maps.isEmpty) return null;
    return maps.first['word'] as String;
  }

  // ─── 打卡与统计数据 ──────────────────────────

  /// 每日学习目标（SharedPreferences key）
  static const String dailyGoalKey = 'daily_goal';

  /// 读取今日学习目标（默认 10）
  static Future<int> getDailyGoal() async {
    final prefs = await SharedPreferences.getInstance();
    final goal = prefs.getInt(dailyGoalKey) ?? 10;
    if (goal <= 0) return 10;
    return goal;
  }

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
        'daily_goal',
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
        'daily_goal': null,
      });
    }

    // 每次写入后检查是否达标
    await _checkAndMarkCompleted();
  }

  /// 检查今日学习数是否达到目标，达标则标记 completed=1 并记录当日目标值
  static Future<void> _checkAndMarkCompleted() async {
    final db = await DatabaseService.database;
    final today = _todayStr();
    final goal = await getDailyGoal();

    final row = await db.query(
      'daily_activity',
      columns: ['words_learned', 'completed'],
      where: 'date = ?',
      whereArgs: [today],
    );
    if (row.isEmpty) return;

    final learned = (row.first['words_learned'] as int?) ?? 0;
    final completed = (row.first['completed'] as int?) == 1;
    if (!completed && learned >= goal) {
      await db.update(
        'daily_activity',
        {'completed': 1, 'daily_goal': goal},
        where: 'date = ?',
        whereArgs: [today],
      );
    }
  }

  /// 当日打卡进度（用于主页进度条展示）
  /// 返回 {learned, goal, completed}
  static Future<Map<String, dynamic>> getTodayGoalProgress() async {
    final db = await DatabaseService.database;
    final today = _todayStr();
    final goal = await getDailyGoal();

    final row = await db.query(
      'daily_activity',
      columns: ['words_learned', 'completed'],
      where: 'date = ?',
      whereArgs: [today],
    );

    final learned = row.isEmpty ? 0 : (row.first['words_learned'] as int?) ?? 0;
    final completed = row.isNotEmpty && (row.first['completed'] as int?) == 1;

    return {'learned': learned, 'goal': goal, 'completed': completed};
  }

  /// 获取指定月份每天的打卡数据（用于日历展示）
  /// 返回 {date, completed} 列表，未打卡日期也包含（completed=0）
  static Future<List<Map<String, dynamic>>> getMonthlyActivity(
    int year,
    int month,
  ) async {
    final db = await DatabaseService.database;
    final prefix = '$year-${month.toString().padLeft(2, '0')}';

    final rows = await db.query(
      'daily_activity',
      columns: ['date', 'completed'],
      where: 'date LIKE ?',
      whereArgs: ['$prefix%'],
    );

    final completedMap = <String, bool>{};
    for (final r in rows) {
      completedMap[r['date'] as String] = (r['completed'] as int?) == 1;
    }

    final daysInMonth = DateTime(year, month + 1, 0).day;
    final results = <Map<String, dynamic>>[];
    for (int day = 1; day <= daysInMonth; day++) {
      final dateStr = '$prefix-${day.toString().padLeft(2, '0')}';
      results.add({
        'date': dateStr,
        'completed': completedMap[dateStr] ?? false,
      });
    }
    return results;
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

    // 如果今天已完成，从今天开始；否则从昨天开始
    final startDay = (todayRow.isNotEmpty && todayRow.first['completed'] == 1)
        ? DateTime(now.year, now.month, now.day)
        : DateTime(
            now.year,
            now.month,
            now.day,
          ).subtract(const Duration(days: 1));

    // 只用一条 SQL 查询最近 365 天的打卡记录，在内存中计算连续天数
    final startDate = startDay.subtract(const Duration(days: 364));
    final startStr =
        '${startDate.year}-${startDate.month.toString().padLeft(2, '0')}-${startDate.day.toString().padLeft(2, '0')}';

    final rows = await db.query(
      'daily_activity',
      columns: ['date'],
      where: 'date >= ? AND completed = 1',
      whereArgs: [startStr],
    );

    final completedDates = <String>{};
    for (final row in rows) {
      completedDates.add(row['date'] as String);
    }

    int streak = 0;
    for (int i = 0; i < 365; i++) {
      final date = startDay.subtract(Duration(days: i));
      final dateStr =
          '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
      if (completedDates.contains(dateStr)) {
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

  // ─── 单词总览（按状态查询与管理） ─────────────────

  /// 按状态获取单词列表
  /// [status]: 0=等待学习, 1=已学习, 2=已掌握
  /// [bookId] 不为 null 时按词书筛选
  /// 返回列表，每个元素为 {word, books: `List<String>`}，
  /// books 为该单词来源的所有词书名称（去重）。
  static Future<List<Map<String, dynamic>>> getWordsByStatus({
    int? status,
    int? bookId,
  }) async {
    final db = await DatabaseService.database;

    // 如果指定了词书，先取出该词书中的所有单词集合
    Set<String>? bookWords;
    if (bookId != null) {
      final maps = await db.query(
        'word_book_entries',
        columns: ['word'],
        where: 'book_id = ?',
        whereArgs: [bookId],
      );
      bookWords = maps.map((m) => m['word'] as String).toSet();
    }

    List<Map<String, dynamic>> wordMaps;
    if (status == 0) {
      // 等待学习：出现在词书中但还没有学习记录
      wordMaps = await db.rawQuery('''
        SELECT DISTINCT e.word FROM word_book_entries e
        WHERE e.word NOT IN (
          SELECT r.word FROM user_word_records r
        )
        ORDER BY e.word COLLATE NOCASE
      ''');
    } else {
      final sql = status == 1
          ? '''
        SELECT DISTINCT r.word FROM user_word_records r
        WHERE r.is_mastered = 0
        ORDER BY r.word COLLATE NOCASE
      '''
          : '''
        SELECT DISTINCT r.word FROM user_word_records r
        WHERE r.is_mastered = 1
        ORDER BY r.word COLLATE NOCASE
      ''';
      wordMaps = await db.rawQuery(sql);
    }

    // 按词书筛选（仅保留出现在该词书中的单词）
    if (bookWords != null) {
      final bookWordsSet = bookWords;
      wordMaps = wordMaps
          .where((m) => bookWordsSet.contains(m['word'] as String))
          .toList();
    }

    // 查询所有单词的来源词书映射
    final bookMaps = await db.rawQuery('''
      SELECT e.word, b.title FROM word_book_entries e
      JOIN word_books b ON b.id = e.book_id
    ''');
    final sourceMap = <String, Set<String>>{};
    for (final m in bookMaps) {
      final word = m['word'] as String;
      final title = m['title'] as String;
      sourceMap.putIfAbsent(word, () => <String>{}).add(title);
    }

    return wordMaps.map((m) {
      final word = m['word'] as String;
      return {'word': word, 'books': sourceMap[word]?.toList() ?? <String>[]};
    }).toList();
  }

  /// 获取所有词书简要信息（用于筛选器）
  /// 返回列表，每个元素为 {id, title}
  static Future<List<Map<String, dynamic>>> getAllBooksBrief() async {
    final db = await DatabaseService.database;
    final maps = await db.query(
      'word_books',
      columns: ['id', 'title'],
      orderBy: 'created_at DESC',
    );
    return maps;
  }

  /// 获取已掌握的单词列表，用于词汇测试。
  /// `[count]` 为 null 或 <= 0 时返回全部已掌握单词。
  /// `[bookId]` 不为 null 时仅返回该词书中的已掌握单词。
  /// 返回列表，每个元素为 {word, books: `List<String>`}。
  static Future<List<Map<String, dynamic>>> getMasteredWordsForTest({
    int? count,
    int? bookId,
  }) async {
    final db = await DatabaseService.database;

    Set<String>? bookWordSet;
    if (bookId != null) {
      final maps = await db.query(
        'word_book_entries',
        columns: ['word'],
        where: 'book_id = ?',
        whereArgs: [bookId],
      );
      bookWordSet = maps.map((m) => m['word'] as String).toSet();
    }

    final limitClause = (count != null && count > 0) ? 'LIMIT $count' : '';
    final wordMaps = await db.rawQuery('''
      SELECT DISTINCT r.word FROM user_word_records r
      WHERE r.is_mastered = 1
      ORDER BY RANDOM()
      $limitClause
    ''');

    var words = wordMaps.map((m) => m['word'] as String).toList();
    if (bookWordSet != null) {
      words = words.where((w) => bookWordSet!.contains(w)).toList();
      if (count != null && count > 0 && words.length > count) {
        words = words.sublist(0, count);
      }
    }

    if (words.isEmpty) return [];

    // 查询来源词书映射
    final bookMaps = await db.rawQuery('''
      SELECT e.word, b.title FROM word_book_entries e
      JOIN word_books b ON b.id = e.book_id
    ''');
    final sourceMap = <String, Set<String>>{};
    for (final m in bookMaps) {
      final word = m['word'] as String;
      final title = m['title'] as String;
      sourceMap.putIfAbsent(word, () => <String>{}).add(title);
    }

    return words.map((w) {
      return {'word': w, 'books': sourceMap[w]?.toList() ?? <String>[]};
    }).toList();
  }

  /// 批量标记为已掌握（事务）
  /// 对于还没有学习记录的词（等待学习），直接创建一条已掌握记录。
  static Future<void> markAsMasteredBatch(List<String> words) async {
    final db = await DatabaseService.database;
    final cleaned = words.map((w) => w.trim().toLowerCase()).toSet().toList();
    if (cleaned.isEmpty) return;
    final now = DateTime.now().toIso8601String();

    await db.transaction((txn) async {
      for (final word in cleaned) {
        final updated = await txn.update(
          'user_word_records',
          {'is_mastered': 1, 'last_reviewed_at': now},
          where: 'word = ?',
          whereArgs: [word],
        );
        if (updated == 0) {
          // 该词还没有学习记录，直接插入一条已掌握记录
          await txn.insert('user_word_records', {
            'word': word,
            'stage': 0,
            'is_weak': 0,
            'is_mastered': 1,
            'next_review_date': null,
            'last_reviewed_at': now,
            'review_count': 0,
            'created_at': now,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await txn.delete('wrong_words', where: 'word = ?', whereArgs: [word]);
      }
    });
  }

  /// 批量重置学习状态（删除学习记录，回到等待学习）
  static Future<void> resetMasteredBatch(List<String> words) async {
    final db = await DatabaseService.database;
    final cleaned = words.map((w) => w.trim().toLowerCase()).toSet().toList();
    if (cleaned.isEmpty) return;

    await db.transaction((txn) async {
      for (final word in cleaned) {
        await txn.delete(
          'user_word_records',
          where: 'word = ?',
          whereArgs: [word],
        );
        await txn.delete('wrong_words', where: 'word = ?', whereArgs: [word]);
      }
    });
  }

  // ─── 批量保存学习/复习结果 ─────────────────────

  /// 批量保存学习结果（学习/复习完成后一次性写入）
  /// results: word → result ("easy" | "hard" | "forgot" | "mastered")
  ///
  /// 区分新增（学习）和更新（复习）：
  /// - 已存在的记录（复习）：使用 UPDATE，保留 created_at，递增 review_count
  /// - 不存在的记录（学习）：使用 INSERT，创建完整新行
  ///
  /// 改进：对 easy/hard 不再硬编码 stage=0，而是参考原 stage 做递进或降级。
  ///
  /// [isReview] 为 true 时计入「今日复习」，false 时计入「今日学习」。
  static Future<void> saveLearningBatchResults(
    Map<String, String> results, {
    bool isReview = false,
  }) async {
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
          // 忘记 → 回到低 Stage 并标记为弱词（不删除记录，保留学习历史）
          final existing = await txn.query(
            'user_word_records',
            columns: ['review_count'],
            where: 'word = ?',
            whereArgs: [word],
          );

          if (existing.isNotEmpty) {
            final oldReviewCount =
                (existing.first['review_count'] as int?) ?? 0;
            final nextDate = UserWordRecord(
              word: word,
              stage: 0,
            ).computeNextReviewDate();

            await txn.update(
              'user_word_records',
              {
                'stage': 0,
                'is_weak': 1,
                'is_mastered': 0,
                'next_review_date': nextDate,
                'last_reviewed_at': now,
                'review_count': oldReviewCount + 1,
              },
              where: 'word = ?',
              whereArgs: [word],
            );
          } else {
            // 无记录时创建一条新记录（首次学习即忘记）
            final nextDate = UserWordRecord(
              word: word,
              stage: 0,
            ).computeNextReviewDate();

            await txn.insert('user_word_records', {
              'word': word,
              'stage': 0,
              'is_weak': 1,
              'is_mastered': 0,
              'next_review_date': nextDate,
              'last_reviewed_at': now,
              'review_count': 1,
              'created_at': now,
            });
          }
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

    // ── 每日活动统计 ──
    var correctCount = 0;
    var wrongCount = 0;
    for (final result in results.values) {
      if (result == 'easy' || result == 'mastered') {
        correctCount++;
      } else if (result == 'hard' || result == 'forgot') {
        wrongCount++;
      }
    }
    await recordDailyActivity(
      wordsLearned: isReview ? 0 : results.length,
      wordsReviewed: isReview ? results.length : 0,
      correctCount: correctCount,
      wrongCount: wrongCount,
    );
  }

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

  // ─── 词汇测试历史记录 ─────────────────────────

  /// 保存一次词汇测试结果到历史记录表
  static Future<void> saveVocabTestResult({
    required int totalCount,
    required int correctCount,
    int? bookId,
    String? bookTitle,
  }) async {
    final db = await DatabaseService.database;
    final accuracy = totalCount > 0 ? (correctCount / totalCount) : 0.0;
    await db.insert('vocab_test_history', {
      'date': DateTime.now().toIso8601String(),
      'total_count': totalCount,
      'correct_count': correctCount,
      'accuracy': accuracy,
      'book_id': bookId,
      'book_title': bookTitle,
    });
  }

  /// 获取词汇测试历史记录（按时间倒序），可选限制条数
  static Future<List<Map<String, dynamic>>> getVocabTestHistory({
    int limit = 50,
  }) async {
    final db = await DatabaseService.database;
    final maps = await db.query(
      'vocab_test_history',
      orderBy: 'date DESC',
      limit: limit,
    );
    return maps;
  }

  /// 获取词汇测试历史统计数据（用于趋势展示）
  static Future<Map<String, dynamic>> getVocabTestStats() async {
    final db = await DatabaseService.database;
    final count =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM vocab_test_history'),
        ) ??
        0;
    final avgResult = await db.rawQuery(
      'SELECT AVG(accuracy) FROM vocab_test_history',
    );
    final avgAccuracy =
        avgResult.isNotEmpty && avgResult.first.values.first != null
        ? (avgResult.first.values.first as num).toDouble()
        : 0.0;
    return {'count': count, 'avgAccuracy': avgAccuracy};
  }
}
