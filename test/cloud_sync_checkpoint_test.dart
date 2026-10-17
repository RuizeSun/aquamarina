import 'package:aquamarina/services/cloud_sync_checkpoint_service.dart';
import 'package:aquamarina/services/cloud_sync_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sync_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final config = CloudSyncConfig.create(
    endpointInput: 'https://cn-nb1.rains3.com',
    bucket: 'aquamarina-test',
    region: 'cn-nb1',
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    CloudSyncCheckpointService.resetForTesting();
  });

  test('累计变更为 0 时不生成空检查点', () async {
    final db = await openSyncTestDb();
    try {
      await db.update('sync_meta', {'total_ops': 0}, where: 'id = 1');
      final snapshot = await CloudSyncCheckpointService.maybeCreate(
        config: config,
        db: db,
      );
      expect(snapshot, isNull);
    } finally {
      await db.close();
    }
  });

  test('检查点退避期内不重试', () async {
    final db = await openSyncTestDb();
    try {
      await db.update('sync_meta', {'total_ops': 100}, where: 'id = 1');
      await CloudSyncSettings.saveState(
        CloudSyncRuntimeState(
          checkpointBackoffUntil: DateTime.now().add(const Duration(hours: 1)),
        ),
      );
      final snapshot = await CloudSyncCheckpointService.maybeCreate(
        config: config,
        db: db,
      );
      expect(snapshot, isNull);
    } finally {
      await db.close();
    }
  });
}
