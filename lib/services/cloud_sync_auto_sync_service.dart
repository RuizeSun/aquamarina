import 'cloud_sync_engine.dart';
import 'cloud_sync_settings.dart';
import 'log_service.dart';

/// 自动增量同步：启动 / 回到前台时触发，带冷却与并发保护。
///
/// 不弹 UI、不抛异常；失败只写日志，下一次生命周期事件或手动同步会重试。
class CloudSyncAutoSyncService {
  CloudSyncAutoSyncService._();

  /// 自动同步最小间隔，避免频繁切前后台造成网络与耗电压力。
  static const Duration cooldown = Duration(minutes: 15);

  static bool _running = false;

  static Future<void> maybeSync({bool force = false}) async {
    if (_running) return;

    final CloudSyncConfig? config;
    try {
      config = await CloudSyncSettings.loadConfig();
    } catch (_) {
      return;
    }
    if (config == null || !config.isConfigured || !config.autoSync) return;

    final credentials = await CloudSyncSettings.loadCredentials();
    if (credentials == null || !credentials.isComplete) return;

    final state = await CloudSyncSettings.loadState();
    final last = state.lastAutoSyncAt;
    if (!force && last != null && DateTime.now().difference(last) < cooldown) {
      return;
    }

    _running = true;
    try {
      final engine = await CloudSyncEngine.create();
      final result = await engine.run();
      logInfo(
        'CloudSyncAutoSync',
        '自动同步完成：pull=${result.pulledOps} ops，'
            'push=${result.pushedOps} ops，pending=${result.remainingLocalOps}',
      );
      await CloudSyncSettings.saveState(
        (await CloudSyncSettings.loadState()).copyWith(
          lastAutoSyncAt: DateTime.now(),
          clearError: true,
        ),
      );
    } catch (e) {
      logWarning('CloudSyncAutoSync', '自动同步失败: $e');
    } finally {
      _running = false;
    }
  }
}
