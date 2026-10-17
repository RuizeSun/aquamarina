import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/cloud_sync_device_state.dart';
import '../models/sync_op.dart';
import 'cloud_sync_device_meta_service.dart';
import 'cloud_sync_settings.dart';
import 'database_service.dart';
import 'log_service.dart';
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

  /// 立即执行一次清理，返回成功删除的远端对象数量。
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
        .where(
          (o) =>
              o.key.contains('/chunks/') &&
              (o.key.endsWith('.jsonl') || o.key.endsWith('.jsonl.gz')),
        )
        .toList();
    if (chunks.isEmpty) return 0;

    final byDevice = <String, List<S3ObjectInfo>>{};
    for (final object in chunks) {
      final device = CloudSyncDeviceMetaService.deviceIdOfKey(object.key);
      if (device == null || device.isEmpty) continue;
      byDevice.putIfAbsent(device, () => []).add(object);
    }
    if (byDevice.isEmpty) return 0;
    for (final group in byDevice.values) {
      group.sort((a, b) => a.key.compareTo(b.key));
    }

    final meta = CloudSyncDeviceMetaService(config: config, storage: storage);
    final heads = <String, CloudDeviceHead?>{};
    final states = <String, CloudDeviceState?>{};
    for (final device in byDevice.keys) {
      heads[device] = await meta.fetchHead(device);
      states[device] = await meta.fetchState(device);
    }
    // 没有 chunk 但有 head/state 的设备也要参与水位判断：
    // 它们可能只是从未上传过自己的变更，但仍然需要其它设备的历史 chunk。
    final extraDevices = <String>{};
    try {
      for (final device in await meta.listDeviceIds()) {
        if (byDevice.containsKey(device)) continue;
        final head = await meta.fetchHead(device);
        final state = await meta.fetchState(device);
        if (head == null && state == null) continue;
        heads[device] = head;
        states[device] = state;
        extraDevices.add(device);
      }
    } catch (e) {
      logWarning('CloudSyncMaintenance', '读取其它设备水位失败: $e');
      return 0;
    }

    final now = DateTime.now().toUtc();
    final candidatesForActivity = {...byDevice.keys, ...extraDevices};
    final activeDevices = <String>{
      for (final device in candidatesForActivity)
        if (_isActive(now, heads[device]?.updatedAt, states[device]?.updatedAt))
          device,
    };
    if (activeDevices.isEmpty) return 0;

    // 任意一个「非 owner」活跃设备缺少 state，就无法证明它已经拿到历史变更，
    // 对应 owner 的 chunk 本轮不删；owner 自身的 chunk 不需要自己的 state。
    final candidates = <String>[];
    for (final entry in byDevice.entries) {
      final owner = entry.key;
      final group = entry.value;
      final head = heads[owner];
      final ownerLatest = head != null
          ? _parseHlc(head.latestHlc)
          : _chunkStartHlc(group.last.key);
      for (final object in group) {
        final start = _chunkStartHlc(object.key);
        final modified = object.lastModified?.toUtc();
        if (start == null || modified == null) continue;
        if (ownerLatest != null && start.compareTo(ownerLatest) > 0) {
          continue;
        }
        if (now.difference(modified) < minChunkRetention) continue;
        final appliedEverywhere = activeDevices.every((device) {
          if (device == owner) return true;
          final state = states[device];
          if (state == null) return false;
          final watermark = state.appliedFor(owner);
          return watermark != null && watermark.compareTo(start) >= 0;
        });
        if (appliedEverywhere) candidates.add(object.key);
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
