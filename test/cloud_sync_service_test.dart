import 'dart:typed_data';

import 'package:aquamarina/models/cloud_sync_manifest.dart';
import 'package:aquamarina/services/cloud_sync_service.dart';
import 'package:aquamarina/services/cloud_sync_settings.dart';
import 'package:aquamarina/services/s3_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

const String _deviceA = '11111111-1111-4111-8111-111111111111';
const String _deviceB = '22222222-2222-4222-8222-222222222222';

CloudSyncConfig _config() => CloudSyncConfig.create(
  endpointInput: 'https://cn-nb1.rains3.com',
  bucket: 'aquamarina-test',
  region: 'cn-nb1',
);

CloudDeviceManifest _manifest({
  required String deviceId,
  required String deviceName,
  required DateTime updatedAt,
  String? snapshotKey,
}) {
  return CloudDeviceManifest(
    deviceId: deviceId,
    deviceName: deviceName,
    schemaVersion: 12,
    appVersion: '1.3.0+22',
    updatedAt: updatedAt,
    snapshots: snapshotKey == null
        ? const []
        : [
            CloudSnapshotInfo(
              key: snapshotKey,
              size: 128,
              sha256: List.filled(64, 'a').join(),
              createdAt: updatedAt,
              containsApiKeys: false,
            ),
          ],
  );
}

class _FakeStorage extends S3StorageService {
  _FakeStorage(this._config)
    : super(
        config: _config,
        accessKey: 'test-access',
        secretKey: 'test-secret',
      );

  final CloudSyncConfig _config;
  final Map<String, Uint8List> objects = {};

  @override
  Future<String> putBytes(
    String key,
    Uint8List bytes, {
    void Function(int sent, int total)? onProgress,
  }) async {
    objects[key] = bytes;
    onProgress?.call(bytes.length, bytes.length);
    return 'etag-${objects.length}';
  }

  @override
  Future<Uint8List?> getBytes(
    String key, {
    int maxBytes = 500 * 1024 * 1024,
    bool nullIfMissing = false,
    void Function(int received, int? total)? onProgress,
  }) async {
    final bytes = objects[key];
    if (bytes == null && !nullIfMissing) {
      throw const CloudSyncException('云端对象不存在');
    }
    if (bytes != null) onProgress?.call(bytes.length, bytes.length);
    return bytes;
  }

  @override
  Future<S3ObjectInfo?> stat(String key, {bool nullIfMissing = false}) async {
    final bytes = objects[key];
    if (bytes == null) {
      if (nullIfMissing) return null;
      throw const CloudSyncException('云端对象不存在');
    }
    return S3ObjectInfo(key: key, size: bytes.length, etag: 'etag');
  }

  @override
  Future<List<S3ObjectInfo>> list(
    String prefix, {
    bool recursive = true,
  }) async {
    return objects.entries
        .where((entry) => entry.key.startsWith(prefix))
        .map(
          (entry) => S3ObjectInfo(
            key: entry.key,
            size: entry.value.length,
            etag: 'etag',
          ),
        )
        .toList();
  }

  @override
  Future<void> delete(String key) async {
    objects.remove(key);
  }

  @override
  Future<int> deleteMany(Iterable<String> keys) async {
    var deleted = 0;
    for (final key in keys) {
      if (objects.remove(key) != null) deleted++;
    }
    return deleted == keys.length ? 0 : keys.length - deleted;
  }

  String manifestKey(String deviceId) => _config.manifestKey(deviceId);
}

void main() {
  late _FakeStorage storage;
  late CloudSyncService service;

  setUp(() {
    storage = _FakeStorage(_config());
    service = CloudSyncService.forTesting(
      config: _config(),
      deviceId: _deviceA,
      deviceName: '当前设备',
      storage: storage,
    );
  });

  void seedManifest(CloudDeviceManifest manifest) {
    storage.objects[storage.manifestKey(manifest.deviceId)] =
        CloudSyncUtils.encodeManifest(manifest);
  }

  test('列出云端设备：按更新时间倒序、标记本机、跳过损坏清单', () async {
    seedManifest(
      _manifest(
        deviceId: _deviceA,
        deviceName: '当前设备',
        updatedAt: DateTime.utc(2026, 10, 17, 10),
        snapshotKey: _config().snapshotKey(_deviceA, '20261017T100000000Z'),
      ),
    );
    seedManifest(
      _manifest(
        deviceId: _deviceB,
        deviceName: '旧设备',
        updatedAt: DateTime.utc(2026, 10, 16, 10),
        snapshotKey: _config().snapshotKey(_deviceB, '20261016T100000000Z'),
      ),
    );
    storage.objects['${_config().prefix}/devices/33333333-3333-4333-8333-333333333333/manifest.json'] =
        Uint8List.fromList([1, 2, 3]);

    final devices = await service.listDevices();
    expect(devices.length, 2);
    expect(devices.first.manifest.deviceId, _deviceA);
    expect(devices.first.isCurrentDevice, isTrue);
    expect(devices.last.manifest.deviceId, _deviceB);
    expect(devices.last.isCurrentDevice, isFalse);
    expect(devices.first.latest?.key, contains('/snapshots/'));
  });

  test('fetchManifest 对不存在的设备返回 null', () async {
    expect(await service.fetchManifest(_deviceB), isNull);
  });

  test('deleteOwnCloudData 只删除本设备前缀', () async {
    seedManifest(
      _manifest(
        deviceId: _deviceA,
        deviceName: '当前设备',
        updatedAt: DateTime.utc(2026, 10, 17),
      ),
    );
    seedManifest(
      _manifest(
        deviceId: _deviceB,
        deviceName: '旧设备',
        updatedAt: DateTime.utc(2026, 10, 16),
      ),
    );

    final deleted = await service.deleteOwnCloudData();
    expect(deleted, 1);
    expect(storage.objects.keys, everyElement(contains(_deviceB)));
    expect(await service.fetchManifest(_deviceB), isNotNull);
  });
}
