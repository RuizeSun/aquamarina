import 'package:aquamarina/services/cloud/cloud_sync_run_lock.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(CloudSyncRunLock.debugReset);
  tearDown(CloudSyncRunLock.debugReset);

  test('并发请求串行执行', () async {
    var active = 0;
    var maxActive = 0;
    final order = <String>[];

    Future<int> task(int index) {
      return CloudSyncRunLock.runExclusive(() async {
        active++;
        if (active > maxActive) maxActive = active;
        order.add('start$index');
        await Future<void>.delayed(const Duration(milliseconds: 5));
        order.add('end$index');
        active--;
        return index;
      });
    }

    final results = await Future.wait([task(0), task(1), task(2)]);
    expect(results, [0, 1, 2]);
    expect(maxActive, 1);
    expect(order, ['start0', 'end0', 'start1', 'end1', 'start2', 'end2']);
    expect(CloudSyncRunLock.isBusy, isFalse);
  });

  test('前一个任务失败不会阻塞后续任务', () async {
    final failed = CloudSyncRunLock.runExclusive<int>(() async {
      throw StateError('boom');
    });
    final next = CloudSyncRunLock.runExclusive<int>(() async => 42);

    await expectLater(failed, throwsStateError);
    expect(await next, 42);
    expect(CloudSyncRunLock.isBusy, isFalse);
  });
}
