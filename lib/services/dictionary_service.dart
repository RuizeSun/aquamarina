import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:archive/archive.dart';
import '../models/word_entry.dart';

/// 统一搜索结果，包含英汉双词典的匹配
class CombinedResult {
  final WordEntry? enEntry;
  final CedictEntry? cnEntry;

  CombinedResult({this.enEntry, this.cnEntry});

  bool get hasAny => enEntry != null || cnEntry != null;
}

class DictionaryService {
  static Database? _enDb; // ECDict (英英/英汉)
  static Database? _cnDb; // CEDict (汉英)

  // ─── 初始化 ──────────────────────────────────────────

  static Future<void> _initFfi() async {
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.macOS)) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
  }

  /// 从 assets 中的 databases.zip 解压出所需的数据库文件
  static Future<String> _getDbPath(String dbName) async {
    final dir = await getApplicationSupportDirectory();
    final filePath = p.join(dir.path, dbName);
    final file = File(filePath);
    if (!await file.exists()) {
      final byteData = await rootBundle.load('assets/databases.zip');
      final bytes = byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );
      final archive = ZipDecoder().decodeBytes(bytes);
      for (final entry in archive) {
        if (entry.isFile) {
          final entryPath = p.join(dir.path, entry.name);
          await File(entryPath).writeAsBytes(entry.content as List<int>);
        }
      }
    }
    return filePath;
  }

  static Future<Database> _openEnDb() async {
    await _initFfi();
    final path = await _getDbPath('ec_dict.db');
    return await openDatabase(path, readOnly: true);
  }

  static Future<Database> _openCnDb() async {
    await _initFfi();
    final path = await _getDbPath('ce_dict.db');
    return await openDatabase(path, readOnly: true);
  }

  static Future<Database> get enDb async {
    if (_enDb != null) return _enDb!;
    _enDb = await _openEnDb();
    return _enDb!;
  }

  static Future<Database> get cnDb async {
    if (_cnDb != null) return _cnDb!;
    _cnDb = await _openCnDb();
    return _cnDb!;
  }

  // ─── 英英/英汉词典 (ECDict) ─────────────────────────

  static Future<WordEntry?> searchEnExact(String word) async {
    final db = await enDb;
    final maps = await db.query(
      'dictionary',
      where: 'word = ? COLLATE NOCASE',
      whereArgs: [word.trim()],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return WordEntry.fromMap(maps.first);
  }

  static Future<List<WordEntry>> searchEnFuzzy(String prefix) async {
    final db = await enDb;
    final trimmed = prefix.trim();
    if (trimmed.isEmpty) return [];

    final maps = await db.rawQuery(
      'SELECT * FROM dictionary '
      'WHERE word LIKE ? COLLATE NOCASE '
      'ORDER BY CASE WHEN word = ? THEN 0 ELSE 1 END, LENGTH(word), word '
      'LIMIT 30',
      ['$trimmed%', trimmed],
    );
    return maps.map((m) => WordEntry.fromMap(m)).toList();
  }

  // ─── 汉英词典 (CEDict) ──────────────────────────────

  static Future<CedictEntry?> searchCnExact(String word) async {
    final db = await cnDb;
    // 同时匹配简体/繁体
    final maps = await db.query(
      'entries',
      where: 'simplified = ? OR traditional = ?',
      whereArgs: [word.trim(), word.trim()],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return CedictEntry.fromMap(maps.first);
  }

  static Future<List<CedictEntry>> searchCnFuzzy(String prefix) async {
    final db = await cnDb;
    final trimmed = prefix.trim();
    if (trimmed.isEmpty) return [];

    final maps = await db.rawQuery(
      'SELECT * FROM entries '
      'WHERE simplified LIKE ? OR traditional LIKE ? '
      'ORDER BY '
      '  CASE WHEN simplified = ? THEN 0 '
      '       WHEN traditional = ? THEN 1 '
      '  ELSE 2 END, '
      '  LENGTH(simplified) '
      'LIMIT 20',
      ['$trimmed%', '$trimmed%', trimmed, trimmed],
    );
    return maps.map((m) => CedictEntry.fromMap(m)).toList();
  }

  // ─── 统一搜索接口 ────────────────────────────────────

  /// 统一前缀搜索（英+汉同时查询，合并排序）
  static Future<List<SearchResult>> searchAllFuzzy(String prefix) async {
    final trimmed = prefix.trim();
    if (trimmed.isEmpty) return [];

    final results = <SearchResult>[];
    final futures = <Future<void>>[
      () async {
        final en = await searchEnFuzzy(trimmed);
        for (final e in en) {
          results.add(SearchResult.enWord(e));
        }
      }(),
      () async {
        final cn = await searchCnFuzzy(trimmed);
        for (final c in cn) {
          results.add(SearchResult.cnWord(c));
        }
      }(),
    ];
    await Future.wait(futures);

    // 排序：精确匹配优先，然后按长度
    results.sort((a, b) {
      final aExact = a.displayWord == trimmed;
      final bExact = b.displayWord == trimmed;
      if (aExact && !bExact) return -1;
      if (!aExact && bExact) return 1;
      return a.displayWord.length.compareTo(b.displayWord.length);
    });

    // 限制总数
    if (results.length > 50) {
      return results.sublist(0, 50);
    }
    return results;
  }

  /// 统一精确搜索（同时查询两个词典）
  static Future<CombinedResult> searchAllExact(String word) async {
    final trimmed = word.trim();
    final futures = [searchEnExact(trimmed), searchCnExact(trimmed)];
    final results = await Future.wait(futures);
    return CombinedResult(
      enEntry: results[0] as WordEntry?,
      cnEntry: results[1] as CedictEntry?,
    );
  }

  /// 关闭所有数据库
  static Future<void> close() async {
    if (_enDb != null) {
      await _enDb!.close();
      _enDb = null;
    }
    if (_cnDb != null) {
      await _cnDb!.close();
      _cnDb = null;
    }
  }
}
