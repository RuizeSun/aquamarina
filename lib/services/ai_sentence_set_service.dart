import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../models/ai_sentence_set.dart';
import '../models/ai_sentence.dart';
import '../models/sync_op.dart';
import 'database_service.dart';
import 'learning_service.dart';
import 'sync_capture_service.dart';

/// 句式集管理服务（单例，各页面共享同一数据源以确保实时同步）
class SentenceSetService extends ChangeNotifier {
  static const String _prefsSetsKey = 'sentence_sets_v1';
  static const String _migrationKey = 'sentence_sets_db_migrated_v1';

  /// 全局唯一实例
  static final SentenceSetService instance = SentenceSetService._();

  final Future<Database> Function() _databaseProvider;

  SentenceSetService._() : _databaseProvider = (() => DatabaseService.database);

  /// 仅用于测试：注入数据库。
  SentenceSetService.forTesting(Future<Database> Function() databaseProvider)
    : _databaseProvider = databaseProvider;

  Future<Database> get _db => _databaseProvider();

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
    final db = await _db;
    await _migratePrefsToDb(db);
    final rows = await db.rawQuery('''
      SELECT s.*,
        (SELECT COUNT(*) FROM sentences WHERE set_id = s.id) AS actual_count
      FROM sentence_sets s
      ORDER BY s.created_at ASC
    ''');
    _sets = rows.map(_rowToSet).toList();
    _loaded = true;
    notifyListeners();
  }

  /// 把旧版 SharedPreferences 中的句式集元数据惰性迁移到 SQLite。
  ///
  /// - 迁移标记写入 Prefs，成功后不再重复；
  /// - 表中已有数据时跳过，避免重复导入；
  /// - 迁移失败不阻塞加载（旧数据仍留在 Prefs 中）。
  Future<void> _migratePrefsToDb(Database db) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_migrationKey) == true) return;

    final existing =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM sentence_sets'),
        ) ??
        0;
    if (existing == 0) {
      final jsonStr = prefs.getString(_prefsSetsKey);
      if (jsonStr != null) {
        try {
          final list = jsonDecode(jsonStr) as List<dynamic>;
          final now = DateTime.now().toIso8601String();
          await db.transaction((txn) async {
            for (final raw in list) {
              if (raw is! Map) continue;
              final set = SentenceSet.fromJson(raw.cast<String, dynamic>());
              final id = (set.id == null || set.id!.isEmpty)
                  ? const Uuid().v4()
                  : set.id!;
              final createdAt = set.createdAt?.toIso8601String() ?? now;
              await txn.insert('sentence_sets', {
                'id': id,
                'name': set.name,
                'description': set.description,
                'sentence_count': set.sentenceCount,
                'created_at': createdAt,
                'updated_at': set.updatedAt?.toIso8601String() ?? createdAt,
              }, conflictAlgorithm: ConflictAlgorithm.ignore);
            }
          });
        } catch (_) {
          // 损坏的旧数据不阻塞启动；保留 Prefs 原文便于排查
        }
      }
    }
    await prefs.setBool(_migrationKey, true);
  }

  // ===== 句式集 CRUD =====
  Future<SentenceSet> addSet(SentenceSet set) async {
    final now = DateTime.now();
    final s = set.copyWith(
      id: const Uuid().v4(),
      createdAt: now,
      updatedAt: now,
    );
    final db = await _db;
    await db.insert('sentence_sets', _setToRow(s));
    _sets.add(s);
    notifyListeners();
    return s;
  }

  Future<void> updateSet(SentenceSet set) async {
    final index = _sets.indexWhere((s) => s.id == set.id);
    if (index == -1) throw Exception('句式集不存在');
    final current = _sets[index];
    final updated = set.copyWith(
      sentenceCount: current.sentenceCount,
      updatedAt: DateTime.now(),
    );
    final db = await _db;
    await db.update(
      'sentence_sets',
      _setToRow(updated),
      where: 'id = ?',
      whereArgs: [set.id],
    );
    _sets[index] = updated;
    notifyListeners();
  }

  Future<void> deleteSet(String id) async {
    // 同时删除该句式集下的所有句子及其关联数据（避免遗留孤儿记录）
    final db = await _db;
    await db.transaction((txn) async {
      await txn.delete('sentence_sets', where: 'id = ?', whereArgs: [id]);
      await txn.delete('sentences', where: 'set_id = ?', whereArgs: [id]);
      // 清理已练标记（练过 / 已答对）与错题本中该句式集的记录
      await txn.delete(
        'practiced_sentence_ids',
        where: 'set_id = ?',
        whereArgs: [id],
      );
      await txn.delete(
        'attempted_sentence_ids',
        where: 'set_id = ?',
        whereArgs: [id],
      );
      await txn.delete('wrong_sentences', where: 'set_id = ?', whereArgs: [id]);
    });
    _sets.removeWhere((s) => s.id == id);
    LearningService.invalidateStatsCache();
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
    final db = await _db;
    final maps = await db.query(
      'sentences',
      where: 'set_id = ?',
      whereArgs: [setId],
      // 按同步顺序键排序；旧数据在 v13 迁移时已按 rowid 回填
      orderBy: 'sort_index ASC, rowid ASC',
    );
    return maps.map((m) => _rowToSentence(m)).toList();
  }

  Future<void> addSentence(Sentence sentence) async {
    final db = await _db;
    final id = const Uuid().v4();
    final nextSortIndex = await _nextSortIndex(db, sentence.setId);
    await db.insert('sentences', {
      'id': id,
      'set_id': sentence.setId,
      'english': sentence.english,
      'chinese': sentence.chinese,
      'extra_words': jsonEncode(sentence.extraWords),
      'created_at': DateTime.now().toIso8601String(),
      'sort_index': nextSortIndex,
    });
    await _updateSentenceCount(sentence.setId);
    notifyListeners();
  }

  /// 同一句式集内追加句子的顺序键。
  Future<double> _nextSortIndex(DatabaseExecutor db, String setId) async {
    final rows = await db.rawQuery(
      'SELECT COALESCE(MAX(sort_index), 0) AS m FROM sentences '
      'WHERE set_id = ?',
      [setId],
    );
    final maxValue = (rows.first['m'] as num?)?.toDouble() ?? 0;
    return maxValue + 1;
  }

  Future<void> updateSentence(Sentence sentence) async {
    final db = await _db;
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
    final db = await _db;
    await db.transaction((txn) async {
      await txn.delete('sentences', where: 'id = ?', whereArgs: [sentenceId]);
      // 同步清理该句的练习进度与错题，避免删除后进度超过总数 / 错题本残留
      await txn.delete(
        'practiced_sentence_ids',
        where: 'set_id = ? AND sentence_id = ?',
        whereArgs: [setId, sentenceId],
      );
      await txn.delete(
        'attempted_sentence_ids',
        where: 'set_id = ? AND sentence_id = ?',
        whereArgs: [setId, sentenceId],
      );
      await txn.delete(
        'wrong_sentences',
        where: 'sentence_id = ?',
        whereArgs: [sentenceId],
      );
    });
    await _updateSentenceCount(setId);
    LearningService.invalidateStatsCache();
    notifyListeners();
  }

  Future<void> addSentences(String setId, List<Sentence> newSentences) async {
    final db = await _db;
    final now = DateTime.now().toIso8601String();
    final useFastPath =
        newSentences.length >= 500 &&
        await SyncCaptureService.isCaptureEnabled(db: db);
    var sortIndex = await _nextSortIndex(db, setId);
    final pending = <({String id, Sentence sentence, double sortIndex})>[];
    for (final sentence in newSentences) {
      pending.add((
        id: const Uuid().v4(),
        sentence: sentence,
        sortIndex: sortIndex,
      ));
      sortIndex += 1;
    }
    await db.transaction((txn) async {
      if (useFastPath) {
        await txn.update('sync_meta', {'capture_enabled': 0}, where: 'id = 1');
      }
      final batch = txn.batch();
      for (final item in pending) {
        final s = item.sentence;
        batch.insert('sentences', {
          'id': item.id,
          'set_id': setId,
          'english': s.english,
          'chinese': s.chinese,
          'extra_words': jsonEncode(s.extraWords),
          'created_at': now,
          'sort_index': item.sortIndex,
        });
      }
      await batch.commit(noResult: true);
      if (useFastPath) {
        final items = [
          for (final item in pending)
            SyncBulkItem(
              entity: 'sentences',
              key: {'id': item.id},
              data: {
                'set_id': setId,
                'english': item.sentence.english,
                'chinese': item.sentence.chinese,
                'extra_words': jsonEncode(item.sentence.extraWords),
                'created_at': now,
                'sort_index': item.sortIndex,
              },
            ),
        ];
        for (var i = 0; i < items.length; i += 1000) {
          final end = (i + 1000) > items.length ? items.length : i + 1000;
          await SyncCaptureService.recordBulk(txn, items.sublist(i, end));
        }
        await txn.update('sync_meta', {'capture_enabled': 1}, where: 'id = 1');
      }
    });
    await _updateSentenceCount(setId);
    notifyListeners();
  }

  // ===== 句式集导出 / 导入 =====

  /// 导出单个句式集为 JSON 字符串
  ///
  /// 包含句式集元数据（名称/描述）与全部句子（英文原句/中文翻译/多余词）。
  /// 可通过 [importSetFromJson] 重新导入。
  Future<String> exportSetToJson(String setId) async {
    final set = getSet(setId);
    if (set == null) {
      throw SentenceSetException('句式集不存在或已被删除');
    }
    final sentences = await getSentences(setId);

    return jsonEncode({
      'app': 'aquamarina',
      'type': 'sentence_set',
      'version': 1,
      'created_at': DateTime.now().toIso8601String(),
      'set': {
        'name': set.name,
        'description': set.description,
        'sentences': sentences
            .map(
              (s) => {
                'english': s.english,
                'chinese': s.chinese,
                'extra_words': s.extraWords,
              },
            )
            .toList(),
      },
    });
  }

  /// 从 JSON 字符串导入单个句式集
  ///
  /// 返回新创建的句式集 ID。名称冲突时自动添加序号（类似 Windows 重命名）。
  /// JSON 格式不合法或不是句式集文件时抛出 [SentenceSetException]。
  Future<String> importSetFromJson(String jsonStr) async {
    final dynamic decoded;
    try {
      decoded = jsonDecode(jsonStr);
    } catch (_) {
      throw const SentenceSetException('文件不是有效的 JSON 格式');
    }

    if (decoded is! Map<String, dynamic>) {
      throw const SentenceSetException('句式集文件格式错误：顶层不是对象');
    }
    if (decoded['app'] != 'aquamarina' || decoded['type'] != 'sentence_set') {
      throw const SentenceSetException('不是有效的 Aquamarina 句式集文件');
    }
    final setData = decoded['set'];
    if (setData is! Map<String, dynamic>) {
      throw const SentenceSetException('句式集文件缺少 set 数据');
    }

    final name = setData['name'] as String?;
    if (name == null || name.trim().isEmpty) {
      throw const SentenceSetException('句式集文件缺少名称');
    }

    // 名称冲突时自动加序号
    final uniqueName = generateUniqueSetName(name.trim());
    final newSet = await addSet(
      SentenceSet(
        name: uniqueName,
        description: (setData['description'] as String?)?.trim(),
      ),
    );
    final setId = newSet.id!;

    final sentencesRaw = setData['sentences'];
    if (sentencesRaw is List) {
      final sentences = <Sentence>[];
      for (final raw in sentencesRaw) {
        if (raw is Map<String, dynamic>) {
          final english = (raw['english'] as String?)?.trim();
          final chinese = (raw['chinese'] as String?)?.trim();
          if (english != null &&
              english.isNotEmpty &&
              chinese != null &&
              chinese.isNotEmpty) {
            final extraRaw = raw['extra_words'];
            final extraWords = extraRaw is List
                ? extraRaw.whereType<String>().toList()
                : <String>[];
            sentences.add(
              Sentence(
                setId: setId,
                english: english,
                chinese: chinese,
                extraWords: extraWords,
              ),
            );
          }
        }
      }
      if (sentences.isNotEmpty) {
        await addSentences(setId, sentences);
      }
    }

    return setId;
  }

  // ===== 内部方法 =====
  static Map<String, Object?> _setToRow(SentenceSet set) {
    return {
      'id': set.id,
      'name': set.name,
      'description': set.description,
      'sentence_count': set.sentenceCount,
      'created_at': set.createdAt?.toIso8601String(),
      'updated_at': set.updatedAt?.toIso8601String(),
    };
  }

  static SentenceSet _rowToSet(Map<String, Object?> row) {
    final count =
        (row['actual_count'] as num?)?.toInt() ??
        (row['sentence_count'] as num?)?.toInt() ??
        0;
    final createdAt = row['created_at'] as String?;
    final updatedAt = row['updated_at'] as String?;
    return SentenceSet(
      id: row['id'] as String,
      name: row['name'] as String,
      description: row['description'] as String?,
      sentenceCount: count,
      createdAt: createdAt == null ? null : DateTime.tryParse(createdAt),
      updatedAt: updatedAt == null ? null : DateTime.tryParse(updatedAt),
    );
  }

  Future<void> _updateSentenceCount(String setId) async {
    final db = await _db;
    final count =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM sentences WHERE set_id = ?', [
            setId,
          ]),
        ) ??
        0;
    final index = _sets.indexWhere((s) => s.id == setId);
    if (index != -1) {
      final now = DateTime.now();
      await db.update(
        'sentence_sets',
        {'sentence_count': count, 'updated_at': now.toIso8601String()},
        where: 'id = ?',
        whereArgs: [setId],
      );
      _sets[index] = _sets[index].copyWith(
        sentenceCount: count,
        updatedAt: now,
      );
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

/// 将句式集文件的原始字节解码为 UTF-8 文本。
///
/// 说明：移动端（尤其 Android）通过 file_selector 选中的文件是“字节版”
/// XFile，其 [XFile.readAsString] 会把每个字节当成一个码位逐字节解码，
/// 导致 UTF-8/GBK 中文统统变成乱码。因此这里统一改为读取原始字节后按
/// UTF-8 显式解码，并剥离 UTF-8 BOM。
///
/// 若文件不是 UTF-8 编码（如 GBK/ANSI），会抛出带提示的
/// [SentenceSetException]，而不是静默导入乱码数据。
String decodeSentenceSetFileBytes(List<int> bytes) {
  // 剥离 UTF-8 BOM（EF BB BF），避免开头 U+FEFF 导致 JSON 解析失败。
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    bytes = bytes.sublist(3);
  }

  try {
    // 严格解码：非法字节序列会抛 FormatException，绝不产生静默乱码。
    return utf8.decode(bytes);
  } on FormatException {
    throw const SentenceSetException(
      '句式集文件不是 UTF-8 编码，中文内容无法解析。'
      '请用支持 UTF-8 的编辑器打开并“另存为 UTF-8”后重新导入。',
    );
  }
}

/// 句式集操作异常
class SentenceSetException implements Exception {
  final String message;
  const SentenceSetException(this.message);

  @override
  String toString() => message;
}
