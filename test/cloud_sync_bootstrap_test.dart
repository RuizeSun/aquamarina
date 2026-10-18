import 'package:aquamarina/models/cloud_sync_manifest.dart';
import 'package:aquamarina/services/cloud_sync_bootstrap_service.dart';
import 'package:flutter_test/flutter_test.dart';

CloudDeviceSummary _device(String id, DateTime createdAt, {required int size}) {
  final manifest = CloudDeviceManifest(
    deviceId: id,
    deviceName: id,
    schemaVersion: 17,
    appVersion: '1.4.0+23',
    updatedAt: createdAt,
    snapshots: [
      CloudSnapshotInfo(
        key: 'aquamarina/devices/$id/snapshots/snapshot.zip',
        size: size,
        sha256: 'a'.padRight(64, 'a'),
        createdAt: createdAt,
        containsApiKeys: false,
      ),
    ],
  );
  return CloudDeviceSummary(manifest: manifest, isCurrentDevice: false);
}

void main() {
  group('CloudSyncBootstrapService.chooseCandidate', () {
    test('最新快照明显更小时选择数据更完整的快照', () {
      final rich = _device(
        'windows',
        DateTime.utc(2026, 10, 18, 0, 45),
        size: 95 * 1024,
      );
      final nearlyEmpty = _device(
        'android',
        DateTime.utc(2026, 10, 18, 8, 28),
        size: 7 * 1024,
      );

      final chosen = CloudSyncBootstrapService.chooseCandidate([
        nearlyEmpty,
        rich,
      ]);
      expect(chosen?.manifest.deviceId, 'windows');
    });

    test('体积相近时仍选择最新的快照', () {
      final older = _device(
        'windows',
        DateTime.utc(2026, 10, 18, 0, 45),
        size: 95 * 1024,
      );
      final newer = _device(
        'android',
        DateTime.utc(2026, 10, 18, 8, 28),
        size: 90 * 1024,
      );

      final chosen = CloudSyncBootstrapService.chooseCandidate([older, newer]);
      expect(chosen?.manifest.deviceId, 'android');
    });

    test('没有快照时返回 null', () {
      expect(CloudSyncBootstrapService.chooseCandidate(const []), isNull);
    });
  });
}
