import 'dart:async';

import '../../models/cloud_sync_manifest.dart';
import 'cloud_sync_auto_sync_service.dart';
import 'cloud_sync_checkpoint_service.dart';
import 'cloud_sync_engine.dart';
import 'cloud_sync_foreground_sync_service.dart';
import 'cloud_sync_network_service.dart';
import 'cloud_sync_settings.dart';
import '../system/log_service.dart';
import 'sync_capture_service.dart';

/// 学习结束后的即时同步（事件驱动）。
///
/// - 2 秒防抖：学习/复习/拼写/测试/句型完成的多个回调合并为一次；
/// - 优先只 push 本机 oplog；距上次成功同步超过间隔时才顺带 pull；
/// - 无本地变更且未到拉取间隔时不发任何网络请求；
/// - 完成后重置前台轮询计时；
/// - 失败静默，日志记录，后续事件/轮询/回前台会重试。
class CloudSyncActivitySyncService {
  CloudSyncActivitySyncService._();

  static Duration debounce = const Duration(seconds: 2);

  /// 自动同步进行中时的补跑延迟，避免在微任务级别反复轮询。
  static Duration followUpDelay = const Duration(seconds: 2);

  static Timer? _debounceTimer;
  static Timer? _followUpTimer;
  static bool _running = false;
  static bool _followUp = false;

  // ── 测试注入点 ─────────────────────────────────────
  static Future<void> Function(bool pull)? debugRun;
  static Future<int> Function()? debugPendingCount;
  static Future<CloudSyncConfig?> Function()? debugConfig;
  static Future<CloudSyncRuntimeState> Function()? debugState;
  static void Function()? debugOnReset;

  /// 学习流程完成时调用（同步方法，不阻塞 UI）。
  static void notifyLearningCompleted() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () => unawaited(_flush()));
  }

  /// 测试 / 手动用：立即执行（仍受防抖之外的检查约束）。
  static Future<void> flushNow() => _flush();

  static Future<void> _flush() async {
    _followUpTimer?.cancel();
    _followUpTimer = null;
    if (_running) {
      _followUp = true;
      return;
    }
    _running = true;
    try {
      final config =
          await (debugConfig?.call() ?? CloudSyncSettings.loadConfig());
      if (config == null || !config.isConfigured || !config.autoSync) return;

      // 已有自动同步在跑：等它结束后补一次
      if (CloudSyncAutoSyncService.isRunning) {
        _followUp = true;
        return;
      }

      final pending =
          await (debugPendingCount?.call() ??
              SyncCaptureService.pendingCount());
      final state = await (debugState?.call() ?? CloudSyncSettings.loadState());
      final interval = Duration(minutes: config.autoSyncIntervalMinutes);
      final last = state.lastSuccessAt;
      final now = DateTime.now();
      if (state.backoffUntil != null && now.isBefore(state.backoffUntil!)) {
        return;
      }
      final pullDue = last == null || now.difference(last) >= interval;

      if (pending == 0 && !pullDue) return;
      if (!await CloudSyncNetworkService.isAllowed(config)) return;

      if (debugRun != null) {
        await debugRun!(pullDue);
      } else {
        final engine = await CloudSyncEngine.create();
        final result = await engine.run(pull: pullDue, push: true);
        if (result.hasErrors) {
          throw CloudSyncException(result.errors.first);
        }
        await CloudSyncSettings.updateState(
          (state) => state.copyWith(
            lastAutoSyncAt: DateTime.now(),
            consecutiveFailures: 0,
            clearBackoff: true,
            clearError: true,
          ),
        );
        await CloudSyncCheckpointService.maybeCreate(config: config);
      }
      logInfo('CloudSyncActivity', '学习结束同步完成：pending=$pending, pull=$pullDue');
    } catch (e) {
      logWarning('CloudSyncActivity', '学习结束同步失败: $e');
      try {
        await CloudSyncSettings.updateState((state) {
          final failures = state.consecutiveFailures + 1;
          return state.copyWith(
            lastError: '$e',
            consecutiveFailures: failures,
            backoffUntil: DateTime.now().add(
              Duration(
                minutes: (1 << (failures > 5 ? 5 : failures)).clamp(1, 60),
              ),
            ),
          );
        });
      } catch (_) {}
    } finally {
      _running = false;
      if (debugOnReset != null) {
        debugOnReset!();
      } else {
        CloudSyncForegroundSyncService.instance.resetCountdown();
      }
      if (_followUp) {
        _followUp = false;
        _followUpTimer?.cancel();
        _followUpTimer = Timer(followUpDelay, () => unawaited(_flush()));
      }
    }
  }

  /// 测试用：清理定时器与注入状态。
  static void resetForTesting() {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _followUpTimer?.cancel();
    _followUpTimer = null;
    _running = false;
    _followUp = false;
    debounce = const Duration(seconds: 2);
    followUpDelay = const Duration(seconds: 2);
    debugRun = null;
    debugPendingCount = null;
    debugConfig = null;
    debugState = null;
    debugOnReset = null;
  }
}
