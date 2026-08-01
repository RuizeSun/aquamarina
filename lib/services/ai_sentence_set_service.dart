import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../models/ai_sentence_set.dart';
import '../models/ai_sentence.dart';
import 'database_service.dart';

/// 句式集管理服务（单例，各页面共享同一数据源以确保实时同步）
class SentenceSetService extends ChangeNotifier {
  static const String _prefsSetsKey = 'sentence_sets_v1';

  /// 全局唯一实例
  static final SentenceSetService instance = SentenceSetService._();

  SentenceSetService._();

  List<SentenceSet> _sets = [];
  bool _loaded = false;

  List<SentenceSet> get sets => List.unmodifiable(_sets);
  bool get loaded => _loaded;

  /// 获取所有句式集名称
  List<String> getAllSetNames() {
    return _sets.map((s) => s.name).toList();
  }

  /// 生成不重复的句式集名称（类似 Windows 重命名行为）
  /// 例如：如果 "日常句型" 已存在，则生成 "日常句型 (2)"
  ///       如果 "日常句型 (2)" 也已存在，则生成 "日常句型 (3)"
  String generateUniqueSetName(String desiredName) {
    final nameSet = _sets.map((s) => s.name).toSet();

    if (!nameSet.contains(desiredName)) {
      return desiredName;
    }

    int suffix = 2;
    String candidate;
    do {
      candidate = '$desiredName ($suffix)';
      suffix++;
    } while (nameSet.contains(candidate));

    return candidate;
  }

  // ===== 加载 =====
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();

    // 读取句式集列表
    final jsonStr = prefs.getString(_prefsSetsKey);
    if (jsonStr != null) {
      try {
        final list = jsonDecode(jsonStr) as List<dynamic>;
        _sets = list
            .map((e) => SentenceSet.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {
        _sets = [];
      }
    }

    _loaded = true;
    notifyListeners();
  }

  // ===== 句式集 CRUD =====
  Future<void> addSet(SentenceSet set) async {
    final s = set.copyWith(id: const Uuid().v4(), createdAt: DateTime.now());
    _sets.add(s);
    await _saveSets();
    notifyListeners();
  }

  Future<void> updateSet(SentenceSet set) async {
    final index = _sets.indexWhere((s) => s.id == set.id);
    if (index == -1) throw Exception('句式集不存在');
    _sets[index] = set;
    await _saveSets();
    notifyListeners();
  }

  Future<void> deleteSet(String id) async {
    _sets.removeWhere((s) => s.id == id);
    await _saveSets();
    // 同时删除该句式集下的所有句子
    final db = await DatabaseService.database;
    await db.delete('sentences', where: 'set_id = ?', whereArgs: [id]);
    notifyListeners();
  }

  SentenceSet? getSet(String id) {
    try {
      return _sets.firstWhere((s) => s.id == id);
    } catch (_) {
      return null;
    }
  }

  // ===== 句子 CRUD =====
  Future<List<Sentence>> getSentences(String setId) async {
    final db = await DatabaseService.database;
    final maps = await db.query(
      'sentences',
      where: 'set_id = ?',
      whereArgs: [setId],
      orderBy: 'id ASC',
    );
    return maps.map((m) => _rowToSentence(m)).toList();
  }

  Future<void> addSentence(Sentence sentence) async {
    final db = await DatabaseService.database;
    final id = const Uuid().v4();
    await db.insert('sentences', {
      'id': id,
      'set_id': sentence.setId,
      'english': sentence.english,
      'chinese': sentence.chinese,
      'extra_words': jsonEncode(sentence.extraWords),
      'created_at': DateTime.now().toIso8601String(),
    });
    await _updateSentenceCount(sentence.setId);
    notifyListeners();
  }

  Future<void> updateSentence(Sentence sentence) async {
    final db = await DatabaseService.database;
    await db.update(
      'sentences',
      {
        'english': sentence.english,
        'chinese': sentence.chinese,
        'extra_words': jsonEncode(sentence.extraWords),
      },
      where: 'id = ?',
      whereArgs: [sentence.id],
    );
    notifyListeners();
  }

  Future<void> deleteSentence(String setId, String sentenceId) async {
    final db = await DatabaseService.database;
    await db.delete('sentences', where: 'id = ?', whereArgs: [sentenceId]);
    await _updateSentenceCount(setId);
    notifyListeners();
  }

  Future<void> addSentences(String setId, List<Sentence> newSentences) async {
    final db = await DatabaseService.database;
    final now = DateTime.now().toIso8601String();
    final batch = db.batch();
    for (final s in newSentences) {
      batch.insert('sentences', {
        'id': const Uuid().v4(),
        'set_id': setId,
        'english': s.english,
        'chinese': s.chinese,
        'extra_words': jsonEncode(s.extraWords),
        'created_at': now,
      });
    }
    await batch.commit(noResult: true);
    await _updateSentenceCount(setId);
    notifyListeners();
  }

  // ===== 内部方法 =====
  Future<void> _saveSets() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = _sets.map((s) => s.toJson()).toList();
    await prefs.setString(_prefsSetsKey, jsonEncode(jsonList));
  }

  Future<void> _updateSentenceCount(String setId) async {
    final db = await DatabaseService.database;
    final count =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM sentences WHERE set_id = ?', [
            setId,
          ]),
        ) ??
        0;
    final index = _sets.indexWhere((s) => s.id == setId);
    if (index != -1) {
      _sets[index] = _sets[index].copyWith(sentenceCount: count);
      await _saveSets();
    }
  }

  static Sentence _rowToSentence(Map<String, dynamic> row) {
    return Sentence(
      id: row['id'] as String,
      setId: row['set_id'] as String,
      english: row['english'] as String,
      chinese: row['chinese'] as String,
      extraWords:
          row['extra_words'] == null || (row['extra_words'] as String).isEmpty
          ? []
          : (jsonDecode(row['extra_words'] as String) as List<dynamic>)
                .map((e) => e as String)
                .toList(),
    );
  }
}
