import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'cloud_sync_settings.dart';
import 'database_service.dart';
import 'log_service.dart';
import 's3_storage_service.dart';

/// 云端增量数据维护：保守清理历史 chunk。
///
/// 策略（宁可少删，不可误删）：
/// - 每台设备至少保留最近 [keepChunksPerDevice] 个变更包；
/// - 且仅删除最后修改时间早于 [chunkRetention] 的对象；
/// - 服务端未返回 `lastModified` 时一律跳过；
/// - 删除后同步清理本地 `sync_chunks` 记录。
///
/// 长期离线（超过保留期）的设备可能错过被清理的变更，
/// 可通过完整快照恢复后继续使用增量同步。
class CloudSyncMaintenanceService {
  CloudSyncMaintenanceService._();

  static const Duration gcInterval = Duration(days: 7);
  static const Duration chunkRetention = Duration(days: 180);
  static const int keepChunksPerDevice = 1000;

  /// 带冷却的维护入口（引擎同步结束后调用）。
  static Future<int> maybePruneOldChunks({
    required CloudSyncConfig config,
    required S3StorageService storage,
    Database? db,
  }) async {
    try {
      final state = await CloudSyncSettings.loadState();
      final last = state.lastGcAt;
      if (last != null && DateTime.now().difference(last) < gcInterval) {
        return 0;
      }
      final deleted = await pruneOldChunks(
        config: config,
        storage: storage,
        db: db,
      );
      await CloudSyncSettings.saveState(
        (await CloudSyncSettings.loadState()).copyWith(
          lastGcAt: DateTime.now(),
        ),
      );
      return deleted;
    } catch (e) {
      logWarning('CloudSyncMaintenance', '清理历史 chunk 失败: $e');
      return 0;
    }
  }

  /// 立即执行一次清理，返回成功删除的对象数量。
  static Future<int> pruneOldChunks({
    required CloudSyncConfig config,
    required S3StorageService storage,
    Database? db,
  }) async {
    final objects = await storage.list(
      '${config.devicesPrefix}/',
      recursive: true,
    );
    final chunks = objects
        .where((o) => o.key.contains('/chunks/') && o.key.endsWith('.jsonl'))
        .toList();
    if (chunks.isEmpty) return 0;

    final byDevice = <String, List<S3ObjectInfo>>{};
    for (final object in chunks) {
      final device = _deviceOf(object.key);
      if (device == null) continue;
      byDevice.putIfAbsent(device, () => []).add(object);
    }

    final cutoff = DateTime.now().toUtc().subtract(chunkRetention);
    final candidates = <S3ObjectInfo>[];
    for (final group in byDevice.values) {
      group.sort((a, b) => a.key.compareTo(b.key));
      final keep = group.length > keepChunksPerDevice
          ? keepChunksPerDevice
          : group.length;
      final removable = group.take(group.length - keep);
      for (final object in removable) {
        final modified = object.lastModified?.toUtc();
        if (modified == null) continue;
        if (modified.isAfter(cutoff)) continue;
        candidates.add(object);
      }
    }
    if (candidates.isEmpty) return 0;

    final failures = await storage.deleteMany(candidates.map((e) => e.key));
    try {
      final database = db ?? await DatabaseService.database;
      for (final object in candidates) {
        await database.delete(
          'sync_chunks',
          where: 'chunk_key = ?',
          whereArgs: [object.key],
        );
      }
    } catch (_) {
      // 本地记录清理失败不影响云端结果
    }
    final deleted = candidates.length - failures;
    logInfo(
      'CloudSyncMaintenance',
      '已清理 $deleted 个历史 chunk（保留每设备最近 $keepChunksPerDevice 个 / '
          '${chunkRetention.inDays} 天）',
    );
    return deleted;
  }

  static String? _deviceOf(String key) {
    const marker = '/devices/';
    final start = key.indexOf(marker);
    if (start < 0) return null;
    final idStart = start + marker.length;
    final idEnd = key.indexOf('/chunks/', idStart);
    if (idEnd < 0) return null;
    return key.substring(idStart, idEnd);
  }
}
