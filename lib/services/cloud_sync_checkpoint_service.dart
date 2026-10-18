import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/cloud_sync_manifest.dart';
import 'cloud_sync_service.dart';
import 'cloud_sync_settings.dart';
import 'database_service.dart';
import 'log_service.dart';

/// 自动检查点：复用完整快照，作为新设备引导与灾备基线（P2-2）。
///
/// 触发条件（先到者）：
/// - 距上次检查点 ≥ 7 天；
/// - 累计变更（本机上传 + 远端应用）≥ [opThreshold]；
/// - 从未生成过检查点（首次同步成功后立即生成一份）。
class CloudSyncCheckpointService {
  CloudSyncCheckpointService._();

  static const Duration interval = Duration(days: 7);
  static const int opThreshold = 5000;

  /// 失败退避：30 分钟起步，最长 24 小时。
  static const Duration failureBackoffBase = Duration(minutes: 30);
  static const Duration failureBackoffMax = Duration(hours: 24);

  static bool _running = false;

  /// 返回本次生成的快照；未到触发条件或未配置时返回 null。
  static Future<CloudSnapshotInfo?> maybeCreate({
    CloudSyncConfig? config,
    Database? db,
    DateTime? now,
  }) async {
    if (_running) return null;
    _running = true;
    try {
      final cfg = config ?? await CloudSyncSettings.loadConfig();
      if (cfg == null || !cfg.isConfigured || !cfg.autoCheckpoint) {
        return null;
      }
      final state = await CloudSyncSettings.loadState();
      final current = now ?? DateTime.now();
      if (state.checkpointBackoffUntil != null &&
          current.isBefore(state.checkpointBackoffUntil!)) {
        return null;
      }
      final database = db ?? await DatabaseService.database;
      final total = await _totalOps(database);
      final lastAt = state.lastCheckpointAt;
      // 恢复快照后 total_ops 会重置为 0；此时 total < lastCheckpointOps
      // 视为“数据基线已变”，应允许重新生成检查点。
      final delta = total >= state.lastCheckpointOps
          ? total - state.lastCheckpointOps
          : total;
      final due = lastAt == null
          ? total > 0
          : (current.difference(lastAt) >= interval || delta >= opThreshold);
      if (!due) return null;

      await CloudSyncSettings.updateState(
        (state) => state.copyWith(lastCheckpointAttemptAt: current),
      );
      final service = await CloudSyncService.create();
      final snapshot = await service.uploadSnapshot(includeApiKeys: false);
      await CloudSyncSettings.updateState(
        (state) => state.copyWith(
          lastCheckpointAt: current,
          lastCheckpointOps: total,
          checkpointConsecutiveFailures: 0,
          clearCheckpointBackoff: true,
          clearError: true,
        ),
      );
      logInfo(
        'CloudSyncCheckpoint',
        '自动检查点完成 key=${snapshot.key} size=${snapshot.size} totalOps=$total',
      );
      return snapshot;
    } catch (e) {
      final current = now ?? DateTime.now();
      try {
        var failures = 0;
        var capped = failureBackoffMax;
        await CloudSyncSettings.updateState((state) {
          failures = state.checkpointConsecutiveFailures + 1;
          final exponent = failures > 6 ? 6 : failures - 1;
          final backoff = failureBackoffBase * (1 << exponent);
          capped = backoff > failureBackoffMax ? failureBackoffMax : backoff;
          return state.copyWith(
            lastCheckpointAttemptAt: current,
            checkpointConsecutiveFailures: failures,
            checkpointBackoffUntil: current.add(capped),
          );
        });
        logWarning(
          'CloudSyncCheckpoint',
          '自动检查点失败（连续 $failures 次，退避 ${capped.inMinutes} 分钟）: $e',
        );
      } catch (_) {
        logWarning('CloudSyncCheckpoint', '自动检查点失败（不影响同步）: $e');
      }
      return null;
    } finally {
      _running = false;
    }
  }

  /// 测试用：清理进程内状态。
  static void resetForTesting() {
    _running = false;
  }

  static Future<int> _totalOps(Database db) async {
    final rows = await db.query(
      'sync_meta',
      columns: ['total_ops'],
      where: 'id = 1',
      limit: 1,
    );
    return rows.isEmpty ? 0 : ((rows.first['total_ops'] as int?) ?? 0);
  }
}
