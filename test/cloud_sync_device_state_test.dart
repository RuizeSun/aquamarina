import 'package:aquamarina/models/cloud_sync_device_state.dart';
import 'package:aquamarina/models/sync_op.dart';
import 'package:flutter_test/flutter_test.dart';

const String _deviceA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const String _deviceB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

String _hlc(int ms) => SyncHlc(ms, 0).value;

void main() {
  test('head 编解码保留 chunk 水位', () {
    final head = CloudDeviceHead(
      deviceId: _deviceA,
      deviceName: '设备 A',
      latestChunkKey: 'aquamarina/devices/$_deviceA/chunks/x.jsonl',
      latestHlc: _hlc(1000),
      chunkCount: 3,
      updatedAt: DateTime.utc(2026, 10, 18, 1, 2, 3),
    );
    final parsed = CloudDeviceMetaCodec.parseHead(
      CloudDeviceMetaCodec.encodeHead(head),
    );
    expect(parsed.deviceId, _deviceA);
    expect(parsed.latestHlc, _hlc(1000));
    expect(parsed.chunkCount, 3);
    expect(parsed.updatedAt.toUtc(), DateTime.utc(2026, 10, 18, 1, 2, 3));
  });

  test('head 拒绝缺失字段与过新版本', () {
    expect(
      () => CloudDeviceHead.fromJson({'format_version': 1}),
      throwsFormatException,
    );
    expect(
      () => CloudDeviceHead.fromJson({
        'format_version': 999,
        'device_id': _deviceA,
        'device_name': 'A',
        'latest_chunk_key': 'k',
        'latest_hlc': _hlc(1),
        'chunk_count': 0,
        'updated_at': DateTime.now().toIso8601String(),
      }),
      throwsFormatException,
    );
  });

  test('state 合并水位时只保留更大的 HLC', () {
    final state = CloudDeviceState(
      deviceId: _deviceA,
      deviceName: '设备 A',
      applied: {_deviceB: _hlc(2000)},
      updatedAt: DateTime.now(),
    );
    final older = state.withApplied(_deviceB, _hlc(1000));
    expect(older.appliedFor(_deviceB), SyncHlc(2000, 0));

    final newer = state.withApplied(_deviceB, _hlc(3000));
    expect(newer.appliedFor(_deviceB), SyncHlc(3000, 0));

    final added = older.withApplied(
      'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
      _hlc(500),
    );
    expect(added.applied.length, 2);
  });

  test('state 编解码与非法 applied 校验', () {
    final state = CloudDeviceState(
      deviceId: _deviceA,
      deviceName: '设备 A',
      applied: {_deviceB: _hlc(2000)},
      updatedAt: DateTime.utc(2026, 10, 18),
    );
    final parsed = CloudDeviceMetaCodec.parseState(
      CloudDeviceMetaCodec.encodeState(state),
    );
    expect(parsed.applied, {_deviceB: _hlc(2000)});

    expect(
      () => CloudDeviceState.fromJson({
        'format_version': 1,
        'device_id': _deviceA,
        'device_name': 'A',
        'applied': {_deviceB: 'not-an-hlc'},
        'updated_at': DateTime.now().toIso8601String(),
      }),
      throwsFormatException,
    );
  });

  test('meta 编解码保留设备名称与平台', () {
    final meta = CloudDeviceMeta(
      deviceId: _deviceA,
      deviceName: '设备 A',
      platform: 'Windows',
      schemaVersion: 19,
      lastSeen: DateTime.utc(2026, 10, 18, 2, 3, 4),
    );
    final parsed = CloudDeviceMetaCodec.parseMeta(
      CloudDeviceMetaCodec.encodeMeta(meta),
    );
    expect(parsed.deviceId, _deviceA);
    expect(parsed.deviceName, '设备 A');
    expect(parsed.platform, 'Windows');
    expect(parsed.schemaVersion, 19);
    expect(parsed.lastSeen.toUtc(), DateTime.utc(2026, 10, 18, 2, 3, 4));
  });
}
