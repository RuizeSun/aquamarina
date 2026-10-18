import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/cloud_sync_manifest.dart';
import 'backup_service.dart';
import 'cloud_sync_device_meta_service.dart';
import 'cloud_sync_engine.dart';
import 'cloud_sync_run_lock.dart';
import 'cloud_sync_settings.dart';
import 'database_service.dart';
import 'log_service.dart';
import 's3_storage_service.dart';
import 'sync_schema.dart';

/// 从云端恢复的结果。
class CloudRestoreOutcome {
  final CloudDeviceManifest manifest;
  final CloudSnapshotInfo snapshot;
  final BackupImportResult result;

  /// 恢复前自动生成的本机数据库快照路径（失败时为 null）。
  final String? safetyCopyPath;

  const CloudRestoreOutcome({
    required this.manifest,
    required this.snapshot,
    required this.result,
    required this.safetyCopyPath,
  });
}

/// 云端快照同步服务（阶段 2：设备隔离快照 + 清单）。
///
/// 该层是后续 oplog 同步的 bootstrap / checkpoint 载体：
/// - 每台设备只写自己的 `devices/{deviceId}/` 前缀；
/// - 快照对象不可变，清单最后写入（读者不会看到缺失对象）；
/// - 上传前使用 `BackupService` 的一致性快照，下载后校验 SHA-256 再导入。
class CloudSyncService {
  static const int _maxManifestBytes = 4 * 1024 * 1024;

  final CloudSyncConfig config;
  final String deviceId;
  final String deviceName;
  final S3StorageService storage;

  /// 上传快照前是否先让增量同步收敛。
  ///
  /// 快照只导出数据库文件，不包含 oplog；如果存在未上传的本地变更，
  /// 或拉取任务因时间预算/缺失父级只完成了一部分，快照会记录“半完成”
  /// 状态，恢复方随后拉取 chunk 时会重复累加计数。生产路径必须开启。
  final bool _requireSyncedSnapshot;
  final Database? _testDatabase;

  CloudSyncService._({
    required this.config,
    required this.deviceId,
    required this.deviceName,
    required this.storage,
    required bool requireSyncedSnapshot,
    Database? database,
  }) : _requireSyncedSnapshot = requireSyncedSnapshot,
       _testDatabase = database;

  /// 仅用于单元测试：注入内存对象存储与数据库，避免真实网络与平台插件。
  factory CloudSyncService.forTesting({
    required CloudSyncConfig config,
    required String deviceId,
    required String deviceName,
    required S3StorageService storage,
    Database? database,
  }) {
    return CloudSyncService._(
      config: config,
      deviceId: deviceId,
      deviceName: deviceName,
      storage: storage,
      requireSyncedSnapshot: false,
      database: database,
    );
  }

  /// 使用已存在的客户端创建服务（检查点等内部调用）。
  factory CloudSyncService.withStorage({
    required CloudSyncConfig config,
    required String deviceId,
    required String deviceName,
    required S3StorageService storage,
  }) {
    return CloudSyncService._(
      config: config,
      deviceId: deviceId,
      deviceName: deviceName,
      storage: storage,
      requireSyncedSnapshot: true,
    );
  }

  /// 使用已保存的配置与凭据创建服务。
  static Future<CloudSyncService> create() async {
    final config = await CloudSyncSettings.loadConfig();
    if (config == null || !config.isConfigured) {
      throw const CloudSyncException('尚未配置对象存储，请先在「云同步」中完成配置');
    }
    final credentials = await CloudSyncSettings.loadCredentials();
    if (credentials == null || !credentials.isComplete) {
      throw const CloudSyncException('缺少 Access Key / Secret Key，请先完成配置');
    }
    final deviceId = await CloudSyncSettings.getOrCreateDeviceId();
    final deviceName = await CloudSyncSettings.getOrCreateDeviceName(deviceId);
    return CloudSyncService._(
      config: config,
      deviceId: deviceId,
      deviceName: deviceName,
      storage: S3StorageService(
        config: config,
        accessKey: credentials.accessKey,
        secretKey: credentials.secretKey,
      ),
      requireSyncedSnapshot: true,
    );
  }

  /// 用指定配置与凭据测试连接（配置页「测试连接」使用，不需要先保存）。
  static Future<String> testConfig(
    CloudSyncConfig config,
    CloudSyncCredentials credentials,
  ) {
    if (!credentials.isComplete) {
      throw const CloudSyncException('请填写 Access Key 与 Secret Key');
    }
    return S3StorageService(
      config: config,
      accessKey: credentials.accessKey,
      secretKey: credentials.secretKey,
    ).testConnection();
  }

  /// 拉取单台设备的清单；不存在返回 null。
  Future<CloudDeviceManifest?> fetchManifest(String targetDeviceId) async {
    final key = config.manifestKey(targetDeviceId);
    final bytes = await storage.getBytes(
      key,
      maxBytes: _maxManifestBytes,
      nullIfMissing: true,
    );
    if (bytes == null) return null;
    return CloudSyncUtils.parseManifest(bytes);
  }

  /// 列出云端所有设备（按清单更新时间倒序）。
  ///
  /// 先用 CommonPrefixes 发现设备目录，再按设备读取 `manifest.json`，
  /// 避免为了找清单而递归列举全部 chunk。
  Future<List<CloudDeviceSummary>> listDevices() async {
    final meta = CloudSyncDeviceMetaService(config: config, storage: storage);
    final deviceIds = await meta.listDeviceIds();
    final summaries = <CloudDeviceSummary>[];
    for (final deviceId in deviceIds) {
      try {
        final manifest = await fetchManifest(deviceId);
        if (manifest == null) continue;
        summaries.add(
          CloudDeviceSummary(
            manifest: manifest,
            isCurrentDevice: manifest.deviceId == this.deviceId,
          ),
        );
      } catch (e) {
        // 单个设备的清单损坏不应阻塞其它设备
        logWarning('CloudSync', '跳过损坏的云端清单 device=$deviceId: $e');
      }
    }
    summaries.sort(
      (a, b) => b.manifest.updatedAt.compareTo(a.manifest.updatedAt),
    );
    return summaries;
  }

  /// 上传一份完整备份快照，并更新本设备清单。
  Future<CloudSnapshotInfo> uploadSnapshot({
    required bool includeApiKeys,
    void Function(int sent, int total)? onProgress,
    bool Function()? isCancelled,
  }) {
    // 与增量同步、恢复、设备删除共用同一把全局锁，避免 manifest / 数据库
    // 文件被并发读写。
    return CloudSyncRunLock.runExclusive(
      () => _uploadSnapshot(
        includeApiKeys: includeApiKeys,
        onProgress: onProgress,
        isCancelled: isCancelled,
      ),
    );
  }

  /// 快照前把本地 oplog 清空，并确保没有半完成的拉取 chunk。
  ///
  /// 调用方已持有 [CloudSyncRunLock]，这里嵌套的 `engine.run` 会直接执行。
  Future<void> _settleBeforeSnapshot(bool Function()? isCancelled) async {
    final db = await DatabaseService.database;
    final engine = CloudSyncEngine.forTesting(
      config: config,
      deviceId: deviceId,
      deviceName: deviceName,
      storage: storage,
      database: db,
    );
    for (var attempt = 0; attempt < 5; attempt++) {
      _throwIfCancelled(isCancelled);
      final result = await engine.run(
        pull: true,
        push: true,
        maxPushBatches: 100,
        maxDuration: const Duration(seconds: 60),
        isCancelled: isCancelled,
      );
      if (result.hasErrors) {
        throw CloudSyncException('生成快照前同步失败：${result.errors.first}');
      }
      if (result.cancelled) {
        throw const CloudSyncCancelledException('生成快照前同步已取消');
      }
      if (!result.hasIncompleteWork && result.remainingLocalOps == 0) {
        return;
      }
    }
    throw const CloudSyncException('本地变更或拉取任务尚未完成，请稍后重试上传备份');
  }

  Future<CloudSnapshotInfo> _uploadSnapshot({
    required bool includeApiKeys,
    void Function(int sent, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (_requireSyncedSnapshot) {
      await _settleBeforeSnapshot(isCancelled);
    }
    _throwIfCancelled(isCancelled);
    logInfo('CloudSync', '开始上传快照 includeApiKeys=$includeApiKeys');
    final now = DateTime.now().toUtc();
    final stamp = CloudSyncUtils.utcTimestamp(now);
    final key = config.snapshotKey(deviceId, stamp);
    final tmpDir = await getTemporaryDirectory();
    final file = File(p.join(tmpDir.path, 'aquamarina_snapshot_$stamp.zip'));
    final CloudSnapshotInfo snapshot;
    try {
      await BackupService.exportBackupToFile(
        includeApiKeys: includeApiKeys,
        output: file,
      );
      _throwIfCancelled(isCancelled);
      final size = await file.length();
      final uploaded = await storage.putFile(key, file, onProgress: onProgress);
      // 网络上传本身不可中断；若用户在上传期间取消，不写清单，让快照成为
      // 未被引用的孤儿对象，避免把“取消”误当成一次成功备份。
      _throwIfCancelled(isCancelled);
      snapshot = CloudSnapshotInfo(
        key: key,
        size: size,
        sha256: uploaded.sha256,
        createdAt: now,
        containsApiKeys: includeApiKeys,
      );
    } finally {
      if (await file.exists()) {
        await file.delete();
      }
    }

    final appVersion = await _appVersion();
    final existing = await fetchManifest(deviceId);
    final base =
        existing ??
        CloudDeviceManifest(
          deviceId: deviceId,
          deviceName: deviceName,
          schemaVersion: DatabaseService.schemaVersion,
          appVersion: appVersion,
          updatedAt: now,
          snapshots: const [],
        );
    final updated = base
        .copyWith(
          deviceName: deviceName,
          schemaVersion: DatabaseService.schemaVersion,
          appVersion: appVersion,
        )
        .addSnapshot(snapshot, retainCount: config.retainCount);

    // 清单最后写入：即使中途失败，也只是留下一个孤儿快照，不会产生坏清单。
    await storage.putBytes(
      config.manifestKey(deviceId),
      CloudSyncUtils.encodeManifest(updated),
    );

    await _pruneSnapshots(updated);
    await CloudSyncSettings.updateState(
      (state) => state.copyWith(
        lastSuccessAt: DateTime.now(),
        lastUploadKey: key,
        clearError: true,
      ),
    );
    logInfo(
      'CloudSync',
      '快照上传完成 key=$key size=${snapshot.size} sha256=${snapshot.sha256}',
    );
    return snapshot;
  }

  /// 从指定设备的最新快照恢复（覆盖本地）。
  ///
  /// 恢复前会自动保留一份本机数据库快照，导入失败时由
  /// `BackupService.importBackup` 自行回滚。
  Future<CloudRestoreOutcome> restoreSnapshot(
    CloudDeviceSummary summary, {
    void Function(int received, int? total)? onProgress,
  }) {
    return CloudSyncRunLock.runExclusive(
      () => _restoreSnapshot(summary, onProgress: onProgress),
    );
  }

  Future<CloudRestoreOutcome> _restoreSnapshot(
    CloudDeviceSummary summary, {
    void Function(int received, int? total)? onProgress,
  }) async {
    final snapshot = summary.latest;
    if (snapshot == null) {
      throw const CloudSyncException('该设备还没有可恢复的备份');
    }
    if (snapshot.size > BackupService.maxBackupSize) {
      throw CloudSyncException(
        '云端备份过大（${CloudSyncUtils.formatBytes(snapshot.size)}），拒绝恢复',
      );
    }

    final stat = await storage.stat(snapshot.key, nullIfMissing: true);
    if (stat == null) {
      throw const CloudSyncException('云端备份对象不存在，可能已被清理，请重新上传');
    }
    if (stat.size != null && stat.size != snapshot.size) {
      throw const CloudSyncException('云端备份大小与清单不一致，已中止恢复');
    }

    final tmpDir = await getTemporaryDirectory();
    final file = File(
      p.join(
        tmpDir.path,
        'aquamarina_restore_${DateTime.now().microsecondsSinceEpoch}.zip',
      ),
    );
    final CloudRestoreOutcome outcome;
    try {
      final downloaded = await storage.downloadToFile(
        snapshot.key,
        file,
        maxBytes: BackupService.maxBackupSize,
        onProgress: onProgress,
      );
      if (downloaded == null) {
        throw const CloudSyncException('云端备份下载失败，请重试');
      }
      if (downloaded.size != snapshot.size) {
        throw const CloudSyncException('云端备份下载不完整，已中止恢复');
      }
      if (downloaded.sha256 != snapshot.sha256) {
        throw const CloudSyncException('云端备份校验失败（内容已损坏），已中止恢复');
      }

      logInfo(
        'CloudSync',
        '开始恢复快照 device=${summary.manifest.deviceId} key=${snapshot.key} size=${downloaded.size}',
      );
      final safetyCopyPath = await _createSafetyCopy();
      final result = await BackupService.importBackupFromFile(file);
      outcome = CloudRestoreOutcome(
        manifest: summary.manifest,
        snapshot: snapshot,
        result: result,
        safetyCopyPath: safetyCopyPath,
      );
    } finally {
      if (await file.exists()) {
        await file.delete();
      }
    }

    await CloudSyncSettings.updateState(
      (state) => state.copyWith(
        lastSuccessAt: DateTime.now(),
        lastRestoredDeviceId: summary.manifest.deviceId,
        clearError: true,
      ),
    );
    logInfo(
      'CloudSync',
      '快照恢复完成，API Key 已恢复=${outcome.result.restoredApiKeys}',
    );
    return outcome;
  }

  /// 删除指定设备的全部云端数据（P2-8 设备管理）。
  ///
  /// 只允许删除非当前设备，避免误删本机正在使用的命名空间。
  Future<int> deleteDeviceData(String targetDeviceId) {
    return CloudSyncRunLock.runExclusive(() async {
      if (targetDeviceId == deviceId) {
        throw const CloudSyncException('不能删除当前设备，请使用「清空本设备云端数据」');
      }
      final prefix = '${config.devicePrefix(targetDeviceId)}/';
      final objects = await storage.list(prefix, recursive: true);
      if (objects.isNotEmpty) {
        await storage.deleteMany(objects.map((e) => e.key));
      }
      // 云端目录删除后，本机为该设备保存的水位 / 已应用记录 / chunk 缓存
      // 已经没有意义；保留会让后续同步依赖不存在的 chunk，也会无限增长。
      final database = _testDatabase ?? await DatabaseService.database;
      await SyncSchema.deleteDeviceRecords(database, targetDeviceId);
      logInfo(
        'CloudSync',
        '已删除设备 $targetDeviceId 的云端数据，共 ${objects.length} 个对象',
      );
      return objects.length;
    });
  }

  /// 清空本设备在云端的全部对象（快照 / 清单 / 状态）。
  ///
  /// 危险操作：不影响其它设备，但本设备云端历史将无法恢复。
  Future<int> deleteOwnCloudData() {
    return CloudSyncRunLock.runExclusive(() async {
      final prefix = '${config.devicePrefix(deviceId)}/';
      final objects = await storage.list(prefix, recursive: true);
      if (objects.isEmpty) return 0;
      await storage.deleteMany(objects.map((e) => e.key));
      logInfo('CloudSync', '已清空本设备云端数据，共 ${objects.length} 个对象');
      return objects.length;
    });
  }

  // ── 内部工具 ────────────────────────────────────────

  static void _throwIfCancelled(bool Function()? isCancelled) {
    if (isCancelled?.call() ?? false) {
      throw const CloudSyncCancelledException('上传备份已取消');
    }
  }

  /// 按保留份数清理本设备历史快照（失败不阻塞上传结果）。
  Future<void> _pruneSnapshots(CloudDeviceManifest manifest) async {
    final retained = manifest.snapshots.map((e) => e.key).toSet();
    try {
      final objects = await storage.list(
        '${config.devicePrefix(deviceId)}/snapshots/',
        recursive: true,
      );
      final obsolete = objects
          .map((e) => e.key)
          .where((key) => !retained.contains(key))
          .toList(growable: false);
      if (obsolete.isEmpty) return;
      final failures = await storage.deleteMany(obsolete);
      if (failures > 0) {
        logWarning('CloudSync', '有 $failures 个历史快照清理失败（不影响本次上传）');
      } else {
        logInfo('CloudSync', '已清理 ${obsolete.length} 个历史快照');
      }
    } catch (e) {
      logWarning('CloudSync', '清理历史快照失败（不影响本次上传）: $e');
    }
  }

  /// 恢复前生成本机数据库快照，保留最近 3 份。
  Future<String?> _createSafetyCopy() async {
    try {
      final supportDir = await getApplicationSupportDirectory();
      final dir = Directory(p.join(supportDir.path, 'sync_snapshots'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final path = p.join(
        dir.path,
        'pre_restore_${CloudSyncUtils.utcTimestamp(DateTime.now())}.db',
      );
      await DatabaseService.exportDatabaseCopy(path);
      await _pruneSafetyCopies(dir);
      logInfo('CloudSync', '恢复前本机快照已保存: $path');
      return path;
    } catch (e) {
      // 安全副本失败不阻塞恢复：importBackup 自身仍会保留 .bak 并支持回滚
      logWarning('CloudSync', '创建恢复前本机快照失败: $e');
      return null;
    }
  }

  Future<void> _pruneSafetyCopies(Directory dir) async {
    try {
      final files = await dir
          .list()
          .where((entity) => entity is File && entity.path.endsWith('.db'))
          .cast<File>()
          .toList();
      if (files.length <= 3) return;
      files.sort((a, b) => a.path.compareTo(b.path));
      for (final file in files.take(files.length - 3)) {
        try {
          await file.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<String> _appVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return '${info.version}+${info.buildNumber}';
    } catch (_) {
      return 'unknown';
    }
  }
}
