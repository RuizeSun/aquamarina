import 'package:aquamarina/services/cloud/cloud_sync_activity_sync_service.dart';
import 'package:aquamarina/services/cloud/cloud_sync_settings.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

CloudSyncConfig _config({bool autoSync = true, int interval = 5}) {
  return CloudSyncConfig.create(
    endpointInput: 'https://cn-nb1.rains3.com',
    bucket: 'aquamarina-test',
    region: 'cn-nb1',
    autoSync: autoSync,
    autoSyncIntervalMinutes: interval,
  );
}

void main() {
  setUp(() {
    CloudSyncActivitySyncService.resetForTesting();
    CloudSyncActivitySyncService.debounce = const Duration(seconds: 2);
  });

  tearDown(() {
    CloudSyncActivitySyncService.resetForTesting();
  });

  test('2 秒防抖合并多次学习完成事件，仅 push 一次', () {
    fakeAsync((async) {
      final pulls = <bool>[];
      var resets = 0;
      CloudSyncActivitySyncService.debugConfig = () async => _config();
      CloudSyncActivitySyncService.debugState = () async =>
          CloudSyncRuntimeState(lastSuccessAt: DateTime.now());
      CloudSyncActivitySyncService.debugPendingCount = () async => 1;
      CloudSyncActivitySyncService.debugRun = (pull) async {
        pulls.add(pull);
      };
      CloudSyncActivitySyncService.debugOnReset = () => resets++;

      CloudSyncActivitySyncService.notifyLearningCompleted();
      async.elapse(const Duration(seconds: 1));
      CloudSyncActivitySyncService.notifyLearningCompleted();
      CloudSyncActivitySyncService.notifyLearningCompleted();
      async.elapse(const Duration(seconds: 2));
      async.flushMicrotasks();

      expect(pulls, [false]);
      expect(resets, 1);
    });
  });

  test('无本地变更且未到拉取间隔时不发起同步', () {
    fakeAsync((async) {
      var runs = 0;
      CloudSyncActivitySyncService.debugConfig = () async => _config();
      CloudSyncActivitySyncService.debugState = () async =>
          CloudSyncRuntimeState(lastSuccessAt: DateTime.now());
      CloudSyncActivitySyncService.debugPendingCount = () async => 0;
      CloudSyncActivitySyncService.debugRun = (pull) async {
        runs++;
      };

      CloudSyncActivitySyncService.notifyLearningCompleted();
      async.elapse(const Duration(seconds: 3));
      async.flushMicrotasks();

      expect(runs, 0);
    });
  });

  test('距上次同步超过间隔时会顺带拉取', () {
    fakeAsync((async) {
      final pulls = <bool>[];
      CloudSyncActivitySyncService.debugConfig = () async => _config();
      CloudSyncActivitySyncService.debugState = () async =>
          CloudSyncRuntimeState(
            lastSuccessAt: DateTime.now().subtract(const Duration(minutes: 10)),
          );
      CloudSyncActivitySyncService.debugPendingCount = () async => 1;
      CloudSyncActivitySyncService.debugRun = (pull) async {
        pulls.add(pull);
      };

      CloudSyncActivitySyncService.notifyLearningCompleted();
      async.elapse(const Duration(seconds: 3));
      async.flushMicrotasks();

      expect(pulls, [true]);
    });
  });

  test('关闭自动同步后学习完成事件不触发同步', () {
    fakeAsync((async) {
      var runs = 0;
      CloudSyncActivitySyncService.debugConfig = () async =>
          _config(autoSync: false);
      CloudSyncActivitySyncService.debugState = () async =>
          CloudSyncRuntimeState(lastSuccessAt: DateTime.now());
      CloudSyncActivitySyncService.debugPendingCount = () async => 1;
      CloudSyncActivitySyncService.debugRun = (pull) async {
        runs++;
      };

      CloudSyncActivitySyncService.notifyLearningCompleted();
      async.elapse(const Duration(seconds: 3));
      async.flushMicrotasks();

      expect(runs, 0);
    });
  });
}
