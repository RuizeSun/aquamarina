import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../models/cloud_sync_device_state.dart';
import '../../models/sync_op.dart';
import 'cloud_sync_device_meta_service.dart';
import 'cloud_sync_settings.dart';
import '../data/database_service.dart';
import '../system/log_service.dart';
import 's3_storage_service.dart';
import 'sync_conflict_store.dart';

/// 云端增量数据维护：按设备水位清理历史 chunk。
///
/// 规则（宁可少删，不可误删）：
/// - 只有确认所有活跃设备都已应用某个 chunk，且该对象超过
///   [minChunkRetention] 后才删除；
/// - 任何活跃设备缺少 `state.json` 时本轮不删除（等它完成一次同步）；
/// - 超过 [inactiveDeviceWindow] 未更新的设备视为失联，不再参与水位计算；
/// - 删除远端 chunk 后，同步清理本地 `sync_chunks`、`sync_applied`
///   与已经无人需要的墓碑。
class CloudSyncMaintenanceService {
  CloudSyncMaintenanceService._();

  static const Duration gcInterval = Duration(days: 7);
  static const Duration minChunkRetention = Duration(days: 30);
  static const Duration tombstoneRetention = Duration(days: 180);
  static const Duration inactiveDeviceWindow = Duration(days: 180);

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
      try {
        final pruned = await SyncConflictStore.prune(db: db);
        if (pruned > 0) {
          logInfo('CloudSyncMaintenance', '已清理 $pruned 条过期冲突记录');
        }
      } catch (e) {
        logWarning('CloudSyncMaintenance', '清理冲突记录失败: $e');
      }
      await CloudSyncSettings.updateState(
        (state) => state.copyWith(lastGcAt: DateTime.now()),
      );
      return deleted;
    } catch (e) {
      logWarning('CloudSyncMaintenance', '清理历史 chunk 失败: $e');
      return 0;
    }
  }

  /// 立即执行一次清理，返回成功删除的远端对象数量。
  static Future<int> pruneOldChunks({
    required CloudSyncConfig config,
    required S3StorageService storage,
    Database? db,
  }) async {
    final meta = CloudSyncDeviceMetaService(config: config, storage: storage);
    // 设备目录用一次非递归 LIST 发现，避免把所有设备的 chunk 一次性
    // 递归列举进内存。后续只按设备列举自己的 chunks/。
    final deviceIds = await meta.listDeviceIds();
    if (deviceIds.isEmpty) return 0;

    final heads = <String, CloudDeviceHead?>{};
    final states = <String, CloudDeviceState?>{};
    final now = DateTime.now().toUtc();
    for (final device in deviceIds) {
      heads[device] = await meta.fetchHead(device);
      states[device] = await meta.fetchState(device);
    }
    // 只有带 head/state 的设备能证明自己拿到了哪些历史变更。
    // 完全没有元数据的目录（如仅含快照）不参与水位，避免误删。
    final activeDevices = <String>{
      for (final device in deviceIds)
        if ((heads[device] != null || states[device] != null) &&
            _isActive(now, heads[device]?.updatedAt, states[device]?.updatedAt))
          device,
    };
    if (activeDevices.isEmpty) return 0;

    // 每个 owner 的可删除上界 = min(自身 head, 所有非 owner 活跃设备已应用水位)。
    // 任一非 owner 缺少 state 或该来源水位时，本轮跳过这个 owner。
    final limits = <String, SyncHlc?>{};
    final byDevice = <String, List<S3ObjectInfo>>{};
    for (final owner in deviceIds) {
      var limit = _parseHlc(heads[owner]?.latestHlc);
      var blocked = false;
      for (final device in activeDevices) {
        if (device == owner) continue;
        final state = states[device];
        if (state == null) {
          blocked = true;
          break;
        }
        final watermark = state.appliedFor(owner);
        if (watermark == null) {
          blocked = true;
          break;
        }
        if (limit == null || watermark.compareTo(limit) < 0) {
          limit = watermark;
        }
      }
      if (blocked) continue;

      final cap = limit;
      final objects = await storage.list(
        '${config.devicePrefix(owner)}/chunks/',
        recursive: true,
        stopWhen: cap == null
            ? null
            : (key) {
                final start = _chunkStartHlc(key);
                // 键按 HLC 排序：越过水位后包含一个边界对象即可停止，
                // 后续对象不可能再被删除，也不必读入内存。
                return start != null && start.compareTo(cap) > 0;
              },
      );
      final chunks =
          objects
              .where(
                (o) =>
                    o.key.contains('/chunks/') &&
                    (o.key.endsWith('.jsonl') || o.key.endsWith('.jsonl.gz')),
              )
              .toList()
            ..sort((a, b) => a.key.compareTo(b.key));
      if (chunks.isEmpty) continue;
      limits[owner] = limit;
      byDevice[owner] = chunks;
    }
    if (byDevice.isEmpty) return 0;

    final candidates = <String>[];
    for (final entry in byDevice.entries) {
      final limit = limits[entry.key];
      for (final object in entry.value) {
        final start = _chunkStartHlc(object.key);
        final modified = object.lastModified?.toUtc();
        if (start == null || modified == null) continue;
        if (limit != null && start.compareTo(limit) > 0) continue;
        if (now.difference(modified) < minChunkRetention) continue;
        candidates.add(object.key);
      }
    }
    if (candidates.isEmpty) return 0;

    final deletedKeys = <String>{};
    for (final key in candidates) {
      try {
        await storage.delete(key);
        deletedKeys.add(key);
      } catch (e) {
        logWarning('CloudSyncMaintenance', '删除历史 chunk 失败 $key: $e');
      }
    }
    if (deletedKeys.isEmpty) return 0;

    final globalMin = _globalMinWatermark(activeDevices, heads, states);
    await _pruneLocalState(
      db: db,
      byDevice: byDevice,
      deletedKeys: deletedKeys,
      globalMinHlc: globalMin,
    );

    final deleted = deletedKeys.length;
    logInfo(
      'CloudSyncMaintenance',
      '已清理 $deleted 个历史 chunk（所有活跃设备水位已越过 / '
          '至少保留 ${minChunkRetention.inDays} 天）',
    );
    return deleted;
  }

  /// 计算所有活跃设备都已越过的最小 HLC（用于墓碑清理）。
  static SyncHlc? _globalMinWatermark(
    Set<String> activeDevices,
    Map<String, CloudDeviceHead?> heads,
    Map<String, CloudDeviceState?> states,
  ) {
    SyncHlc? min;
    void consider(SyncHlc? hlc) {
      if (hlc == null) return;
      if (min == null || hlc.compareTo(min!) < 0) min = hlc;
    }

    for (final device in activeDevices) {
      consider(_parseHlc(heads[device]?.latestHlc));
      final applied = states[device]?.applied ?? const <String, String>{};
      for (final value in applied.values) {
        consider(_parseHlc(value));
      }
    }
    return min;
  }

  static Future<void> _pruneLocalState({
    required Database? db,
    required Map<String, List<S3ObjectInfo>> byDevice,
    required Set<String> deletedKeys,
    required SyncHlc? globalMinHlc,
  }) async {
    final database = db ?? await DatabaseService.database;
    try {
      await database.transaction((txn) async {
        for (final entry in byDevice.entries) {
          final owner = entry.key;
          final remaining = entry.value
              .where((o) => !deletedKeys.contains(o.key))
              .toList();
          final nextRetained = remaining.isEmpty
              ? null
              : _chunkStartHlc(remaining.first.key);
          if (nextRetained == null) {
            await txn.delete(
              'sync_applied',
              where: 'device_id = ?',
              whereArgs: [owner],
            );
          } else {
            await txn.delete(
              'sync_applied',
              where: 'device_id = ? AND hlc IS NOT NULL AND hlc < ?',
              whereArgs: [owner, nextRetained.value],
            );
          }
          // 没有 hlc 的历史行无法按水位判断，按保留期兜底。
          final legacyCutoff = DateTime.now()
              .toUtc()
              .subtract(tombstoneRetention)
              .toIso8601String();
          await txn.delete(
            'sync_applied',
            where: 'device_id = ? AND hlc IS NULL AND applied_at < ?',
            whereArgs: [owner, legacyCutoff],
          );
        }
        for (final key in deletedKeys) {
          await txn.delete(
            'sync_chunks',
            where: 'chunk_key = ?',
            whereArgs: [key],
          );
        }
        if (globalMinHlc != null) {
          final cutoff = DateTime.now()
              .toUtc()
              .subtract(tombstoneRetention)
              .toIso8601String();
          await txn.delete(
            'sync_tombstones',
            where: 'deleted_at < ? AND deleted_hlc < ?',
            whereArgs: [cutoff, globalMinHlc.value],
          );
          // 行版本与墓碑同寿命清理：所有活跃设备都已越过且超过保留期后，
          // 不再需要用它阻止极端迟到的事件；避免表无限增长。
          final cutoffHlc = SyncHlc(
            DateTime.now()
                .toUtc()
                .subtract(tombstoneRetention)
                .millisecondsSinceEpoch,
            0,
          ).value;
          await txn.delete(
            'sync_row_versions',
            where: 'hlc < ? AND hlc < ?',
            whereArgs: [cutoffHlc, globalMinHlc.value],
          );
        }
      });
    } catch (e) {
      logWarning('CloudSyncMaintenance', '清理本地同步记录失败: $e');
    }
  }

  static bool _isActive(
    DateTime now,
    DateTime? headUpdatedAt,
    DateTime? stateUpdatedAt,
  ) {
    final latest = _latest(headUpdatedAt, stateUpdatedAt);
    if (latest == null) return true; // 没有元数据时按活跃处理，避免误删
    return now.difference(latest) <= inactiveDeviceWindow;
  }

  static DateTime? _latest(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.isAfter(b) ? a : b;
  }

  static SyncHlc? _parseHlc(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return SyncHlc.parse(raw);
    } on FormatException {
      return null;
    }
  }

  static SyncHlc? _chunkStartHlc(String key) {
    final name = key.split('/').last;
    final parts = name.split('-');
    if (parts.length < 2) return null;
    final ms = int.tryParse(parts[0], radix: 16);
    final counter = int.tryParse(parts[1], radix: 16);
    if (ms == null || counter == null) return null;
    return SyncHlc(ms, counter);
  }
}
