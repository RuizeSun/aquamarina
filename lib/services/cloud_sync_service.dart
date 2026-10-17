import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/cloud_sync_manifest.dart';
import 'backup_service.dart';
import 'cloud_sync_run_lock.dart';
import 'cloud_sync_settings.dart';
import 'database_service.dart';
import 'log_service.dart';
import 's3_storage_service.dart';

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

  CloudSyncService._({
    required this.config,
    required this.deviceId,
    required this.deviceName,
    required this.storage,
  });

  /// 仅用于单元测试：注入内存对象存储，避免真实网络与平台插件。
  factory CloudSyncService.forTesting({
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
  Future<List<CloudDeviceSummary>> listDevices() async {
    final objects = await storage.list(
      '${config.devicesPrefix}/',
      recursive: true,
    );
    final manifestKeys = <String>{
      for (final object in objects)
        if (object.key.endsWith('/manifest.json')) object.key,
    };

    final summaries = <CloudDeviceSummary>[];
    for (final key in manifestKeys) {
      try {
        final bytes = await storage.getBytes(
          key,
          maxBytes: _maxManifestBytes,
          nullIfMissing: true,
        );
        if (bytes == null) continue;
        final manifest = CloudSyncUtils.parseManifest(bytes);
        summaries.add(
          CloudDeviceSummary(
            manifest: manifest,
            isCurrentDevice: manifest.deviceId == deviceId,
          ),
        );
      } catch (e) {
        // 单个设备的清单损坏不应阻塞其它设备
        logWarning('CloudSync', '跳过损坏的云端清单 $key: $e');
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
  }) {
    // 与增量同步、恢复、设备删除共用同一把全局锁，避免 manifest / 数据库
    // 文件被并发读写。
    return CloudSyncRunLock.runExclusive(
      () => _uploadSnapshot(
        includeApiKeys: includeApiKeys,
        onProgress: onProgress,
      ),
    );
  }

  Future<CloudSnapshotInfo> _uploadSnapshot({
    required bool includeApiKeys,
    void Function(int sent, int total)? onProgress,
  }) async {
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
      final size = await file.length();
      final uploaded = await storage.putFile(key, file, onProgress: onProgress);
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
    await CloudSyncSettings.saveState(
      (await CloudSyncSettings.loadState()).copyWith(
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

    await CloudSyncSettings.saveState(
      (await CloudSyncSettings.loadState()).copyWith(
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
      if (objects.isEmpty) return 0;
      await storage.deleteMany(objects.map((e) => e.key));
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
