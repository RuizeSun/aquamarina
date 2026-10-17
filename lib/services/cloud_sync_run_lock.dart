import 'dart:async';

/// 进程内全局互斥：增量同步、快照上传/恢复、设备删除、自动检查点串行执行。
///
/// 这里用 Future 链把所有云端对象/数据库文件操作串起来，后到的请求等待前一个完成，
/// 避免两个 run 同时 LIST / PUT、manifest 读改写竞争，以及恢复与同步同时操作
/// 数据库文件。调用方不要在已持有本锁时再次调用会加锁的方法。
class CloudSyncRunLock {
  CloudSyncRunLock._();

  static Future<void> _tail = Future<void>.value();
  static bool _busy = false;
  static final Object _zoneKey = Object();

  static bool get isBusy => _busy;

  static Future<T> runExclusive<T>(Future<T> Function() action) {
    // 同一调用链内的嵌套操作直接执行，避免“接管并合并”等组合操作死锁。
    if (Zone.current[_zoneKey] == true) {
      return action();
    }
    final completer = Completer<void>();
    final previous = _tail;
    _tail = completer.future;
    return previous.then((_) {
      return runZoned(() async {
        _busy = true;
        try {
          return await action();
        } finally {
          _busy = false;
          completer.complete();
        }
      }, zoneValues: {_zoneKey: true});
    });
  }

  /// 仅用于测试：清空排队状态。
  static void debugReset() {
    _tail = Future<void>.value();
    _busy = false;
  }
}
