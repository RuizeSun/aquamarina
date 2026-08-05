import 'package:sqflite/sqflite.dart';
import '../models/word_note.dart';
import 'database_service.dart';

/// 单词收藏与笔记服务
class WordNoteService {
  WordNoteService._();

  /// 查询单词的收藏/笔记记录
  static Future<WordNote?> getWordNote(String word) async {
    final db = await DatabaseService.database;
    final maps = await db.query(
      'word_notes',
      where: 'word = ? COLLATE NOCASE',
      whereArgs: [word.trim().toLowerCase()],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return WordNote.fromMap(maps.first);
  }

  /// 查询是否已收藏
  static Future<bool> isFavorited(String word) async {
    final note = await getWordNote(word);
    return note?.isFavorited ?? false;
  }

  /// 收藏 / 取消收藏
  ///
  /// - 首次收藏：插入新记录
  /// - 取消收藏：若该词没有笔记则删除整行，否则仅置 is_favorited = 0
  /// - 重复收藏：幂等，直接置 is_favorited = 1
  static Future<void> setFavorite(String word, {required bool favorite}) async {
    final db = await DatabaseService.database;
    final cleaned = word.trim().toLowerCase();
    final now = DateTime.now().toIso8601String();

    final existing = await getWordNote(cleaned);
    if (existing == null) {
      if (!favorite) return; // 不存在时无需取消
      await db.insert('word_notes', {
        'word': cleaned,
        'is_favorited': 1,
        'created_at': now,
        'updated_at': now,
      });
      return;
    }

    if (favorite) {
      await db.update(
        'word_notes',
        {'is_favorited': 1, 'updated_at': now},
        where: 'word = ? COLLATE NOCASE',
        whereArgs: [cleaned],
      );
    } else {
      // 取消收藏：如果该词也没有笔记，直接删除整行；否则保留行仅取消标记
      if (existing.note == null || existing.note!.isEmpty) {
        await db.delete(
          'word_notes',
          where: 'word = ? COLLATE NOCASE',
          whereArgs: [cleaned],
        );
      } else {
        await db.update(
          'word_notes',
          {'is_favorited': 0, 'updated_at': now},
          where: 'word = ? COLLATE NOCASE',
          whereArgs: [cleaned],
        );
      }
    }
  }

  /// 保存笔记（[note] 为空字符串时视为删除笔记）
  static Future<void> saveNote(String word, String note) async {
    final db = await DatabaseService.database;
    final cleaned = word.trim().toLowerCase();
    final trimmed = note.trim();
    final now = DateTime.now().toIso8601String();

    final existing = await getWordNote(cleaned);

    if (trimmed.isEmpty) {
      // 空笔记：若无收藏则删除整行，否则仅清空 note
      if (existing == null) return;
      if (existing.isFavorited) {
        await db.update(
          'word_notes',
          {'note': null, 'updated_at': now},
          where: 'word = ? COLLATE NOCASE',
          whereArgs: [cleaned],
        );
      } else {
        await db.delete(
          'word_notes',
          where: 'word = ? COLLATE NOCASE',
          whereArgs: [cleaned],
        );
      }
      return;
    }

    if (existing == null) {
      await db.insert('word_notes', {
        'word': cleaned,
        'note': trimmed,
        'is_favorited': 0,
        'created_at': now,
        'updated_at': now,
      });
    } else {
      await db.update(
        'word_notes',
        {'note': trimmed, 'updated_at': now},
        where: 'word = ? COLLATE NOCASE',
        whereArgs: [cleaned],
      );
    }
  }

  /// 获取所有收藏单词（按收藏/更新时间倒序）
  static Future<List<WordNote>> getFavorites() async {
    final db = await DatabaseService.database;
    final maps = await db.query(
      'word_notes',
      where: 'is_favorited = 1',
      orderBy: 'updated_at DESC',
    );
    return maps.map(WordNote.fromMap).toList();
  }

  /// 搜索收藏：按单词或笔记内容模糊匹配
  static Future<List<WordNote>> searchFavorites(String query) async {
    final db = await DatabaseService.database;
    final pattern = '%${query.trim()}%';
    final maps = await db.query(
      'word_notes',
      where: 'is_favorited = 1 AND (word LIKE ? OR note LIKE ?)',
      whereArgs: [pattern, pattern],
      orderBy: 'updated_at DESC',
    );
    return maps.map(WordNote.fromMap).toList();
  }

  /// 获取所有有笔记的单词（按更新时间倒序）
  static Future<List<WordNote>> getNotes() async {
    final db = await DatabaseService.database;
    final maps = await db.query(
      'word_notes',
      where: 'note IS NOT NULL AND note != \'\'',
      orderBy: 'updated_at DESC',
    );
    return maps.map(WordNote.fromMap).toList();
  }

  /// 搜索笔记：按单词或笔记内容模糊匹配
  static Future<List<WordNote>> searchNotes(String query) async {
    final db = await DatabaseService.database;
    final pattern = '%${query.trim()}%';
    final maps = await db.query(
      'word_notes',
      where:
          'note IS NOT NULL AND note != \'\' AND (word LIKE ? OR note LIKE ?)',
      whereArgs: [pattern, pattern],
      orderBy: 'updated_at DESC',
    );
    return maps.map(WordNote.fromMap).toList();
  }

  /// 获取统计信息
  static Future<({int favoriteCount, int noteCount})> getStats() async {
    final db = await DatabaseService.database;
    final fav =
        Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM word_notes WHERE is_favorited = 1',
          ),
        ) ??
        0;
    final notes =
        Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM word_notes WHERE note IS NOT NULL AND note != \'\'',
          ),
        ) ??
        0;
    return (favoriteCount: fav, noteCount: notes);
  }

  /// 删除单词的全部收藏/笔记记录（供数据清理等场景使用）
  static Future<void> removeWord(String word) async {
    final db = await DatabaseService.database;
    await db.delete(
      'word_notes',
      where: 'word = ? COLLATE NOCASE',
      whereArgs: [word.trim().toLowerCase()],
    );
  }
}
