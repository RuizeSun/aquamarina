import '../models/cloud_sync_manifest.dart';
import 'cloud_sync_checkpoint_service.dart';
import 'cloud_sync_engine.dart';
import 'cloud_sync_network_service.dart';
import 'cloud_sync_settings.dart';
import 'log_service.dart';

/// 自动增量同步：启动 / 回到前台时触发，带冷却与并发保护。
///
/// 不弹 UI、不抛异常；失败只写日志，下一次生命周期事件或手动同步会重试。
class CloudSyncAutoSyncService {
  CloudSyncAutoSyncService._();

  /// 自动同步最小间隔，避免频繁切前后台造成网络与耗电压力。
  /// 实际值来自 `CloudSyncConfig.autoSyncIntervalMinutes`。
  static const Duration defaultCooldown = Duration(minutes: 5);

  static bool _running = false;

  static bool get isRunning => _running;

  static Future<void> maybeSync({bool force = false}) async {
    if (_running) return;
    // 必须在第一个 await 之前置位：config / credentials / 网络检查期间
    // 另一个 resume/tick 也可能进入，否则会并发启动两次同步。
    _running = true;
    CloudSyncConfig? config;
    try {
      try {
        config = await CloudSyncSettings.loadConfig();
      } catch (_) {
        return;
      }
      if (config == null || !config.isConfigured || !config.autoSync) return;

      final credentials = await CloudSyncSettings.loadCredentials();
      if (credentials == null || !credentials.isComplete) return;

      final state = await CloudSyncSettings.loadState();
      final now = DateTime.now();
      if (state.backoffUntil != null && now.isBefore(state.backoffUntil!)) {
        return;
      }
      final last = state.lastAutoSyncAt;
      final cooldown = Duration(
        minutes: config.autoSyncIntervalMinutes > 0
            ? config.autoSyncIntervalMinutes
            : defaultCooldown.inMinutes,
      );
      if (!force && last != null && now.difference(last) < cooldown) {
        return;
      }
      if (!await CloudSyncNetworkService.isAllowed(config)) {
        logInfo('CloudSyncAutoSync', '当前网络不满足「仅 Wi-Fi」设置，跳过本次同步');
        return;
      }

      final engine = await CloudSyncEngine.create();
      final result = await engine.run();
      if (result.hasErrors) {
        throw CloudSyncException(result.errors.first);
      }
      logInfo(
        'CloudSyncAutoSync',
        '自动同步完成：pull=${result.pulledOps} ops，'
            'push=${result.pushedOps} ops，pending=${result.remainingLocalOps}',
      );
      await CloudSyncSettings.updateState(
        (state) => state.copyWith(
          lastAutoSyncAt: DateTime.now(),
          consecutiveFailures: 0,
          clearBackoff: true,
          clearError: true,
        ),
      );
      // 自动检查点：内部有 7 天 / 5000 op 冷却，失败不影响同步。
      await CloudSyncCheckpointService.maybeCreate(config: config);
    } catch (e) {
      try {
        final cooldownMinutes =
            (config?.autoSyncIntervalMinutes ?? defaultCooldown.inMinutes)
                .clamp(1, 60);
        var failures = 0;
        var backoffMinutes = cooldownMinutes;
        await CloudSyncSettings.updateState((state) {
          failures = state.consecutiveFailures + 1;
          final exponent = failures > 5 ? 5 : failures;
          backoffMinutes = (cooldownMinutes * (1 << exponent)).clamp(1, 60);
          return state.copyWith(
            lastError: '$e',
            consecutiveFailures: failures,
            backoffUntil: DateTime.now().add(Duration(minutes: backoffMinutes)),
          );
        });
        logWarning(
          'CloudSyncAutoSync',
          '自动同步失败（连续 $failures 次，退避 $backoffMinutes 分钟）: $e',
        );
      } catch (_) {
        // 状态写入失败时仍保留日志；下一次生命周期事件会重试。
      }
    } finally {
      _running = false;
    }
  }
}
