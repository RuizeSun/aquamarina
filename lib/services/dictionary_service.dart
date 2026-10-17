import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:archive/archive.dart';
import '../models/word_entry.dart';
import 'log_service.dart';

/// 统一搜索结果，包含英汉双词典的匹配
class CombinedResult {
  final WordEntry? enEntry;
  final CedictEntry? cnEntry;

  CombinedResult({this.enEntry, this.cnEntry});

  bool get hasAny => enEntry != null || cnEntry != null;
}

class DictionaryService {
  /// 单条 SQL 中 `IN (...)` 的最大绑定参数个数。
  ///
  /// SQLite 默认上限为 32766（旧构建为 999），超出会直接报错；
  /// 分批查询既能规避上限，也避免一次性绑定过多参数带来的解析与规划开销。
  static const int _maxQueryChunkSize = 900;

  // ─── 数据库实例与并发锁 ────────────────────────────────
  static Database? _enDb; // ECDict (英英/英汉)
  static Database? _cnDb; // CEDict (汉英)

  /// 初始化 Future，防止 enDb 的并发重复初始化
  static Future<void>? _enDbInitFuture;

  /// 初始化 Future，防止 cnDb 的并发重复初始化
  static Future<void>? _cnDbInitFuture;

  /// 解压 Future，防止 databases.zip 的并发重复解压
  static Future<void>? _extractFuture;

  /// 词典准备状态：首次启动解压期间供 UI 展示提示。
  static final ValueNotifier<String?> preparationStatus =
      ValueNotifier<String?>(null);

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

  /// 从 assets 中的 databases.zip 解压出所有数据库文件（仅执行一次）
  /// 失败时重置 [_extractFuture]，允许后续调用重试
  static Future<void> _ensureExtracted() async {
    _extractFuture ??= _doExtract();
    try {
      await _extractFuture;
    } catch (_) {
      _extractFuture = null;
      rethrow;
    }
  }

  /// 词典数据库文件名（顺序仅供校验/日志使用）
  static const List<String> _dictionaryDbNames = ['ec_dict.db', 'ce_dict.db'];

  /// SQLite 数据库文件头（16 字节）
  static const String _sqliteHeader = 'SQLite format 3\u0000';

  static Future<void> _doExtract() async {
    final dir = await getApplicationSupportDirectory();
    final directoryPath = dir.path;

    // 只有「完整且可识别」的数据库才跳过解压。
    // 旧实现仅检查文件是否存在：若上次解压中途被杀，会留下半截文件，
    // 之后永远认为已解压成功，词典查询持续报 malformed。
    var allValid = true;
    for (final name in _dictionaryDbNames) {
      if (!await _isValidSqliteFile(p.join(directoryPath, name))) {
        allValid = false;
        break;
      }
    }
    if (allValid) return;

    preparationStatus.value = '正在准备词典（首次启动需要解压）…';
    try {
      // 清理损坏文件与可能残留的临时文件
      for (final name in _dictionaryDbNames) {
        await _deleteIfExists(p.join(directoryPath, name));
        await _deleteIfExists(p.join(directoryPath, '$name.tmp'));
      }

      final zipPath = p.join(directoryPath, 'databases.zip.tmp');
      await _deleteIfExists(zipPath);

      final byteData = await rootBundle.load('assets/databases.zip');
      final bytes = byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );
      await File(zipPath).writeAsBytes(bytes, flush: true);

      try {
        // 解压放到后台 isolate：zip 解压后约 133MB，在主 isolate 同步执行
        // 会直接卡住 UI（首启数秒甚至 ANR）。
        await Isolate.run(() => _extractDictionaryZip(zipPath, directoryPath));
      } finally {
        await _deleteIfExists(zipPath);
      }

      // 解压完成后再次校验，避免写盘失败/磁盘满导致半截文件被长期使用
      for (final name in _dictionaryDbNames) {
        final path = p.join(directoryPath, name);
        if (!await _isValidSqliteFile(path)) {
          await _deleteIfExists(path);
          throw FileSystemException('词典数据库解压后校验失败，请重试', path);
        }
      }
      logInfo('DictionaryService', '词典数据库解压完成');
    } finally {
      preparationStatus.value = null;
    }
  }

  /// 在后台 isolate 中执行的实际解压逻辑。
  ///
  /// 只依赖 `dart:io` / `archive`，不访问 Flutter 绑定；
  /// 使用 `InputFileStream` + `OutputFileStream` 流式解压，
  /// 同一时刻只持有一个文件的压缩/解压缓冲，避免把 133MB 全部读入内存。
  static Future<void> _extractDictionaryZip(
    String zipPath,
    String directoryPath,
  ) async {
    final archive = ZipDecoder().decodeStream(
      InputFileStream(zipPath),
      verify: true,
    );
    try {
      for (final entry in archive) {
        if (!entry.isFile) continue;
        // 取 basename，避免 zip 内路径穿越写入目录外
        final name = p.basename(entry.name);
        if (!_dictionaryDbNames.contains(name)) continue;

        final targetPath = p.join(directoryPath, name);
        final tmpPath = '$targetPath.tmp';
        final output = OutputFileStream(tmpPath);
        try {
          entry.writeContent(output);
        } finally {
          await output.close();
        }
        entry.closeSync();

        final target = File(targetPath);
        if (await target.exists()) await target.delete();
        await File(tmpPath).rename(targetPath);
      }
    } finally {
      archive.clearSync();
    }
  }

  /// 校验文件是否为完整的 SQLite 数据库（文件头魔数 + 最小长度）
  static Future<bool> _isValidSqliteFile(String path) async {
    final file = File(path);
    if (!await file.exists()) return false;
    if (await file.length() < 512) return false;

    final raf = await file.open();
    try {
      final header = await raf.read(_sqliteHeader.length);
      if (header.length < _sqliteHeader.length) return false;
      for (var i = 0; i < _sqliteHeader.length; i++) {
        if (header[i] != _sqliteHeader.codeUnitAt(i)) return false;
      }
      return true;
    } finally {
      await raf.close();
    }
  }

  static Future<void> _deleteIfExists(String path) async {
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  }

  static Future<Database> _openEnDb() async {
    await _initFfi();
    await _ensureExtracted();
    final dir = await getApplicationSupportDirectory();
    final path = p.join(dir.path, 'ec_dict.db');
    return await openDatabase(path, readOnly: true);
  }

  static Future<Database> _openCnDb() async {
    await _initFfi();
    await _ensureExtracted();
    final dir = await getApplicationSupportDirectory();
    final path = p.join(dir.path, 'ce_dict.db');
    return await openDatabase(path, readOnly: true);
  }

  /// 获取英英/英汉词典数据库（线程安全，防并发重复初始化）
  /// 初始化失败时重置 [_enDbInitFuture]，之后调用可重新尝试
  static Future<Database> get enDb async {
    if (_enDb != null) return _enDb!;
    _enDbInitFuture ??= _openEnDb().then((db) {
      _enDb = db;
      logInfo('DictionaryService', '英汉词典数据库打开成功');
    });
    try {
      await _enDbInitFuture;
    } catch (_) {
      _enDbInitFuture = null;
      rethrow;
    }
    return _enDb!;
  }

  /// 获取汉英词典数据库（线程安全，防并发重复初始化）
  /// 初始化失败时重置 [_cnDbInitFuture]，之后调用可重新尝试
  static Future<Database> get cnDb async {
    if (_cnDb != null) return _cnDb!;
    _cnDbInitFuture ??= _openCnDb().then((db) {
      _cnDb = db;
      logInfo('DictionaryService', '汉英词典数据库打开成功');
    });
    try {
      await _cnDbInitFuture;
    } catch (_) {
      _cnDbInitFuture = null;
      rethrow;
    }
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

    // 仅按 word 排序(而非 CASE/LENGTH)：可命中 word 索引、避免对整张表
    // 做 NOCASE 全量扫描 + 临时 B 树排序(原实现每次键入约 100ms)。
    // 仍保留 COLLATE NOCASE，大小写不敏感语义不变；前缀的精确/最短词
    // 在 word 序中天然靠前。
    final maps = await db.rawQuery(
      'SELECT * FROM dictionary '
      'WHERE word LIKE ? COLLATE NOCASE '
      'ORDER BY word '
      'LIMIT 30',
      ['$trimmed%'],
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

    // 拆成两路各自命中 simplified / traditional 索引的前缀查询，再在内存中
    // 去重合并；避免原 OR(跨列)无法走索引、匹配稀少时全表扫描约 12ms 的代价。
    final pattern = '$trimmed%';
    final simpMaps = await db.rawQuery(
      'SELECT * FROM entries WHERE simplified LIKE ? '
      'ORDER BY simplified LIMIT 20',
      [pattern],
    );
    final tradMaps = await db.rawQuery(
      'SELECT * FROM entries WHERE traditional LIKE ? '
      'ORDER BY traditional LIMIT 20',
      [pattern],
    );

    final seen = <int>{};
    final entries = <CedictEntry>[];
    for (final m in simpMaps) {
      if (seen.add(m['id'] as int)) entries.add(CedictEntry.fromMap(m));
    }
    for (final m in tradMaps) {
      if (seen.add(m['id'] as int)) entries.add(CedictEntry.fromMap(m));
    }
    if (entries.length > 20) {
      return entries.sublist(0, 20);
    }
    return entries;
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

  /// 批量精确查询英英/英汉词典
  ///
  /// 使用 WHERE word IN (...) 一次查询多个单词，替代逐词循环；
  /// 单词数超过 [_maxQueryChunkSize] 时自动分批查询后合并结果，
  /// 粘贴数万单词时也不会因参数过多而失败。
  static Future<Map<String, WordEntry>> searchEnExactBatch(
    List<String> words,
  ) async {
    if (words.isEmpty) return {};
    final cleaned = words.map((w) => w.trim().toLowerCase()).toSet().toList();
    final db = await enDb;
    final result = <String, WordEntry>{};
    for (var start = 0; start < cleaned.length; start += _maxQueryChunkSize) {
      final chunk = cleaned.skip(start).take(_maxQueryChunkSize).toList();
      final placeholders = List.filled(chunk.length, '?').join(',');
      final maps = await db.rawQuery(
        'SELECT * FROM dictionary WHERE word IN ($placeholders) COLLATE NOCASE',
        chunk,
      );
      for (final m in maps) {
        final entry = WordEntry.fromMap(m);
        result[entry.word.toLowerCase()] = entry;
      }
    }
    return result;
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
  /// 同时重置初始化 Future，避免再次访问时返回已关闭的连接
  static Future<void> close() async {
    if (_enDb != null) {
      await _enDb!.close();
      _enDb = null;
    }
    if (_cnDb != null) {
      await _cnDb!.close();
      _cnDb = null;
    }
    _enDbInitFuture = null;
    _cnDbInitFuture = null;
    // 同样重置解压 Future，允许关闭后重新解压
    _extractFuture = null;
  }
}
