import 'package:connectivity_plus/connectivity_plus.dart';

import 'cloud_sync_settings.dart';

/// 自动同步的网络策略（P2-7）。
///
/// - `wifiOnly=false` 时不限制网络；
/// - `wifiOnly=true` 时只允许 Wi-Fi / 以太网；
/// - 无法读取网络状态时放行，避免因平台限制永久停止同步。
class CloudSyncNetworkService {
  CloudSyncNetworkService._();

  /// 测试注入：返回是否允许同步。
  static Future<bool> Function()? debugAllowed;

  static Future<bool> isAllowed(CloudSyncConfig config) async {
    if (!config.wifiOnly) return true;
    if (debugAllowed != null) return debugAllowed!();
    try {
      final results = await Connectivity().checkConnectivity();
      return results.any(
        (result) =>
            result == ConnectivityResult.wifi ||
            result == ConnectivityResult.ethernet,
      );
    } catch (_) {
      return true;
    }
  }

  static void resetForTesting() {
    debugAllowed = null;
  }
}
