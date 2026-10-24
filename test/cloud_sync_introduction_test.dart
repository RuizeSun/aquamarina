import 'package:aquamarina/models/cloud_sync_manifest.dart';
import 'package:aquamarina/services/cloud/cloud_sync_introduction_service.dart';
import 'package:aquamarina/services/cloud/cloud_sync_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _deviceA = '11111111-1111-4111-8111-111111111111';
const String _deviceB = '22222222-2222-4222-8222-222222222222';

CloudDeviceManifest _manifest({
  List<String> contributors = const [],
  List<CloudSnapshotInfo> snapshots = const [],
}) {
  return CloudDeviceManifest(
    deviceId: 'dataset-id',
    deviceName: '云端数据',
    schemaVersion: 20,
    appVersion: '1.4.2+25',
    updatedAt: DateTime.utc(2026, 10, 21),
    snapshots: snapshots,
    contributors: contributors,
  );
}

CloudSnapshotInfo _snapshot(String deviceId) {
  return CloudSnapshotInfo(
    key: 'aquamarina/dataset/snapshots/20261021T120000000Z-$deviceId.zip',
    size: 1024,
    sha256: List.filled(64, 'a').join(),
    createdAt: DateTime.utc(2026, 10, 21),
    containsApiKeys: false,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('首次接入决策按 datasetId 记录，且互不影响', () async {
    expect(await CloudSyncSettings.loadIntroDecision('dataset-a'), isNull);

    await CloudSyncSettings.saveIntroDecision('dataset-a', 'merge');

    final saved = await CloudSyncSettings.loadIntroDecision('dataset-a');
    expect(saved, isNotNull);
    expect(saved, contains('merge'));
    expect(await CloudSyncSettings.loadIntroDecision('dataset-b'), isNull);
  });

  test('空 datasetId 不会写入或读取决策', () async {
    await CloudSyncSettings.saveIntroDecision('', 'merge');
    expect(await CloudSyncSettings.loadIntroDecision(''), isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getKeys().where((key) => key.startsWith('cloud_sync_intro_v1:')),
      isEmpty,
    );
  });

  test('contributors 判断本机是否已经贡献过该数据集', () {
    final explicit = _manifest(
      contributors: [_deviceB],
      snapshots: [_snapshot(_deviceA)],
    );
    // 旧快照来自 A，但显式 contributors 只记录 B：替换后不应把 A 算进来。
    expect(
      CloudSyncIntroductionService.hasContributed(explicit, _deviceB),
      isTrue,
    );
    expect(
      CloudSyncIntroductionService.hasContributed(explicit, _deviceA),
      isFalse,
    );

    // 旧清单没有 contributors 时，从快照 key 反推上传者。
    final legacy = _manifest(snapshots: [_snapshot(_deviceA)]);
    expect(
      CloudSyncIntroductionService.hasContributed(legacy, _deviceA),
      isTrue,
    );
    expect(
      CloudSyncIntroductionService.hasContributed(legacy, _deviceB),
      isFalse,
    );
    expect(
      CloudSyncIntroductionService.hasContributed(null, _deviceA),
      isFalse,
    );
    expect(CloudSyncIntroductionService.hasContributed(legacy, ''), isFalse);
  });

  test('两台设备合并后，已贡献的一端不再需要换 datasetId', () {
    // D1 由 B 上传，A 尚未贡献。
    final d1 = _manifest(snapshots: [_snapshot(_deviceB)]);
    expect(CloudSyncIntroductionService.hasContributed(d1, _deviceA), isFalse);

    // A 合并后上传 D2，contributors 变为 B + A。
    final d2 = _manifest(
      contributors: CloudSyncUtils.resolveContributorIds(
        stored: d1.contributors,
        snapshots: d1.snapshots,
        deviceId: _deviceA,
      ),
      snapshots: [_snapshot(_deviceA), _snapshot(_deviceB)],
    );

    // B 再次确认时已经在 contributors 中，只做本地合并、不再换 ID。
    expect(CloudSyncIntroductionService.hasContributed(d2, _deviceB), isTrue);
  });
}
