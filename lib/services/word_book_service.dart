import 'package:sqflite/sqflite.dart';
import '../models/word_book.dart';
import 'database_service.dart';
import 'dictionary_service.dart';

class WordBookService {
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

  /// 创建词书
  static Future<int> createBook(WordBook book) async {
    final db = await DatabaseService.database;
    final now = DateTime.now().toIso8601String();
    final id = await db.insert('word_books', {
      ...book.toMap(),
      'created_at': now,
      'updated_at': now,
    });
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
  }

  /// 删除词书（级联删除条目）
  static Future<void> deleteBook(int id) async {
    final db = await DatabaseService.database;
    await db.delete('word_book_entries', where: 'book_id = ?', whereArgs: [id]);
    await db.delete('word_books', where: 'id = ?', whereArgs: [id]);
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

  /// 批量添加单词到词书（去重）
  static Future<int> addWordsToBook(int bookId, List<String> words) async {
    final db = await DatabaseService.database;
    final now = DateTime.now().toIso8601String();
    int added = 0;

    for (final word in words) {
      try {
        await db.insert('word_book_entries', {
          'book_id': bookId,
          'word': word.trim().toLowerCase(),
          'added_at': now,
        });
        added++;
      } catch (e) {
        // UNIQUE 约束冲突，跳过
      }
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

  /// 导入词汇：解析文本（一行一词），查本地词典，返回结果
  static Future<ImportResult> importWords(String text) async {
    final lines = text
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    final found = <String>{};
    final missing = <String>[];

    for (final word in lines) {
      final cleaned = word.toLowerCase().trim();
      final entry = await DictionaryService.searchEnExact(cleaned);
      if (entry != null) {
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
