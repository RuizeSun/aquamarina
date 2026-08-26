import 'package:sqflite/sqflite.dart';
import '../models/ai_sentence.dart';
import '../models/sentence_note.dart';
import 'database_service.dart';

/// 句子收藏与笔记服务
class SentenceNoteService {
  SentenceNoteService._();

  /// 将笔记记录还原为 Sentence（供取消收藏等场景使用）
  static Sentence toSentence(SentenceNote note) {
    return Sentence(
      id: note.sentenceId,
      setId: note.setId ?? '',
      english: note.english,
      chinese: note.chinese,
    );
  }

  /// 为句子生成稳定的主键（句式集 / 错题本句子均带 id）
  static String _keyFor(Sentence sentence) {
    final id = sentence.id;
    if (id != null && id.isNotEmpty) return id;
    // 无 id（如临时构造的句子）时回退到英文原文生成稳定 key
    return 'bytext:${sentence.english}';
  }

  /// 查询句子的收藏/笔记记录
  static Future<SentenceNote?> getSentenceNote(String sentenceId) async {
    final db = await DatabaseService.database;
    final maps = await db.query(
      'sentence_notes',
      where: 'sentence_id = ?',
      whereArgs: [sentenceId],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return SentenceNote.fromMap(maps.first);
  }

  /// 查询句子是否已收藏
  static Future<bool> isFavorited(String sentenceId) async {
    final note = await getSentenceNote(sentenceId);
    return note?.isFavorited ?? false;
  }

  /// 收藏 / 取消收藏
  ///
  /// - 首次收藏：插入新记录（保存句子内容快照）
  /// - 取消收藏：若该句没有笔记则删除整行，否则仅置 is_favorited = 0
  /// - 重复收藏：幂等，直接置 is_favorited = 1
  static Future<void> setFavorite(
    Sentence sentence, {
    required bool favorite,
  }) async {
    final db = await DatabaseService.database;
    final key = _keyFor(sentence);
    final now = DateTime.now().toIso8601String();

    final existing = await getSentenceNote(key);
    if (existing == null) {
      if (!favorite) return; // 不存在时无需取消
      await db.insert('sentence_notes', {
        'sentence_id': key,
        'set_id': sentence.setId,
        'english': sentence.english,
        'chinese': sentence.chinese,
        'is_favorited': 1,
        'created_at': now,
        'updated_at': now,
      });
      return;
    }

    if (favorite) {
      await db.update(
        'sentence_notes',
        {'is_favorited': 1, 'updated_at': now},
        where: 'sentence_id = ?',
        whereArgs: [key],
      );
    } else {
      // 取消收藏：如果该句也没有笔记，直接删除整行；否则保留行仅取消标记
      if (existing.note == null || existing.note!.isEmpty) {
        await db.delete(
          'sentence_notes',
          where: 'sentence_id = ?',
          whereArgs: [key],
        );
      } else {
        await db.update(
          'sentence_notes',
          {'is_favorited': 0, 'updated_at': now},
          where: 'sentence_id = ?',
          whereArgs: [key],
        );
      }
    }
  }

  /// 保存笔记（[note] 为空字符串时视为删除笔记）
  static Future<void> saveNote(Sentence sentence, String note) async {
    final db = await DatabaseService.database;
    final key = _keyFor(sentence);
    final trimmed = note.trim();
    final now = DateTime.now().toIso8601String();

    final existing = await getSentenceNote(key);

    if (trimmed.isEmpty) {
      // 空笔记：若无收藏则删除整行，否则仅清空 note
      if (existing == null) return;
      if (existing.isFavorited) {
        await db.update(
          'sentence_notes',
          {'note': null, 'updated_at': now},
          where: 'sentence_id = ?',
          whereArgs: [key],
        );
      } else {
        await db.delete(
          'sentence_notes',
          where: 'sentence_id = ?',
          whereArgs: [key],
        );
      }
      return;
    }

    if (existing == null) {
      await db.insert('sentence_notes', {
        'sentence_id': key,
        'set_id': sentence.setId,
        'english': sentence.english,
        'chinese': sentence.chinese,
        'note': trimmed,
        'is_favorited': 0,
        'created_at': now,
        'updated_at': now,
      });
    } else {
      await db.update(
        'sentence_notes',
        {'note': trimmed, 'updated_at': now},
        where: 'sentence_id = ?',
        whereArgs: [key],
      );
    }
  }

  /// 获取所有收藏句子（按更新时间倒序）
  static Future<List<SentenceNote>> getFavorites() async {
    final db = await DatabaseService.database;
    final maps = await db.query(
      'sentence_notes',
      where: 'is_favorited = 1',
      orderBy: 'updated_at DESC',
    );
    return maps.map(SentenceNote.fromMap).toList();
  }

  /// 搜索收藏：按英文、中文或笔记内容模糊匹配
  static Future<List<SentenceNote>> searchFavorites(String query) async {
    final db = await DatabaseService.database;
    final pattern = '%${query.trim()}%';
    final maps = await db.query(
      'sentence_notes',
      where:
          'is_favorited = 1 AND (english LIKE ? OR chinese LIKE ? OR note LIKE ?)',
      whereArgs: [pattern, pattern, pattern],
      orderBy: 'updated_at DESC',
    );
    return maps.map(SentenceNote.fromMap).toList();
  }

  /// 获取所有有笔记的句子（按更新时间倒序）
  static Future<List<SentenceNote>> getNotes() async {
    final db = await DatabaseService.database;
    final maps = await db.query(
      'sentence_notes',
      where: "note IS NOT NULL AND note != ''",
      orderBy: 'updated_at DESC',
    );
    return maps.map(SentenceNote.fromMap).toList();
  }

  /// 搜索笔记：按英文、中文或笔记内容模糊匹配
  static Future<List<SentenceNote>> searchNotes(String query) async {
    final db = await DatabaseService.database;
    final pattern = '%${query.trim()}%';
    final maps = await db.query(
      'sentence_notes',
      where:
          "note IS NOT NULL AND note != '' AND (english LIKE ? OR chinese LIKE ? OR note LIKE ?)",
      whereArgs: [pattern, pattern, pattern],
      orderBy: 'updated_at DESC',
    );
    return maps.map(SentenceNote.fromMap).toList();
  }

  /// 获取统计信息
  static Future<({int favoriteCount, int noteCount})> getStats() async {
    final db = await DatabaseService.database;
    final fav =
        Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM sentence_notes WHERE is_favorited = 1',
          ),
        ) ??
        0;
    final notes =
        Sqflite.firstIntValue(
          await db.rawQuery(
            "SELECT COUNT(*) FROM sentence_notes WHERE note IS NOT NULL AND note != ''",
          ),
        ) ??
        0;
    return (favoriteCount: fav, noteCount: notes);
  }

  /// 删除句子的全部收藏/笔记记录（供数据清理等场景使用）
  static Future<void> removeSentence(String sentenceId) async {
    final db = await DatabaseService.database;
    await db.delete(
      'sentence_notes',
      where: 'sentence_id = ?',
      whereArgs: [sentenceId],
    );
  }
}
