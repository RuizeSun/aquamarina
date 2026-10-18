import 'dart:typed_data';

import 'package:aquamarina/models/cloud_sync_manifest.dart';
import 'package:aquamarina/services/cloud_sync_service.dart';
import 'package:aquamarina/services/cloud_sync_settings.dart';
import 'package:aquamarina/services/s3_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'sync_test_support.dart';

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
    String? startAfter,
    bool Function(String key)? stopWhen,
  }) async {
    final entries =
        objects.entries
            .where((entry) => entry.key.startsWith(prefix))
            .where(
              (entry) =>
                  startAfter == null || entry.key.compareTo(startAfter) > 0,
            )
            .toList()
          ..sort((a, b) => a.key.compareTo(b.key));
    final out = <S3ObjectInfo>[];
    for (final entry in entries) {
      out.add(
        S3ObjectInfo(key: entry.key, size: entry.value.length, etag: 'etag'),
      );
      if (stopWhen != null && stopWhen(entry.key)) break;
    }
    return out;
  }

  @override
  Future<List<String>> listCommonPrefixes(String prefix) async {
    final out = <String>{};
    for (final key in objects.keys) {
      if (!key.startsWith(prefix)) continue;
      final rest = key.substring(prefix.length);
      final slash = rest.indexOf('/');
      if (slash < 0) continue;
      out.add('$prefix${rest.substring(0, slash + 1)}');
    }
    return (out.toList()..sort());
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
  late Database db;

  setUp(() async {
    db = await openSyncTestDb();
    storage = _FakeStorage(_config());
    service = CloudSyncService.forTesting(
      config: _config(),
      deviceId: _deviceA,
      deviceName: '当前设备',
      storage: storage,
      database: db,
    );
  });

  tearDown(() async {
    await db.close();
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

  test('删除云端设备后清理本机同步记录', () async {
    seedManifest(
      _manifest(
        deviceId: _deviceB,
        deviceName: '旧设备',
        updatedAt: DateTime.utc(2026, 10, 16),
      ),
    );
    final now = DateTime.now().toUtc().toIso8601String();
    for (final device in [_deviceA, _deviceB]) {
      await db.insert('sync_state', {
        'device_id': device,
        'last_seq': 0,
        'last_hlc': null,
        'last_chunk_key': null,
        'updated_at': now,
      });
      await db.insert('sync_applied', {
        'device_id': device,
        'entity': 'word_notes',
        'seq': 1,
        'hlc': null,
        'applied_at': now,
      });
      await db.insert('sync_chunks', {
        'device_id': device,
        'chunk_key': '${_config().devicePrefix(device)}/chunks/x.jsonl',
        'sha256': List.filled(64, 'a').join(),
        'min_hlc': null,
        'max_hlc': null,
        'applied_at': now,
      });
      await db.insert('sync_backend_watermarks', {
        'backend_id': _config().backendIdentity,
        'device_id': device,
        'last_hlc': '0000000000000000:00000000',
        'last_chunk_key': null,
        'saved_at': now,
      });
    }

    await service.deleteDeviceData(_deviceB);

    for (final table in [
      'sync_state',
      'sync_applied',
      'sync_chunks',
      'sync_backend_watermarks',
    ]) {
      final rows = await db.query(table);
      expect(
        rows.map((row) => row['device_id']),
        everyElement(_deviceA),
        reason: table,
      );
    }
    expect(await service.fetchManifest(_deviceB), isNull);
  });
}
