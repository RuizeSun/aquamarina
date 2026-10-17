import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/cloud_sync_manifest.dart';
import '../models/sync_op.dart';
import 'cloud_sync_maintenance_service.dart';
import 'cloud_sync_service.dart';
import 'cloud_sync_settings.dart';
import 'database_service.dart';
import 'log_service.dart';
import 's3_storage_service.dart';
import 'sync_apply_service.dart';
import 'sync_capture_service.dart';

/// 一次增量同步的结果摘要。
class CloudSyncRunResult {
  int pushedChunks = 0;
  int pushedOps = 0;
  int pulledChunks = 0;
  int pulledOps = 0;
  int duplicates = 0;
  int conflicts = 0;
  int skippedMissingParent = 0;
  int remainingLocalOps = 0;
  final List<String> errors = [];
  final List<String> conflictDetails = [];

  bool get hasErrors => errors.isNotEmpty;
}

/// 增量同步编排：拉取其它设备的 chunk → 应用；再推送本机 oplog。
///
/// - chunk 不可变，键中包含首个 op 的 HLC 与内容哈希，重传天然幂等；
/// - 拉取按 HLC 字典序进行，配合行版本 / 墓碑保证乱序到达也收敛；
/// - `sync_chunks` 记录已应用 chunk，避免重复下载；
/// - 缺失父级的 chunk 不记为已应用，下次同步重试。
class CloudSyncEngine {
  final CloudSyncConfig config;
  final String deviceId;
  final String deviceName;
  final S3StorageService storage;
  final Database? _testDatabase;

  CloudSyncEngine._({
    required this.config,
    required this.deviceId,
    required this.deviceName,
    required this.storage,
    Database? database,
  }) : _testDatabase = database;

  /// 使用已保存配置创建引擎（复用 CloudSyncService 的配置与 S3 客户端）。
  static Future<CloudSyncEngine> create() async {
    final service = await CloudSyncService.create();
    return CloudSyncEngine._(
      config: service.config,
      deviceId: service.deviceId,
      deviceName: service.deviceName,
      storage: service.storage,
    );
  }

  /// 仅用于测试：注入内存数据库与假对象存储。
  factory CloudSyncEngine.forTesting({
    required CloudSyncConfig config,
    required String deviceId,
    required String deviceName,
    required S3StorageService storage,
    required Database database,
  }) {
    return CloudSyncEngine._(
      config: config,
      deviceId: deviceId,
      deviceName: deviceName,
      storage: storage,
      database: database,
    );
  }

  Future<Database> _db() async =>
      _testDatabase ?? await DatabaseService.database;

  Future<CloudSyncRunResult> run({
    bool pull = true,
    bool push = true,
    int maxPushBatches = 20,
  }) async {
    final db = await _db();
    final result = CloudSyncRunResult();
    await db.update('sync_meta', {
      'device_id': deviceId,
      'capture_enabled': 1,
    }, where: 'id = 1');

    if (pull) {
      await _pull(db, result);
    }
    if (push) {
      await _push(db, result, maxPushBatches);
    }
    // 保守清理历史 chunk（内部有 7 天冷却，失败不影响同步）
    await CloudSyncMaintenanceService.maybePruneOldChunks(
      config: config,
      storage: storage,
      db: db,
    );

    result.remainingLocalOps = await SyncCaptureService.pendingCount(db: db);
    try {
      await CloudSyncSettings.saveState(
        (await CloudSyncSettings.loadState()).copyWith(
          lastSuccessAt: DateTime.now(),
          clearError: true,
        ),
      );
    } catch (_) {
      // 状态展示失败不影响同步结果
    }
    logInfo(
      'CloudSyncEngine',
      '增量同步完成：pull=${result.pulledChunks} chunks / '
          '${result.pulledOps} ops，push=${result.pushedChunks} chunks / '
          '${result.pushedOps} ops，pending=${result.remainingLocalOps}，'
          'conflicts=${result.conflicts}',
    );
    return result;
  }

  Future<void> _pull(Database db, CloudSyncRunResult result) async {
    final objects = await storage.list(
      '${config.devicesPrefix}/',
      recursive: true,
    );
    final chunkObjects = objects
        .where((o) => o.key.contains('/chunks/') && o.key.endsWith('.jsonl'))
        .toList();
    if (chunkObjects.isEmpty) return;

    final appliedRows = await db.query('sync_chunks', columns: ['chunk_key']);
    final appliedKeys = {
      for (final row in appliedRows) row['chunk_key'] as String,
    };
    final metaRows = await db.query(
      'sync_meta',
      columns: ['baseline_hlc'],
      where: 'id = 1',
      limit: 1,
    );
    final baseline = metaRows.isEmpty
        ? ''
        : (metaRows.first['baseline_hlc'] as String? ?? '');

    final candidates =
        chunkObjects
            .where((o) => !appliedKeys.contains(o.key))
            .where((o) => _deviceOf(o.key) != deviceId)
            .where((o) => !_isAtOrBeforeBaseline(o.key, baseline))
            .toList()
          ..sort((a, b) => a.key.compareTo(b.key));

    for (final object in candidates) {
      final sourceDevice = _deviceOf(object.key);
      if (sourceDevice == null || sourceDevice.isEmpty) continue;
      try {
        final bytes = await storage.getBytes(
          object.key,
          maxBytes: 8 * 1024 * 1024,
          nullIfMissing: true,
        );
        if (bytes == null) continue;
        final sha = CloudSyncUtils.sha256Hex(bytes);
        if (!object.key.contains(sha.substring(0, 16))) {
          result.errors.add('chunk 哈希校验失败：${object.key}');
          continue;
        }
        final ops = SyncChunkCodec.decode(bytes);
        final apply = await SyncApplyService.applyOps(ops, db: db);
        result.pulledOps += ops.length;
        result.duplicates += apply.duplicates;
        result.conflicts += apply.conflicts;
        result.skippedMissingParent += apply.skippedMissingParent;
        if (result.conflictDetails.length < 20) {
          result.conflictDetails.addAll(
            apply.conflictDetails.take(20 - result.conflictDetails.length),
          );
        }
        if (apply.skippedMissingParent > 0) {
          result.errors.add('chunk 存在缺失父级，将在下次同步重试：${object.key}');
          continue;
        }
        await db.insert('sync_chunks', {
          'device_id': sourceDevice,
          'chunk_key': object.key,
          'sha256': sha,
          'applied_at': DateTime.now().toUtc().toIso8601String(),
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
        result.pulledChunks++;
      } catch (e) {
        result.errors.add('拉取 ${object.key} 失败：$e');
      }
    }
  }

  Future<void> _push(
    Database db,
    CloudSyncRunResult result,
    int maxPushBatches,
  ) async {
    for (var i = 0; i < maxPushBatches; i++) {
      final batch = await SyncCaptureService.takePendingBatch(
        db: db,
        deviceId: deviceId,
      );
      if (batch == null) break;
      final key = _chunkKey(batch);
      try {
        await storage.putBytes(key, batch.bytes);
      } catch (e) {
        result.errors.add('上传 chunk 失败：$e');
        break;
      }
      await SyncCaptureService.markUploaded(batch, db: db);
      result.pushedChunks++;
      result.pushedOps += batch.ops.length;
    }
  }

  /// chunk 键包含首个 op 的 HLC，便于按时间顺序拉取。
  String _chunkKey(SyncBatch batch) {
    final first = batch.ops.first;
    final hlc = first.hlc.value.replaceAll(':', '-');
    return '${config.devicePrefix(deviceId)}/chunks/$hlc-'
        '${batch.sha256.substring(0, 16)}.jsonl';
  }

  String? _deviceOf(String key) {
    const marker = '/devices/';
    final start = key.indexOf(marker);
    if (start < 0) return null;
    final idStart = start + marker.length;
    final idEnd = key.indexOf('/chunks/', idStart);
    if (idEnd < 0) return null;
    return key.substring(idStart, idEnd);
  }

  /// chunk 键形如 `chunks/{msHex}-{counterHex}-{sha}.jsonl`。
  ///
  /// 备份恢复后，基线之前的 chunk 已包含在快照中，应跳过以免重复计数。
  bool _isAtOrBeforeBaseline(String key, String baseline) {
    if (baseline.isEmpty) return false;
    final name = key.split('/').last;
    final parts = name.split('-');
    if (parts.length < 3) return false;
    final ms = int.tryParse(parts[0], radix: 16);
    final counter = int.tryParse(parts[1], radix: 16);
    if (ms == null || counter == null) return false;
    try {
      return SyncHlc(ms, counter).compareTo(SyncHlc.parse(baseline)) <= 0;
    } on FormatException {
      return false;
    }
  }
}
