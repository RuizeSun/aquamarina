import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_service.dart';

/// 备份文件格式：ZIP
///
///   - `aquamarina.db`         业务数据库（词书/学习记录/句子等）
///   - `preferences.json`      SharedPreferences 全量（带类型标记）
///   - `secure_storage.json`   AI API Keys（可选，导出时由用户勾选）
///   - `backup_meta.json`      元信息（应用名/创建时间等）
///
/// 注意：内置词典数据库（ec_dict.db / ce_dict.db）不属于用户数据，
/// 不在备份范围内。
class BackupService {
  BackupService._();

  static const String dbFileName = 'aquamarina.db';
  static const String _prefsFileName = 'preferences.json';
  static const String _secureFileName = 'secure_storage.json';
  static const String _metaFileName = 'backup_meta.json';

  /// 导入的备份文件大小上限（防滥用，正常备份远小于此值）
  static const int _maxBackupSize = 500 * 1024 * 1024;

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();

  // ── 导出 ─────────────────────────────────────────────

  /// 生成完整备份数据（ZIP 字节流）。
  ///
  /// [includeApiKeys] 为 true 时包含 AI API Keys（敏感信息）。
  ///
  /// 数据库通过“关闭连接 → 拷贝文件 → 重新打开”的方式导出，
  /// 确保拷贝时没有未合并进主文件的 WAL 事务，备份数据完整。
  static Future<Uint8List> exportBackup({required bool includeApiKeys}) async {
    final archive = Archive();

    // 1. 业务数据库
    final dir = await getApplicationSupportDirectory();
    final dbFile = File(p.join(dir.path, dbFileName));
    if (await dbFile.exists()) {
      await DatabaseService.close();
      try {
        archive.addFile(
          ArchiveFile.bytes(dbFileName, await dbFile.readAsBytes()),
        );
      } finally {
        // 立即重新打开数据库，恢复业务功能
        await DatabaseService.database;
      }
    }

    // 2. SharedPreferences
    archive.addFile(
      ArchiveFile.string(_prefsFileName, await _exportPreferences()),
    );

    // 3. AI API Keys（可选）
    if (includeApiKeys) {
      archive.addFile(
        ArchiveFile.string(_secureFileName, await _exportSecureStorage()),
      );
    }

    // 4. 元信息
    archive.addFile(
      ArchiveFile.string(
        _metaFileName,
        jsonEncode({
          'app': 'aquamarina',
          'created_at': DateTime.now().toIso8601String(),
          'contains_api_keys': includeApiKeys,
        }),
      ),
    );

    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  /// 序列化 SharedPreferences：为每个 key 附带类型标记，保证恢复时类型不丢失。
  static Future<String> _exportPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final map = <String, dynamic>{};
    for (final key in prefs.getKeys()) {
      final value = prefs.get(key);
      if (value is String) {
        map[key] = {'t': 's', 'v': value};
      } else if (value is bool) {
        map[key] = {'t': 'b', 'v': value};
      } else if (value is int) {
        map[key] = {'t': 'i', 'v': value};
      } else if (value is double) {
        map[key] = {'t': 'd', 'v': value};
      } else if (value is List<String>) {
        map[key] = {'t': 'l', 'v': value};
      }
    }
    return jsonEncode(map);
  }

  /// 读取 AI API Keys。
  ///
  /// Secure Storage 无法枚举所有 key，因此通过已知的 key 约定导出：
  ///   - `ai_api_key`（旧版 AiConfigService）
  ///   - `ai_api_key_<profileId>`（AiProfileService._secureKeyFor）
  /// 若后续新增 key 约定，需同步维护此处。
  static Future<String> _exportSecureStorage() async {
    final map = <String, String>{};

    final legacy = await _readSecure('ai_api_key');
    if (legacy != null && legacy.isNotEmpty) {
      map['ai_api_key'] = legacy;
    }

    final prefs = await SharedPreferences.getInstance();
    final profilesJson = prefs.getString('ai_profiles_v2');
    if (profilesJson != null) {
      try {
        final list = jsonDecode(profilesJson) as List<dynamic>;
        for (final item in list) {
          final id = (item as Map<String, dynamic>)['id'] as String?;
          if (id == null || id.isEmpty) continue;
          final key = 'ai_api_key_$id';
          final value = await _readSecure(key);
          if (value != null && value.isNotEmpty) {
            map[key] = value;
          }
        }
      } catch (_) {
        // profiles 数据损坏时忽略，仅导出能读到的 key
      }
    }
    return jsonEncode(map);
  }

  static Future<String?> _readSecure(String key) async {
    try {
      return await _secureStorage.read(key: key);
    } catch (_) {
      return null;
    }
  }

  // ── 导入 ─────────────────────────────────────────────

  /// 从备份 ZIP 字节流恢复数据（覆盖式）。
  ///
  /// 执行顺序保证数据安全：
  ///   1. 解压并校验（CRC + 大小限制 + 必需文件 + SQLite 头 + JSON 结构）
  ///   2. 全部校验通过后，先关闭数据库，原子替换数据库文件
  ///   3. 恢复 SharedPreferences 与（可选）Secure Storage
  ///   4. 重新打开数据库
  ///
  /// 任何校验失败都会在触碰现有数据之前抛出 [BackupException]。
  static Future<BackupImportResult> importBackup(Uint8List bytes) async {
    // ── 1. 解压与校验 ─────────────────────────────
    if (bytes.length > _maxBackupSize) {
      throw const BackupException('备份文件过大，拒绝导入');
    }

    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes, verify: true);
    } on ArchiveException {
      throw const BackupException('文件不是有效的备份文件（ZIP 解析失败）');
    }

    final dbEntry = archive.findFile(dbFileName);
    if (dbEntry == null) {
      throw const BackupException('备份文件缺少 aquamarina.db，无法导入');
    }
    final dbBytes = dbEntry.content as List<int>;
    if (!_isSqliteHeader(dbBytes)) {
      throw const BackupException('备份中的数据库文件无效，拒绝导入');
    }
    if (dbBytes.length > _maxBackupSize) {
      throw const BackupException('备份中的数据库文件过大，拒绝导入');
    }

    // 校验元信息（可选；旧备份可能没有）
    final metaEntry = archive.findFile(_metaFileName);
    if (metaEntry != null) {
      try {
        final meta =
            jsonDecode(utf8.decode(metaEntry.content as List<int>))
                as Map<String, dynamic>;
        if (meta['app'] != 'aquamarina') {
          throw const BackupException('不是 Aquamarina 的备份文件');
        }
      } catch (e) {
        if (e is BackupException) rethrow;
        throw const BackupException('备份文件的元信息损坏');
      }
    }

    // 解析并校验 SharedPreferences（不触碰现有数据）
    final hasPrefsEntry = archive.findFile(_prefsFileName) != null;
    var prefsEntries = const <MapEntry<String, Object?>>[];
    if (hasPrefsEntry) {
      try {
        prefsEntries = _parsePreferences(
          utf8.decode(archive.findFile(_prefsFileName)!.content as List<int>),
        );
      } on FormatException catch (e) {
        throw BackupException('备份文件中的设置数据损坏：${e.message}');
      }
    }

    // 解析并校验 Secure Storage（不触碰现有数据）
    Map<String, String> secureMap = const {};
    final hasSecureEntry = archive.findFile(_secureFileName) != null;
    if (hasSecureEntry) {
      try {
        final decoded = jsonDecode(
          utf8.decode(archive.findFile(_secureFileName)!.content as List<int>),
        );
        if (decoded is! Map) {
          throw const FormatException('JSON 顶层不是对象');
        }
        for (final e in decoded.entries) {
          if (e.key is! String || e.value is! String) {
            throw const FormatException('API Key 数据格式错误');
          }
        }
        secureMap = decoded.cast<String, String>();
      } on FormatException catch (e) {
        throw BackupException('备份文件中的 API Key 数据损坏：${e.message}');
      } catch (_) {
        throw const BackupException('备份文件中的 API Key 数据损坏');
      }
    }

    // ── 2. 校验全部通过，开始写入 ──────────────────
    final dir = await getApplicationSupportDirectory();
    final dbPath = p.join(dir.path, dbFileName);

    // 先为现有数据库留一份回滚副本
    final bakPath = '$dbPath.bak';
    if (await File(dbPath).exists()) {
      await File(dbPath).copy(bakPath);
    }

    try {
      await DatabaseService.close();

      // 2a. 原子替换数据库文件（临时文件 + rename，避免写坏唯一副本）
      final tmpPath = '$dbPath.import_tmp';
      await File(tmpPath).writeAsBytes(dbBytes, flush: true);
      await File(tmpPath).rename(dbPath);
      // 清理可能残留的 WAL/SHM 文件，避免与旧连接冲突
      for (final suffix in ['-wal', '-shm']) {
        final sidecar = File('$dbPath$suffix');
        if (await sidecar.exists()) {
          await sidecar.delete();
        }
      }

      // 2b. 恢复 SharedPreferences（entry 存在时总是清空并写入，含空对象）
      if (hasPrefsEntry) {
        await _restorePreferences(prefsEntries);
      }

      // 2c. 恢复 Secure Storage
      if (hasSecureEntry) {
        await _restoreSecureStorage(secureMap);
      }

      // 2d. 立即重新打开数据库
      try {
        await DatabaseService.database;
      } catch (_) {
        throw const BackupException('数据库文件已替换，但打开失败，请重启应用');
      }
    } catch (e) {
      // 回滚：恢复导入前的数据库
      try {
        await DatabaseService.close();
        final current = File(dbPath);
        if (await current.exists()) {
          await current.delete();
        }
        if (await File(bakPath).exists()) {
          await File(bakPath).rename(dbPath);
        }
      } catch (_) {
        // 回滚失败时保留现场，交由用户处理
      }
      rethrow;
    } finally {
      final bak = File(bakPath);
      if (await bak.exists()) {
        await bak.delete();
      }
    }

    return BackupImportResult(restoredApiKeys: hasSecureEntry);
  }

  /// 解析 preferences.json 并校验所有条目结构与类型。
  /// 任何异常都以 [FormatException] 抛出，此时不产生任何写入。
  static List<MapEntry<String, Object?>> _parsePreferences(String json) {
    final raw = jsonDecode(json);
    if (raw is! Map) {
      throw const FormatException('JSON 顶层不是对象');
    }
    final result = <MapEntry<String, Object?>>[];
    for (final e in raw.entries) {
      final key = e.key.toString();
      final item = e.value;
      if (item is! Map || item['t'] == null || !item.containsKey('v')) {
        throw FormatException('条目 "$key" 格式错误');
      }
      final type = item['t'];
      final value = item['v'];
      switch (type) {
        case 's':
          if (value is! String) throw FormatException('条目 "$key" 类型错误');
          result.add(MapEntry(key, value));
          break;
        case 'b':
          if (value is! bool) throw FormatException('条目 "$key" 类型错误');
          result.add(MapEntry(key, value));
          break;
        case 'i':
          if (value is! num) throw FormatException('条目 "$key" 类型错误');
          result.add(MapEntry(key, value.toInt()));
          break;
        case 'd':
          if (value is! num) throw FormatException('条目 "$key" 类型错误');
          result.add(MapEntry(key, value.toDouble()));
          break;
        case 'l':
          if (value is! List || value.any((v) => v is! String)) {
            throw FormatException('条目 "$key" 类型错误');
          }
          result.add(MapEntry(key, value.cast<String>()));
          break;
        default:
          throw FormatException('条目 "$key" 存在未知类型 "$type"');
      }
    }
    return result;
  }

  static Future<void> _restorePreferences(
    List<MapEntry<String, Object?>> entries,
  ) async {
    final prefs = await SharedPreferences.getInstance();

    // 清空现有设置
    for (final key in prefs.getKeys()) {
      await prefs.remove(key);
    }

    // 写入备份条目
    for (final e in entries) {
      final value = e.value;
      if (value is String) {
        await prefs.setString(e.key, value);
      } else if (value is bool) {
        await prefs.setBool(e.key, value);
      } else if (value is int) {
        await prefs.setInt(e.key, value);
      } else if (value is double) {
        await prefs.setDouble(e.key, value);
      } else if (value is List<String>) {
        await prefs.setStringList(e.key, value);
      }
    }
  }

  static Future<void> _restoreSecureStorage(Map<String, String> backup) async {
    // 清理现有的已知 key（配置列表此时已从备份恢复，以其为准）
    final prefs = await SharedPreferences.getInstance();
    final keysToClear = <String>{'ai_api_key'};
    final profilesJson = prefs.getString('ai_profiles_v2');
    if (profilesJson != null) {
      try {
        final list = jsonDecode(profilesJson) as List<dynamic>;
        for (final item in list) {
          final id = (item as Map<String, dynamic>)['id'] as String?;
          if (id != null && id.isNotEmpty) {
            keysToClear.add('ai_api_key_$id');
          }
        }
      } catch (_) {}
    }
    for (final key in keysToClear) {
      try {
        await _secureStorage.delete(key: key);
      } catch (_) {}
    }

    // 写入备份中的 key
    for (final entry in backup.entries) {
      try {
        await _secureStorage.write(key: entry.key, value: entry.value);
      } catch (_) {}
    }
  }

  // ── 清除全部数据 ─────────────────────────────────────

  /// 清除全部用户数据（数据库、SharedPreferences、Secure Storage）。
  ///
  /// 执行顺序：
  ///   1. 清空 Secure Storage 中已知的 API Key
  ///   2. 清空 SharedPreferences 所有键
  ///   3. 关闭数据库 → 删除数据库文件 → 重新创建空数据库（触发 onCreate）
  static Future<void> clearAllData() async {
    // 1. 清空 Secure Storage
    await _clearSecureStorage();

    // 2. 清空 SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();

    // 3. 删除并重建数据库
    final dir = await getApplicationSupportDirectory();
    final dbPath = p.join(dir.path, dbFileName);

    await DatabaseService.close();

    // 删除数据库文件及其 WAL/SHM 副本
    for (final suffix in ['', '-wal', '-shm']) {
      final file = File('$dbPath$suffix');
      if (await file.exists()) {
        await file.delete();
      }
    }

    // 重新打开数据库（会自动触发 onCreate 创建空表）
    await DatabaseService.database;
  }

  /// 清空 Secure Storage 中所有已知的 API Key。
  static Future<void> _clearSecureStorage() async {
    final keysToClear = <String>{'ai_api_key'};

    // 尝试从即将被清空的 SharedPreferences 中读取 profile IDs
    final prefs = await SharedPreferences.getInstance();
    final profilesJson = prefs.getString('ai_profiles_v2');
    if (profilesJson != null) {
      try {
        final list = jsonDecode(profilesJson) as List<dynamic>;
        for (final item in list) {
          final id = (item as Map<String, dynamic>)['id'] as String?;
          if (id != null && id.isNotEmpty) {
            keysToClear.add('ai_api_key_$id');
          }
        }
      } catch (_) {}
    }

    for (final key in keysToClear) {
      try {
        await _secureStorage.delete(key: key);
      } catch (_) {}
    }
  }

  /// 校验文件内容是否为 SQLite 数据库（魔数头 16 字节）。
  static bool _isSqliteHeader(List<int> bytes) {
    if (bytes.length < 16) return false;
    const header = 'SQLite format 3\x00';
    for (var i = 0; i < header.length; i++) {
      if (bytes[i] != header.codeUnitAt(i)) return false;
    }
    return true;
  }
}

/// 导入结果摘要
class BackupImportResult {
  final bool restoredApiKeys;

  const BackupImportResult({required this.restoredApiKeys});
}

/// 备份相关异常
class BackupException implements Exception {
  final String message;
  const BackupException(this.message);

  @override
  String toString() => message;
}
