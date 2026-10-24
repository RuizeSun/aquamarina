import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../cloud/cloud_sync_settings.dart';
import 'database_service.dart';
import '../system/log_service.dart';
import '../tts/mimo_tts_credentials.dart';
import '../cloud/sync_capture_service.dart';
import '../cloud/sync_schema.dart';
import '../system/theme_mode_service.dart';
import '../tts/tts_service.dart';

/// 备份文件格式：ZIP
///
///   - `aquamarina.db`         业务数据库（词书/学习记录/句子等）
///   - `preferences.json`      SharedPreferences 全量（带类型标记）
///   - `secure_storage.json`   API Keys（AI 服务 / MiMo TTS，可选，导出时由用户勾选）
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

  /// 仅本机使用的 SharedPreferences 前缀：既不会写入备份，恢复时也不会被覆盖。
  ///
  /// 云同步配置（端点/桶/设备标识/同步状态）属于设备本地设置：
  /// 如果随备份跑到另一台设备，会让那台设备把数据写进本设备的云端命名空间。
  static const String localOnlyPrefPrefix = 'cloud_sync_';

  /// 导入的备份文件大小上限（防滥用，正常备份远小于此值）
  ///
  /// 公开给导入页面，在 `readAsBytes()` 之前先检查文件大小，避免大文件直接 OOM。
  static const int maxBackupSize = 500 * 1024 * 1024;

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();

  // ── 导出 ─────────────────────────────────────────────

  /// 生成完整备份数据（ZIP 字节流）。
  ///
  /// 兼容旧调用方；内部改为写临时文件再读取。云同步与手动导出应优先使用
  /// [exportBackupToFile]，避免大数据库整包进入内存（P0-2）。
  static Future<Uint8List> exportBackup({required bool includeApiKeys}) async {
    final dir = await getTemporaryDirectory();
    final file = File(
      p.join(
        dir.path,
        'aquamarina_backup_${DateTime.now().microsecondsSinceEpoch}.zip',
      ),
    );
    try {
      await exportBackupToFile(includeApiKeys: includeApiKeys, output: file);
      return await file.readAsBytes();
    } finally {
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  /// 流式生成完整备份到 [output]。
  ///
  /// - 数据库先用 `VACUUM INTO` 生成一致副本；
  /// - 副本中的 `sync_*` / `oplog_*` 会被删除并 `VACUUM`（P2-1），
  ///   恢复时由 `SyncSchema.ensure` 重建，避免快照携带运行时状态；
  /// - 使用 `ZipFileEncoder` 直接从文件流写入，不把 DB 读进内存。
  static Future<void> exportBackupToFile({
    required bool includeApiKeys,
    required File output,
  }) async {
    logInfo('BackupService', '开始导出备份 includeApiKeys=$includeApiKeys');
    final parent = output.parent;
    if (!await parent.exists()) {
      await parent.create(recursive: true);
    }

    final dbPath = await DatabaseService.databasePath;
    final dbFile = File(dbPath);
    // 唯一临时文件：避免与云同步检查点或手动导出并发时互相覆盖。
    final tmpPath =
        '$dbPath.export_tmp_${DateTime.now().microsecondsSinceEpoch}';
    final tmpFile = File(tmpPath);
    if (await tmpFile.exists()) {
      await tmpFile.delete();
    }

    ZipFileEncoder? encoder;
    var syncWatermarks = const <SyncWatermark>[];
    var syncBackendId = '';
    try {
      if (await dbFile.exists()) {
        // 由 SQLite 引擎生成与主连接一致（含 WAL 事务）的独立快照
        await DatabaseService.exportDatabaseCopy(tmpPath);
        // 先读取副本里的同步水位，再删除运行时表；这样水位与快照数据一致。
        final extracted = await _extractAndStripSyncRuntimeTables(tmpPath);
        syncWatermarks = extracted.$1;
        syncBackendId = extracted.$2;
      }

      encoder = ZipFileEncoder();
      encoder.create(output.path);
      if (await tmpFile.exists()) {
        await encoder.addFile(tmpFile, dbFileName);
      }
      encoder.addArchiveFile(
        ArchiveFile.string(_prefsFileName, await _exportPreferences()),
      );
      if (includeApiKeys) {
        encoder.addArchiveFile(
          ArchiveFile.string(_secureFileName, await _exportSecureStorage()),
        );
      }
      encoder.addArchiveFile(
        ArchiveFile.string(
          _metaFileName,
          jsonEncode({
            'app': 'aquamarina',
            'created_at': DateTime.now().toIso8601String(),
            'contains_api_keys': includeApiKeys,
            if (syncBackendId.isNotEmpty) 'sync_backend_id': syncBackendId,
            if (syncWatermarks.isNotEmpty)
              'sync_watermarks': [
                for (final watermark in syncWatermarks) watermark.toJson(),
              ],
          }),
        ),
      );
      await encoder.close();
      encoder = null;

      final size = await output.length();
      logInfo('BackupService', '备份导出完成，文件大小: $size 字节');
    } catch (e) {
      // 避免把半个 ZIP 留给调用方（用户选择的路径可能已被截断）。
      try {
        if (await output.exists()) await output.delete();
      } catch (_) {}
      rethrow;
    } finally {
      if (encoder != null) {
        try {
          await encoder.close();
        } catch (_) {}
      }
      if (await tmpFile.exists()) {
        await tmpFile.delete();
      }
    }
  }

  /// 从导出的 DB 副本中读取同步水位，然后移除同步运行时表，减小快照体积。
  ///
  /// 水位会写入 `backup_meta.json`；恢复时用它重建 `sync_state`，从而只拉取
  /// 快照真正未包含的 chunk。旧备份没有该字段时仍使用创建时间基线。
  ///
  /// `sync_tombstones` 与 `sync_row_versions` 必须保留：恢复后仍可能拉取到
  /// 其它设备在快照水位之后才上传的旧 HLC 操作，没有墓碑会被“复活”，
  /// 没有行版本则可能覆盖快照里更新的数据。
  @visibleForTesting
  static Future<(List<SyncWatermark>, String)>
  extractAndStripSyncRuntimeTablesForTesting(String dbPath) =>
      _extractAndStripSyncRuntimeTables(dbPath);

  static Future<(List<SyncWatermark>, String)>
  _extractAndStripSyncRuntimeTables(String dbPath) async {
    Database? db;
    try {
      db = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final byDevice = <String, SyncWatermark>{};
      var backendId = '';
      try {
        final metaRows = await db.query(
          'sync_meta',
          columns: ['device_id', 'head_hlc', 'head_key', 'backend_id'],
          where: 'id = 1',
          limit: 1,
        );
        if (metaRows.isNotEmpty) {
          final row = metaRows.first;
          backendId = row['backend_id'] as String? ?? '';
          final ownId = row['device_id'] as String? ?? '';
          final headHlc = row['head_hlc'] as String? ?? '';
          final headKey = row['head_key'] as String? ?? '';
          final own = SyncWatermark.fromJson({
            'device_id': ownId,
            'last_hlc': headHlc,
            'last_chunk_key': headKey,
          });
          if (own != null) byDevice[own.deviceId] = own;
        }
      } catch (_) {
        // 旧库没有 head 列时忽略
      }
      try {
        final stateRows = await db.query(
          'sync_state',
          columns: ['device_id', 'last_hlc', 'last_chunk_key'],
        );
        for (final row in stateRows) {
          final watermark = SyncWatermark.fromJson(row);
          if (watermark == null) continue;
          final existing = byDevice[watermark.deviceId];
          if (existing == null ||
              watermark.lastHlc.compareTo(existing.lastHlc) > 0) {
            byDevice[watermark.deviceId] = watermark;
          }
        }
      } catch (_) {
        // 旧库没有 sync_state 时忽略
      }

      // 墓碑与行版本是恢复后防复活 / 防旧数据覆盖的依据，不能随其它
      // 同步运行时表一起删除。
      const preservedTables = {'sync_tombstones', 'sync_row_versions'};
      final rows = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        "AND (name LIKE 'sync\\_%' ESCAPE '\\' OR name LIKE 'oplog\\_%' ESCAPE '\\')",
      );
      for (final row in rows) {
        final name = row['name'];
        if (name is String &&
            name.isNotEmpty &&
            !preservedTables.contains(name)) {
          await db.execute('DROP TABLE IF EXISTS "$name"');
        }
      }
      await db.execute('VACUUM');
      return (byDevice.values.toList(growable: false), backendId);
    } catch (e) {
      // 瘦身失败不影响导出：恢复时仍会清理运行时状态
      logWarning('BackupService', '清理快照中的同步表失败（不影响导出）: $e');
      return (const <SyncWatermark>[], '');
    } finally {
      await db?.close();
    }
  }

  /// 决定恢复时使用备份中的来源水位，还是退回备份创建时间基线。
  ///
  /// 来源水位只对导出它的对象存储后端有效。如果本机已配置另一个后端，
  /// 必须丢弃水位，但同时要把 `backend_id` 写成当前后端身份；否则下一次
  /// 同步会把恢复结果误判为“后端切换”，从而清空 `baseline_hlc` 并全量重放。
  @visibleForTesting
  static ({List<SyncWatermark>? watermarks, String backendId})
  resolveRestoreWatermarks({
    required List<SyncWatermark>? backupWatermarks,
    required String backupBackendId,
    required String? localBackendIdentity,
  }) {
    final local = localBackendIdentity?.trim() ?? '';
    if (backupBackendId.isNotEmpty &&
        local.isNotEmpty &&
        local != backupBackendId) {
      return (watermarks: null, backendId: local);
    }
    return (watermarks: backupWatermarks, backendId: backupBackendId);
  }

  /// 序列化 SharedPreferences：为每个 key 附带类型标记，保证恢复时类型不丢失。
  static Future<String> _exportPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final map = <String, dynamic>{};
    for (final key in prefs.getKeys()) {
      if (key.startsWith(localOnlyPrefPrefix)) continue;
      // 句式集元数据已迁入 SQLite（v14）；旧 key 只为兼容历史备份
      if (key == 'sentence_sets_v1') continue;
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
  ///   - `tts_mimo_api_key`（MimoTtsCredentials.storageKey，小米 MiMo TTS）
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

    // 小米 MiMo TTS 的 API Key
    final mimoKey = await _readSecure(MimoTtsCredentials.storageKey);
    if (mimoKey != null && mimoKey.isNotEmpty) {
      map[MimoTtsCredentials.storageKey] = mimoKey;
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
    final dir = await getTemporaryDirectory();
    final file = File(
      p.join(
        dir.path,
        'aquamarina_import_${DateTime.now().microsecondsSinceEpoch}.zip',
      ),
    );
    try {
      await file.writeAsBytes(bytes, flush: true);
      return await importBackupFromFile(file);
    } finally {
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  /// 从备份 ZIP 文件流式恢复数据（覆盖式）。
  ///
  /// 数据库通过 `ArchiveFile.writeContent` 直接解压到临时文件，
  /// 不会把整库读入内存（P0-2）。
  static Future<BackupImportResult> importBackupFromFile(File file) async {
    final size = await file.length();
    logInfo('BackupService', '开始导入备份，文件大小: $size 字节');
    if (size > maxBackupSize) {
      throw const BackupException('备份文件过大，拒绝导入');
    }

    final dir = await getApplicationSupportDirectory();
    final dbPath = p.join(dir.path, dbFileName);
    // 唯一临时文件：避免并发恢复或上次异常中断留下的文件互相覆盖。
    final extractPath =
        '$dbPath.import_extract_${DateTime.now().microsecondsSinceEpoch}';
    final extractFile = File(extractPath);
    if (await extractFile.exists()) {
      await extractFile.delete();
    }

    InputFileStream? input;
    try {
      Archive archive;
      try {
        input = InputFileStream(file.path);
        archive = ZipDecoder().decodeStream(input, verify: true);
      } on ArchiveException {
        throw const BackupException('文件不是有效的备份文件（ZIP 解析失败）');
      }

      final dbEntry = archive.findFile(dbFileName);
      if (dbEntry == null) {
        throw const BackupException('备份文件缺少 aquamarina.db，无法导入');
      }

      // 校验元信息（可选；旧备份可能没有）
      DateTime? backupCreatedAt;
      List<SyncWatermark>? backupWatermarks;
      var backupBackendId = '';
      final metaBytes = _readSmallEntry(archive, _metaFileName, 1024 * 1024);
      if (metaBytes != null) {
        try {
          final meta =
              jsonDecode(utf8.decode(metaBytes)) as Map<String, dynamic>;
          if (meta['app'] != 'aquamarina') {
            throw const BackupException('不是 Aquamarina 的备份文件');
          }
          final createdAt = meta['created_at'];
          if (createdAt is String) {
            backupCreatedAt = DateTime.tryParse(createdAt);
          }
          final rawWatermarks = meta['sync_watermarks'];
          if (rawWatermarks is List) {
            final parsed = rawWatermarks
                .map(SyncWatermark.fromJson)
                .whereType<SyncWatermark>()
                .toList(growable: false);
            if (parsed.isNotEmpty) backupWatermarks = parsed;
          }
          final backendId = meta['sync_backend_id'];
          if (backendId is String) backupBackendId = backendId;
        } catch (e) {
          if (e is BackupException) rethrow;
          throw const BackupException('备份文件的元信息损坏');
        }
      }

      // 解析并校验 SharedPreferences（不触碰现有数据）
      final prefsBytes = _readSmallEntry(
        archive,
        _prefsFileName,
        64 * 1024 * 1024,
      );
      final hasPrefsEntry = prefsBytes != null;
      var prefsEntries = const <MapEntry<String, Object?>>[];
      if (prefsBytes != null) {
        try {
          prefsEntries = _parsePreferences(utf8.decode(prefsBytes));
        } on FormatException catch (e) {
          throw BackupException('备份文件中的设置数据损坏：${e.message}');
        }
      }

      // 解析并校验 Secure Storage（不触碰现有数据）
      Map<String, String> secureMap = const {};
      final secureBytes = _readSmallEntry(
        archive,
        _secureFileName,
        4 * 1024 * 1024,
      );
      final hasSecureEntry = secureBytes != null;
      if (secureBytes != null) {
        try {
          final decoded = jsonDecode(utf8.decode(secureBytes));
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

      // 流式解压数据库到临时文件
      final output = OutputFileStream(extractPath);
      try {
        dbEntry.writeContent(output);
      } finally {
        await output.close();
      }
      final extractedSize = await extractFile.length();
      if (extractedSize > maxBackupSize) {
        throw const BackupException('备份中的数据库文件过大，拒绝导入');
      }
      await _validateImportedDatabase(extractPath);

      // 先为现有数据库留一份回滚副本
      final bakPath = '$dbPath.bak';
      if (await File(dbPath).exists()) {
        await File(dbPath).copy(bakPath);
      }

      try {
        await DatabaseService.close();

        // 原子替换数据库文件（临时文件 + rename，避免写坏唯一副本）。
        // Windows 的 File.rename 不能覆盖已存在文件，先删除旧库；失败时由
        // 下方的 .bak 回滚。
        final currentDb = File(dbPath);
        if (await currentDb.exists()) {
          await currentDb.delete();
        }
        await extractFile.rename(dbPath);
        // 清理可能残留的 WAL/SHM 文件，避免与旧连接冲突
        for (final suffix in ['-wal', '-shm']) {
          final sidecar = File('$dbPath$suffix');
          if (await sidecar.exists()) {
            await sidecar.delete();
          }
        }

        if (hasPrefsEntry) {
          await _restorePreferences(prefsEntries);
        }
        if (hasSecureEntry) {
          await _restoreSecureStorage(secureMap);
        }

        try {
          await DatabaseService.database;
        } catch (_) {
          throw const BackupException('数据库文件已替换，但打开失败，请重启应用');
        }

        // 快照可能已移除同步运行时表：先重建，再写入基线。
        final db = await DatabaseService.database;
        try {
          await SyncSchema.ensure(db);
        } catch (e) {
          logWarning('BackupService', '重建同步 schema 失败（不影响恢复）: $e');
        }
        try {
          // 水位只对导出它的那个对象存储后端有效；如果本机当前配置指向
          // 另一个后端，退回“备份创建时间”基线，避免误跳过新后端的数据。
          // 同时把 backend_id 写成当前后端，防止下一次同步把这次恢复误判成
          // 后端切换并清空 baseline。
          String? localBackendIdentity;
          try {
            final localConfig = await CloudSyncSettings.loadConfig();
            if (localConfig != null && localConfig.isConfigured) {
              localBackendIdentity = localConfig.backendIdentity;
            }
          } catch (_) {}
          final decision = resolveRestoreWatermarks(
            backupWatermarks: backupWatermarks,
            backupBackendId: backupBackendId,
            localBackendIdentity: localBackendIdentity,
          );
          if (decision.watermarks == null && backupWatermarks != null) {
            logWarning('BackupService', '备份来自其它对象存储后端，忽略同步水位并退回 baseline');
          }
          await SyncSchema.resetRuntimeState(
            db,
            baseline: backupCreatedAt ?? DateTime.now(),
            watermarks: decision.watermarks,
            backendId: decision.backendId.isEmpty ? null : decision.backendId,
          );
          // 恢复后数据基线已变：清空检查点水位，允许重新生成检查点。
          await CloudSyncSettings.updateState(
            (state) => state.copyWith(clearCheckpoint: true),
          );
        } catch (e) {
          logWarning('BackupService', '重置同步运行时状态失败（不影响恢复）: $e');
        }

        // 恢复会重建 sync_meta（capture_enabled 默认为 0）。如果本机已经
        // 配置云同步，必须立刻重新开启捕获，否则用户在“恢复完成 → 下一次
        // 增量同步”之间产生的学习记录不会进入 oplog，之后也无法补传。
        try {
          if (await CloudSyncSettings.hasCompleteConfiguration()) {
            await SyncCaptureService.setCaptureEnabled(enabled: true, db: db);
            logInfo('BackupService', '恢复后已自动开启同步变更捕获');
          }
        } catch (e) {
          logWarning('BackupService', '恢复后开启同步变更捕获失败: $e');
        }

        try {
          await TtsService.instance.refreshSettings();
        } catch (_) {
          // TTS 刷新失败不影响导入结果
        }
        try {
          await ThemeModeService.instance.load();
        } catch (_) {
          // 主题刷新失败不影响导入结果
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

      logInfo('BackupService', '备份导入完成');
      return BackupImportResult(restoredApiKeys: hasSecureEntry);
    } finally {
      try {
        await input?.close();
      } catch (_) {}
      if (await extractFile.exists()) {
        await extractFile.delete();
      }
    }
  }

  /// 从备份 ZIP 中解压数据库并迁移到当前 schema，供“合并”使用。
  ///
  /// 与 [importBackupFromFile] 不同：这里不会替换本机数据库，也不会恢复
  /// SharedPreferences / Secure Storage；调用方负责在合并完成后删除临时库。
  static Future<BackupMergeSource> extractDatabaseForMerge(File file) async {
    final size = await file.length();
    if (size > maxBackupSize) {
      throw const BackupException('备份文件过大，拒绝合并');
    }
    final tmpDir = await getTemporaryDirectory();
    final extractPath = p.join(
      tmpDir.path,
      'aquamarina_merge_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    final extractFile = File(extractPath);
    InputFileStream? input;
    try {
      Archive archive;
      try {
        input = InputFileStream(file.path);
        archive = ZipDecoder().decodeStream(input, verify: true);
      } on ArchiveException {
        throw const BackupException('备份文件已损坏，无法合并');
      }
      final dbEntry = archive.findFile(dbFileName);
      if (dbEntry == null) {
        throw const BackupException('备份中缺少数据库文件，无法合并');
      }

      DateTime? createdAt;
      var watermarks = const <SyncWatermark>[];
      var backendId = '';
      final metaBytes = _readSmallEntry(archive, _metaFileName, 1024 * 1024);
      if (metaBytes != null) {
        try {
          final meta =
              jsonDecode(utf8.decode(metaBytes)) as Map<String, dynamic>;
          if (meta['app'] != 'aquamarina') {
            throw const BackupException('不是 Aquamarina 的备份文件');
          }
          final rawCreatedAt = meta['created_at'];
          if (rawCreatedAt is String) {
            createdAt = DateTime.tryParse(rawCreatedAt);
          }
          final rawWatermarks = meta['sync_watermarks'];
          if (rawWatermarks is List) {
            watermarks = rawWatermarks
                .map(SyncWatermark.fromJson)
                .whereType<SyncWatermark>()
                .toList(growable: false);
          }
          final rawBackend = meta['sync_backend_id'];
          if (rawBackend is String) backendId = rawBackend;
        } catch (e) {
          if (e is BackupException) rethrow;
          throw const BackupException('备份文件的元信息损坏');
        }
      }

      final output = OutputFileStream(extractPath);
      try {
        dbEntry.writeContent(output);
      } finally {
        await output.close();
      }
      if (await extractFile.length() > maxBackupSize) {
        throw const BackupException('备份中的数据库文件过大，拒绝合并');
      }
      await _validateImportedDatabase(extractPath);
      try {
        await DatabaseService.migrateImportedDatabase(extractPath);
      } catch (e) {
        throw BackupException('备份数据库结构无法升级，拒绝合并：$e');
      }
      return BackupMergeSource(
        databaseFile: extractFile,
        createdAt: createdAt,
        watermarks: watermarks,
        backendId: backendId,
      );
    } catch (_) {
      if (await extractFile.exists()) {
        await extractFile.delete();
      }
      rethrow;
    } finally {
      await input?.close();
    }
  }

  /// 读取小型 JSON 条目并限制大小，避免恶意 ZIP 让内存爆掉。
  static List<int>? _readSmallEntry(
    Archive archive,
    String name,
    int maxBytes,
  ) {
    final entry = archive.findFile(name);
    if (entry == null) return null;
    if (entry.size > maxBytes) {
      throw const BackupException('备份文件中的条目过大，拒绝导入');
    }
    return entry.readBytes();
  }

  /// 在替换现有数据库之前，对解压出的数据库做预检：
  /// - SQLite 文件头有效
  /// - 能否以只读方式打开
  /// - Schema 版本不高于当前 App
  /// - `PRAGMA quick_check` 通过
  /// - 必要业务表齐全
  static Future<void> _validateImportedDatabase(String dbPath) async {
    final file = File(dbPath);
    if (!await file.exists()) {
      throw const BackupException('备份中的数据库文件不存在，拒绝导入');
    }
    if (await file.length() > maxBackupSize) {
      throw const BackupException('备份中的数据库文件过大，拒绝导入');
    }
    final raf = await file.open();
    List<int> header;
    try {
      header = await raf.read(16);
    } finally {
      await raf.close();
    }
    if (!_isSqliteHeader(header)) {
      throw const BackupException('备份中的数据库文件无效，拒绝导入');
    }

    Database? probe;
    try {
      probe = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );

      final version = await probe.getVersion();
      if (version > DatabaseService.schemaVersion) {
        throw BackupException(
          '备份来自更高版本的 App（数据库 v$version），'
          '请先升级 App 后再导入',
        );
      }

      final check = await probe.rawQuery('PRAGMA quick_check');
      final ok =
          check.isNotEmpty && check.every((row) => row.values.first == 'ok');
      if (!ok) {
        throw const BackupException('备份中的数据库已损坏，拒绝导入');
      }

      const requiredTables = [
        'word_books',
        'word_book_entries',
        'user_word_records',
        'daily_activity',
        'sentences',
      ];
      final placeholders = List.filled(requiredTables.length, '?').join(',');
      final tables = await probe.rawQuery(
        'SELECT name FROM sqlite_master '
        'WHERE type = ? AND name IN ($placeholders)',
        ['table', ...requiredTables],
      );
      if (tables.length < requiredTables.length) {
        throw const BackupException('备份数据库结构不完整，拒绝导入');
      }
    } on BackupException {
      rethrow;
    } catch (e) {
      throw BackupException('备份中的数据库无法打开或已损坏：$e');
    } finally {
      await probe?.close();
    }
  }

  /// 解析 preferences.json 并校验所有条目结构与类型。
  ///
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

    // 清空现有设置（保留仅本机使用的配置，如云同步端点/设备标识）
    for (final key in prefs.getKeys()) {
      if (key.startsWith(localOnlyPrefPrefix)) continue;
      await prefs.remove(key);
    }

    // 写入备份条目（跳过仅本机使用的配置）
    for (final e in entries) {
      if (e.key.startsWith(localOnlyPrefPrefix)) continue;
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
  /// 是否恢复了 Secure Storage 中的 API Key。
  final bool restoredApiKeys;

  const BackupImportResult({required this.restoredApiKeys});
}

/// 合并用的快照数据库与元信息。
class BackupMergeSource {
  final File databaseFile;
  final DateTime? createdAt;
  final List<SyncWatermark> watermarks;
  final String backendId;

  const BackupMergeSource({
    required this.databaseFile,
    required this.createdAt,
    required this.watermarks,
    required this.backendId,
  });

  Future<void> delete() async {
    if (await databaseFile.exists()) {
      await databaseFile.delete();
    }
  }
}

/// 备份相关异常
class BackupException implements Exception {
  final String message;
  const BackupException(this.message);

  @override
  String toString() => message;
}
