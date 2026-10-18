import 'package:flutter/foundation.dart';

/// 远端同步写入本地数据库后广播变更，让常驻页面重新查询数据。
///
/// 后台同步没有 `BuildContext`，且会绕过页面使用的业务服务直接写 SQLite；
/// 页面（尤其是 `IndexedStack` 中常驻的主 Tab）必须监听这里，才能在同步
/// 完成后立即刷新，而不是等用户手动切换 Tab。
class SyncDataChangeNotifier extends ChangeNotifier {
  SyncDataChangeNotifier._();

  static final SyncDataChangeNotifier instance = SyncDataChangeNotifier._();

  int _revision = 0;

  /// 远端数据变更次数，便于测试或需要时判断是否有新数据。
  int get revision => _revision;

  /// 通知 UI 本地数据库已被远端同步修改。
  void notifyRemoteDataChanged() {
    _revision++;
    notifyListeners();
  }
}
