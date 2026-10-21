import 'dart:convert';

import 'package:aquamarina/models/cloud_sync_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

String _fakeSha(String char) => List.filled(64, char).join();

const String _deviceA = '11111111-1111-4111-8111-111111111111';
const String _deviceB = '22222222-2222-4222-8222-222222222222';

String _datasetSnapshotKey(String deviceId) =>
    'aquamarina/dataset/snapshots/20261018T120000000Z-$deviceId.zip';

CloudSnapshotInfo _snapshot(String key, DateTime createdAt) {
  return CloudSnapshotInfo(
    key: key,
    size: 1024,
    sha256: _fakeSha('a'),
    createdAt: createdAt,
    containsApiKeys: false,
  );
}

CloudDeviceManifest _manifest(
  List<CloudSnapshotInfo> snapshots, {
  List<String> contributors = const [],
}) {
  return CloudDeviceManifest(
    deviceId: 'a1b2c3d4-e5f6-7890-abcd-ef1234567890',
    deviceName: 'Windows-abcd',
    schemaVersion: 12,
    appVersion: '1.3.0+22',
    updatedAt: DateTime.utc(2026, 10, 17),
    snapshots: snapshots,
    contributors: contributors,
  );
}

void main() {
  group('CloudSnapshotInfo', () {
    test('JSON 往返', () {
      final info = _snapshot('snapshots/1.zip', DateTime.utc(2026, 10, 17, 1));
      final restored = CloudSnapshotInfo.fromJson(
        jsonDecode(jsonEncode(info.toJson())) as Map<String, dynamic>,
      );
      expect(restored.key, info.key);
      expect(restored.size, info.size);
      expect(restored.sha256, info.sha256);
      expect(restored.containsApiKeys, isFalse);
      expect(restored.createdAt.isUtc, isTrue);
    });

    test('拒绝缺失字段与非法哈希', () {
      expect(
        () => CloudSnapshotInfo.fromJson({'key': 'a.zip'}),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => CloudSnapshotInfo.fromJson({
          'key': 'a.zip',
          'size': 1,
          'sha256': 'too-short',
          'created_at': DateTime.utc(2026).toIso8601String(),
          'contains_api_keys': false,
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('CloudDeviceManifest', () {
    test('JSON 往返并按时间倒序', () {
      final manifest = _manifest([
        _snapshot('snapshots/old.zip', DateTime.utc(2026, 10, 16)),
        _snapshot('snapshots/new.zip', DateTime.utc(2026, 10, 17)),
      ]);
      final restored = CloudSyncUtils.parseManifest(
        CloudSyncUtils.encodeManifest(manifest),
      );
      expect(restored.latest?.key, 'snapshots/new.zip');
      expect(restored.snapshots.length, 2);
      expect(restored.deviceId, manifest.deviceId);
      expect(restored.schemaVersion, 12);
      expect(restored.appVersion, '1.3.0+22');
    });

    test('contributors 随清单往返，旧清单缺省为空', () {
      final manifest = _manifest(
        [_snapshot(_datasetSnapshotKey(_deviceA), DateTime.utc(2026, 10, 17))],
        contributors: [_deviceA, _deviceB],
      );
      final restored = CloudSyncUtils.parseManifest(
        CloudSyncUtils.encodeManifest(manifest),
      );
      expect(restored.contributors, [_deviceA, _deviceB]);

      final legacyJson = _manifest([]).toJson();
      expect(legacyJson.containsKey('contributors'), isFalse);
      expect(CloudDeviceManifest.fromJson(legacyJson).contributors, isEmpty);
    });

    test('拒绝非法的 contributors', () {
      final json = _manifest([]).toJson();
      json['contributors'] = 'device-a';
      expect(
        () => CloudDeviceManifest.fromJson(json),
        throwsA(isA<FormatException>()),
      );

      json['contributors'] = ['device-a', 1];
      expect(
        () => CloudDeviceManifest.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });

    test('旧清单可从快照 key 反推贡献设备', () {
      expect(
        CloudSyncUtils.snapshotUploaderDeviceId(_datasetSnapshotKey(_deviceA)),
        _deviceA,
      );
      expect(
        CloudSyncUtils.snapshotContributorIds([
          _snapshot(_datasetSnapshotKey(_deviceA), DateTime.utc(2026, 10, 17)),
          _snapshot(_datasetSnapshotKey(_deviceB), DateTime.utc(2026, 10, 16)),
          _snapshot('snapshots/old-format.zip', DateTime.utc(2026, 10, 15)),
        ]),
        {_deviceA, _deviceB},
      );
    });

    test('resolveContributorIds 合并保留、替换重置', () {
      final snapshots = [
        _snapshot(_datasetSnapshotKey(_deviceB), DateTime.utc(2026, 10, 17)),
      ];
      expect(
        CloudSyncUtils.resolveContributorIds(
          stored: const [],
          snapshots: snapshots,
          deviceId: _deviceA,
        ),
        unorderedEquals([_deviceB, _deviceA]),
      );
      expect(
        CloudSyncUtils.resolveContributorIds(
          stored: const [],
          snapshots: snapshots,
          deviceId: _deviceA,
          reset: true,
        ),
        [_deviceA],
      );
      expect(
        CloudSyncUtils.resolveContributorIds(
          stored: const [_deviceB],
          snapshots: const [],
          deviceId: _deviceA,
        ),
        [_deviceB, _deviceA],
      );
    });

    test('拒绝过新的格式版本', () {
      final json = _manifest([]).toJson();
      json['format_version'] = CloudDeviceManifest.currentFormatVersion + 1;
      expect(
        () => CloudDeviceManifest.fromJson(json),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('过新'),
          ),
        ),
      );
    });

    test('拒绝快照列表类型错误', () {
      final json = _manifest([]).toJson();
      json['snapshots'] = 'not-a-list';
      expect(
        () => CloudDeviceManifest.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });

    test('addSnapshot 去重、排序并截断保留份数', () {
      final first = _snapshot('snapshots/1.zip', DateTime.utc(2026, 10, 15));
      final second = _snapshot('snapshots/2.zip', DateTime.utc(2026, 10, 16));
      final third = _snapshot('snapshots/3.zip', DateTime.utc(2026, 10, 17));

      var manifest = _manifest([first, second]);
      manifest = manifest.addSnapshot(third, retainCount: 2);
      expect(manifest.snapshots.map((e) => e.key), [
        'snapshots/3.zip',
        'snapshots/2.zip',
      ]);

      // 相同 key 重传：覆盖而不重复
      final thirdUpdated = CloudSnapshotInfo(
        key: third.key,
        size: 2048,
        sha256: _fakeSha('b'),
        createdAt: third.createdAt,
        containsApiKeys: true,
      );
      manifest = manifest.addSnapshot(thirdUpdated, retainCount: 5);
      expect(manifest.snapshots.length, 2);
      expect(manifest.latest?.size, 2048);
      expect(manifest.latest?.containsApiKeys, isTrue);
    });

    test('retainCount 小于 1 时至少保留一份', () {
      final manifest = _manifest([]).addSnapshot(
        _snapshot('snapshots/1.zip', DateTime.utc(2026, 10, 17)),
        retainCount: 0,
      );
      expect(manifest.snapshots.length, 1);
    });

    test('清单 JSON 顶层不是对象时报错', () {
      expect(
        () => CloudSyncUtils.parseManifest(utf8.encode('[]')),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
