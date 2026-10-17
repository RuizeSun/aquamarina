import 'package:aquamarina/services/cloud_sync_foreground_sync_service.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final service = CloudSyncForegroundSyncService.instance;

  tearDown(() {
    service.stop();
  });

  test('start 立即触发一次，按间隔轮询，stop 后停止', () {
    fakeAsync((async) {
      var count = 0;
      service.startForTesting(
        onTick: () async {
          count++;
        },
        interval: const Duration(minutes: 5),
      );
      async.flushMicrotasks();
      expect(count, 1);

      async.elapse(const Duration(minutes: 5));
      expect(count, 2);
      async.elapse(const Duration(minutes: 5));
      expect(count, 3);

      service.stop();
      async.elapse(const Duration(minutes: 30));
      expect(count, 3);
    });
  });

  test('resetCountdown 重新开始计时', () {
    fakeAsync((async) {
      var count = 0;
      service.startForTesting(
        onTick: () async {
          count++;
        },
        interval: const Duration(minutes: 5),
      );
      async.flushMicrotasks();
      expect(count, 1);

      async.elapse(const Duration(minutes: 4));
      service.resetCountdown();
      async.elapse(const Duration(minutes: 4));
      expect(count, 1);
      async.elapse(const Duration(minutes: 1));
      expect(count, 2);
    });
  });
}
