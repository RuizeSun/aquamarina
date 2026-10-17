import 'dart:typed_data';

import 'package:aquamarina/models/cloud_sync_device_state.dart';
import 'package:aquamarina/models/sync_op.dart';
import 'package:aquamarina/services/cloud_sync_device_meta_service.dart';
import 'package:aquamarina/services/cloud_sync_maintenance_service.dart';
import 'package:aquamarina/services/cloud_sync_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fake_s3_storage.dart';
import 'sync_test_support.dart';

const String _deviceA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const String _deviceB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

CloudSyncConfig _config() => CloudSyncConfig.create(
  endpointInput: 'https://cn-nb1.rains3.com',
  bucket: 'aquamarina-test',
  region: 'cn-nb1',
  prefix: 'aquamarina',
);

String _hlc(int ms) => SyncHlc(ms, 0).value;

String _chunkKey(CloudSyncConfig config, String deviceId, int ms) {
  final hlc = _hlc(ms).replaceAll(':', '-');
  return '${config.devicePrefix(deviceId)}/chunks/$hlc-'
      'aaaaaaaaaaaaaaaa.jsonl';
}

void main() {
  late Database db;
  late FakeS3Storage storage;
  late CloudSyncConfig config;
  late CloudSyncDeviceMetaService meta;

  setUp(() async {
    db = await openSyncTestDb();
    config = _config();
    storage = FakeS3Storage(config);
    meta = CloudSyncDeviceMetaService(config: config, storage: storage);
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> addChunk(String device, int ms, {DateTime? modified}) async {
    final key = _chunkKey(config, device, ms);
    storage.objects[key] = Uint8List.fromList([1, 2, 3]);
    storage.lastModified[key] = modified ?? DateTime.now().toUtc();
  }

  Future<void> addHead(String device, int latestMs) async {
    final key = _chunkKey(config, device, latestMs);
    await meta.saveHead(
      CloudDeviceHead(
        deviceId: device,
        deviceName: device,
        latestChunkKey: key,
        latestHlc: _hlc(latestMs),
        chunkCount: 1,
        updatedAt: DateTime.now(),
      ),
    );
  }

  Future<void> addState(String device, Map<String, String> applied) async {
    await meta.saveState(
      CloudDeviceState(
        deviceId: device,
        deviceName: device,
        applied: applied,
        updatedAt: DateTime.now(),
      ),
    );
  }

  test('所有活跃设备水位越过后删除 chunk，并清理本地记录', () async {
    final now = DateTime.now().toUtc();
    final old = now.subtract(const Duration(days: 31));
    await addChunk(_deviceA, 1000, modified: old);
    await addChunk(_deviceA, 2000, modified: now);
    await addHead(_deviceA, 2000);
    await addState(_deviceA, {_deviceB: _hlc(500)});

    for (final ms in [1000, 2000]) {
      await db.insert('sync_chunks', {
        'device_id': _deviceA,
        'chunk_key': _chunkKey(config, _deviceA, ms),
        'sha256':
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        'min_hlc': _hlc(ms),
        'max_hlc': _hlc(ms),
        'applied_at': now.toIso8601String(),
      });
      await db.insert('sync_applied', {
        'device_id': _deviceA,
        'entity': 'word_notes',
        'seq': ms,
        'hlc': _hlc(ms),
        'applied_at': now.toIso8601String(),
      });
    }
    await db.insert('sync_tombstones', {
      'entity': 'word_notes',
      'key': '{"word":"apple"}',
      'deleted_hlc': _hlc(100),
      'deleted_at': now.subtract(const Duration(days: 200)).toIso8601String(),
    });

    final deleted = await CloudSyncMaintenanceService.pruneOldChunks(
      config: config,
      storage: storage,
      db: db,
    );

    expect(deleted, 1);
    expect(
      storage.objects.containsKey(_chunkKey(config, _deviceA, 1000)),
      isFalse,
    );
    expect(
      storage.objects.containsKey(_chunkKey(config, _deviceA, 2000)),
      isTrue,
    );
    final chunks = await db.query('sync_chunks');
    expect(chunks.single['min_hlc'], _hlc(2000));
    final applied = await db.query('sync_applied');
    expect(applied.single['hlc'], _hlc(2000));
    expect(await db.query('sync_tombstones'), isEmpty);
  });

  test('仍有活跃设备水位未越过时保留 chunk', () async {
    final now = DateTime.now().toUtc();
    final old = now.subtract(const Duration(days: 31));
    await addChunk(_deviceA, 1000, modified: old);
    await addHead(_deviceA, 1000);
    await addChunk(_deviceB, 1000, modified: now);
    await addHead(_deviceB, 1000);
    // B 只应用到 500，A 的 1000 仍需要保留。
    await addState(_deviceB, {_deviceA: _hlc(500)});
    await addState(_deviceA, {_deviceB: _hlc(1000)});

    final deleted = await CloudSyncMaintenanceService.pruneOldChunks(
      config: config,
      storage: storage,
      db: db,
    );

    expect(deleted, 0);
    expect(
      storage.objects.containsKey(_chunkKey(config, _deviceA, 1000)),
      isTrue,
    );
  });

  test('未超过最小保留期的 chunk 不会被删除', () async {
    final now = DateTime.now().toUtc();
    await addChunk(
      _deviceA,
      1000,
      modified: now.subtract(const Duration(days: 5)),
    );
    await addHead(_deviceA, 1000);
    await addState(_deviceA, {});

    final deleted = await CloudSyncMaintenanceService.pruneOldChunks(
      config: config,
      storage: storage,
      db: db,
    );

    expect(deleted, 0);
    expect(
      storage.objects.containsKey(_chunkKey(config, _deviceA, 1000)),
      isTrue,
    );
  });
}
