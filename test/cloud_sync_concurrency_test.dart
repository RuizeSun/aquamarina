import 'package:aquamarina/services/cloud_sync_device_meta_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('有限并发会处理全部条目且不超过并发上限', () async {
    final items = List<int>.generate(10, (index) => index);
    final done = <int>[];
    var active = 0;
    var peak = 0;

    await runWithConcurrency<int>(items, (item) async {
      active++;
      peak = active > peak ? active : peak;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      done.add(item);
      active--;
    }, concurrency: 3);

    expect(done.toSet(), items.toSet());
    expect(done.length, items.length);
    expect(peak, lessThanOrEqualTo(3));
    expect(peak, greaterThan(1));
  });

  test('空列表直接完成', () async {
    var called = false;
    await runWithConcurrency<int>([], (_) async => called = true);
    expect(called, isFalse);
  });

  test('任务异常会向上传播', () async {
    await expectLater(
      runWithConcurrency<int>([1, 2], (item) async {
        if (item == 2) throw StateError('boom');
      }, concurrency: 1),
      throwsStateError,
    );
  });
}
