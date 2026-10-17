import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../models/sync_op.dart';
import '../models/word_book.dart';
import 'database_service.dart';
import 'dictionary_service.dart';
import 'log_service.dart';
import 'sync_capture_service.dart';
import 'sync_table_spec.dart';

class WordBookService {
  /// 单条 SQL 中 `IN (...)` 的最大绑定参数个数（与 DictionaryService 一致）。
  ///
  /// SQLite 默认上限为 32766（旧构建为 999），超出会直接报错；
  /// 分批查询可保证粘贴数万单词时依然稳定。
  static const int _maxQueryChunkSize = 900;

  /// 获取所有词书
  static Future<List<WordBook>> getAllBooks() async {
    final db = await DatabaseService.database;
    final maps = await db.query('word_books', orderBy: 'created_at DESC');
    return maps.map((m) => WordBook.fromMap(m)).toList();
  }

  /// 获取单个词书
  static Future<WordBook?> getBookById(int id) async {
    final db = await DatabaseService.database;
    final maps = await db.query('word_books', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return null;
    return WordBook.fromMap(maps.first);
  }

  /// 获取所有词书标题
  static Future<List<String>> getAllBookTitles() async {
    final db = await DatabaseService.database;
    final maps = await db.query('word_books', columns: ['title']);
    return maps.map((m) => m['title'] as String).toList();
  }

  /// 生成不重复的词书标题（类似 Windows 重命名行为）
  /// 例如：如果 "四级词汇" 已存在，则生成 "四级词汇 (2)"
  ///       如果 "四级词汇 (2)" 也已存在，则生成 "四级词汇 (3)"
  /// [excludeId] 可选，排除当前编辑的词书（避免自己的标题被当作冲突）
  static Future<String> generateUniqueBookTitle(
    String desiredTitle, {
    int? excludeId,
  }) async {
    final allBooks = await getAllBooks();
    final titleSet = allBooks
        .where((b) => b.id != excludeId)
        .map((b) => b.title)
        .toSet();

    if (!titleSet.contains(desiredTitle)) {
      return desiredTitle;
    }

    int suffix = 2;
    String candidate;
    do {
      candidate = '$desiredTitle ($suffix)';
      suffix++;
    } while (titleSet.contains(candidate));

    return candidate;
  }

  /// 创建词书
  static Future<int> createBook(WordBook book) async {
    final db = await DatabaseService.database;
    final now = DateTime.now().toIso8601String();
    final id = await db.insert('word_books', {
      ...book.toMap(),
      'uuid': const Uuid().v4(),
      'created_at': now,
      'updated_at': now,
    });
    logInfo('WordBookService', '创建词书: "${book.title}" id=$id');
    return id;
  }

  /// 更新词书元数据
  static Future<void> updateBook(WordBook book) async {
    final db = await DatabaseService.database;
    await db.update(
      'word_books',
      {...book.toMap(), 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [book.id],
    );
    logDebug('WordBookService', '更新词书: id=${book.id}');
  }

  /// 删除词书（级联删除条目）
  static Future<void> deleteBook(int id) async {
    final db = await DatabaseService.database;
    await db.transaction((txn) async {
      await txn.delete(
        'word_book_entries',
        where: 'book_id = ?',
        whereArgs: [id],
      );
      await txn.delete('word_books', where: 'id = ?', whereArgs: [id]);
    });
    logInfo('WordBookService', '删除词书: id=$id');
  }

  /// 获取词书中所有单词
  static Future<List<String>> getBookWords(int bookId) async {
    final db = await DatabaseService.database;
    final maps = await db.query(
      'word_book_entries',
      columns: ['word'],
      where: 'book_id = ?',
      whereArgs: [bookId],
      orderBy: 'id ASC',
    );
    return maps.map((m) => m['word'] as String).toList();
  }

  /// 批量添加单词到词书（去重，使用 batch + 事务加速）
  static Future<int> addWordsToBook(int bookId, List<String> words) async {
    final db = await DatabaseService.database;
    final now = DateTime.now().toIso8601String();

    // 先去重、去空，避免把重复/空词传给数据库
    final cleaned = words
        .map((w) => w.trim().toLowerCase())
        .where((w) => w.isNotEmpty)
        .toSet()
        .toList();

    int added = 0;
    if (cleaned.isNotEmpty) {
      // 同步需要跨设备稳定的词书标识（v13 新增列）
      final bookRows = await db.query(
        'word_books',
        columns: ['uuid'],
        where: 'id = ?',
        whereArgs: [bookId],
        limit: 1,
      );
      final bookUuid = bookRows.isEmpty
          ? null
          : bookRows.first['uuid'] as String?;
      // 大批量导入快速路径：关闭逐行触发器，导入后用一条 INSERT ... SELECT
      // 回填 oplog，避免 N 万次触发器写入（P1-3）。
      final useFastPath =
          cleaned.length >= 1000 &&
          await SyncCaptureService.isCaptureEnabled(db: db);
      await db.transaction((txn) async {
        var minEntryId = 0;
        if (useFastPath) {
          final idRows = await txn.rawQuery(
            'SELECT COALESCE(MAX(id), 0) AS m FROM word_book_entries',
          );
          minEntryId = (idRows.first['m'] as int?) ?? 0;
          await txn.update('sync_meta', {
            'capture_enabled': 0,
          }, where: 'id = 1');
        }
        // 一次 batch 提交所有插入，避免逐词一次平台通道往返
        final batch = txn.batch();
        for (final word in cleaned) {
          batch.insert('word_book_entries', {
            'book_id': bookId,
            'book_uuid': bookUuid,
            'word': word,
            'added_at': now,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        final results = await batch.commit();
        for (final result in results) {
          if (result is int && result > 0) added++;
        }
        if (useFastPath) {
          if (bookUuid != null) {
            // 一条（或几条）批量 op 代替 N 条逐行 oplog。
            final items = [
              for (final word in cleaned)
                SyncBulkItem(
                  entity: 'word_book_entries',
                  key: {'book_uuid': bookUuid, 'word': word},
                  data: {'added_at': now},
                ),
            ];
            for (var i = 0; i < items.length; i += 1000) {
              final end = (i + 1000) > items.length ? items.length : i + 1000;
              await SyncCaptureService.recordBulk(txn, items.sublist(i, end));
            }
          } else {
            // 极旧词书没有 uuid 时退回逐行回填。
            final spec = SyncSpecs.byEntity['word_book_entries'];
            if (spec != null) {
              await SyncCaptureService.backfillOps(
                txn,
                spec,
                where: 'book_id = ? AND id > ?',
                whereArgs: [bookId, minEntryId],
              );
            }
          }
          await txn.update('sync_meta', {
            'capture_enabled': 1,
          }, where: 'id = 1');
        }
      });
    }

    // 更新词书词数
    final count =
        Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM word_book_entries WHERE book_id = ?',
            [bookId],
          ),
        ) ??
        0;
    await db.update(
      'word_books',
      {'word_count': count, 'updated_at': now},
      where: 'id = ?',
      whereArgs: [bookId],
    );

    return added;
  }

  /// 判断某个单词是否已在指定词书中（一次索引查询，避免整表加载）
  static Future<bool> isWordInBook(int bookId, String word) async {
    final db = await DatabaseService.database;
    final count =
        Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM word_book_entries '
            'WHERE book_id = ? AND word = ?',
            [bookId, word.trim().toLowerCase()],
          ),
        ) ??
        0;
    return count > 0;
  }

  /// 从词书删除单个单词
  static Future<void> removeWordFromBook(int bookId, String word) async {
    final db = await DatabaseService.database;
    await db.delete(
      'word_book_entries',
      where: 'book_id = ? AND word = ?',
      whereArgs: [bookId, word.trim().toLowerCase()],
    );

    final count =
        Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM word_book_entries WHERE book_id = ?',
            [bookId],
          ),
        ) ??
        0;
    await db.update(
      'word_books',
      {'word_count': count, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [bookId],
    );
  }

  /// 过滤已学单词：查询 user_word_records 表，区分已学与未学
  /// 返回 { learnedWords, newWords }
  ///
  /// 单词数超过 [_maxQueryChunkSize] 时分批查询后合并已学集合。
  static Future<({List<String> learnedWords, List<String> newWords})>
  filterLearnedWords(List<String> words) async {
    final db = await DatabaseService.database;
    final cleaned = words.map((w) => w.trim().toLowerCase()).toList();

    final learnedSet = <String>{};
    for (var start = 0; start < cleaned.length; start += _maxQueryChunkSize) {
      final chunk = cleaned.skip(start).take(_maxQueryChunkSize).toList();
      final placeholders = List.filled(chunk.length, '?').join(',');
      final maps = await db.rawQuery(
        'SELECT word FROM user_word_records WHERE word IN ($placeholders)',
        chunk,
      );
      learnedSet.addAll(maps.map((m) => m['word'] as String));
    }

    final learnedWords = <String>[];
    final newWords = <String>[];
    for (final w in cleaned) {
      if (learnedSet.contains(w)) {
        learnedWords.add(w);
      } else {
        newWords.add(w);
      }
    }
    return (learnedWords: learnedWords, newWords: newWords);
  }

  // ===== 单本词书导出 / 导入 =====

  /// 导出单本词书为 JSON 字符串
  ///
  /// 包含词书元数据（标题/描述/作者/封面色）与全部单词。
  /// 可通过 [importBookFromJson] 重新导入。
  static Future<String> exportBookToJson(int bookId) async {
    final book = await getBookById(bookId);
    if (book == null) {
      throw WordBookException('词书不存在或已被删除');
    }
    final words = await getBookWords(bookId);

    return jsonEncode({
      'app': 'aquamarina',
      'type': 'wordbook',
      'version': 1,
      'created_at': DateTime.now().toIso8601String(),
      'book': {
        'title': book.title,
        'description': book.description,
        'author': book.author,
        'cover_color': book.coverColor,
        'words': words,
      },
    });
  }

  /// 从 JSON 字符串导入单本词书
  ///
  /// 返回新创建的词书 ID。标题冲突时自动添加序号（类似 Windows 重命名）。
  /// JSON 格式不合法时抛出 [WordBookException]。
  static Future<int> importBookFromJson(String jsonStr) async {
    final dynamic decoded;
    try {
      decoded = jsonDecode(jsonStr);
    } catch (_) {
      throw const WordBookException('文件不是有效的 JSON 格式');
    }

    if (decoded is! Map<String, dynamic>) {
      throw const WordBookException('词书文件格式错误：顶层不是对象');
    }
    if (decoded['app'] != 'aquamarina' || decoded['type'] != 'wordbook') {
      throw const WordBookException('不是有效的 Aquamarina 词书文件');
    }
    final bookData = decoded['book'];
    if (bookData is! Map<String, dynamic>) {
      throw const WordBookException('词书文件缺少 book 数据');
    }

    final title = bookData['title'] as String?;
    if (title == null || title.trim().isEmpty) {
      throw const WordBookException('词书文件缺少标题');
    }

    final wordsRaw = bookData['words'];
    final words = <String>[];
    if (wordsRaw is List) {
      for (final w in wordsRaw) {
        if (w is String && w.trim().isNotEmpty) {
          words.add(w.trim().toLowerCase());
        }
      }
    }

    // 名称冲突时自动加序号
    final uniqueTitle = await generateUniqueBookTitle(title.trim());
    final bookId = await createBook(
      WordBook(
        title: uniqueTitle,
        description: (bookData['description'] as String?)?.trim(),
        author: (bookData['author'] as String?)?.trim(),
        coverColor: (bookData['cover_color'] as num?)?.toInt(),
      ),
    );

    if (words.isNotEmpty) {
      await addWordsToBook(bookId, words);
    }

    return bookId;
  }

  // ===== 导入词汇（文本） =====

  /// 导入词汇：解析文本（一行一词），批量查本地词典，返回结果
  static Future<ImportResult> importWords(String text) async {
    final lines = text
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    // 批量查询词典，一次 SQL 查出所有匹配的单词
    final foundMap = await DictionaryService.searchEnExactBatch(lines);

    final found = <String>[];
    final missing = <String>[];
    for (final word in lines) {
      final cleaned = word.toLowerCase().trim();
      if (foundMap.containsKey(cleaned)) {
        found.add(cleaned);
      } else {
        missing.add(cleaned);
      }
    }

    return ImportResult(
      totalLines: lines.length,
      foundCount: found.length,
      missingCount: missing.length,
      foundWords: found.toList(),
      missingWords: missing,
    );
  }
}

/// 词书操作异常
class WordBookException implements Exception {
  final String message;
  const WordBookException(this.message);

  @override
  String toString() => message;
}

/// 导入结果
class ImportResult {
  final int totalLines;
  final int foundCount;
  final int missingCount;
  final List<String> foundWords;
  final List<String> missingWords;

  ImportResult({
    required this.totalLines,
    required this.foundCount,
    required this.missingCount,
    required this.foundWords,
    required this.missingWords,
  });
}
