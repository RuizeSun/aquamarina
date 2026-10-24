import 'dart:async';

import 'cloud_sync_auto_sync_service.dart';
import 'cloud_sync_settings.dart';
import '../system/log_service.dart';

/// App 前台期间的增量同步轮询。
///
/// - 只在 `resumed` 状态运行，后台立即停止；
/// - 间隔来自 `CloudSyncConfig.autoSyncIntervalMinutes`；
/// - 学习结束等事件同步完成后调用 [resetCountdown]，重新开始计时。
class CloudSyncForegroundSyncService {
  CloudSyncForegroundSyncService._();

  static final CloudSyncForegroundSyncService instance =
      CloudSyncForegroundSyncService._();

  Timer? _timer;
  Duration? _interval;
  Future<void> Function()? _tick;

  bool get isRunning => _timer != null;

  /// 根据当前配置启动轮询；未配置 / 关闭自动同步时停止。
  Future<void> start() async {
    final config = await CloudSyncSettings.loadConfig();
    if (config == null || !config.isConfigured || !config.autoSync) {
      stop();
      return;
    }
    _interval = Duration(minutes: config.autoSyncIntervalMinutes);
    _tick = () => CloudSyncAutoSyncService.maybeSync();
    _begin();
    // 回到前台立即尝试一次（内部仍受冷却约束）
    unawaited(_tick!());
  }

  /// 测试入口：注入 tick 与间隔，不读取配置。
  void startForTesting({
    required Future<void> Function() onTick,
    required Duration interval,
  }) {
    _tick = onTick;
    _interval = interval;
    _begin();
    unawaited(onTick());
  }

  /// 事件同步完成后重新开始计时，避免“刚同步完又立刻轮询”。
  void resetCountdown() {
    if (_timer == null) return;
    _begin();
  }

  void stop() {
    if (_timer != null) {
      logInfo('CloudSyncForeground', '前台自动同步已停止');
    }
    _timer?.cancel();
    _timer = null;
  }

  void _begin() {
    _timer?.cancel();
    final interval = _interval;
    final tick = _tick;
    if (interval == null || tick == null) return;
    _timer = Timer.periodic(interval, (_) => unawaited(tick()));
    logInfo('CloudSyncForeground', '前台自动同步已启动，间隔 ${interval.inMinutes} 分钟');
  }
}
