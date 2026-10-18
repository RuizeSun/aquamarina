import 'dart:convert';

import 'package:aquamarina/models/cloud_sync_device_state.dart';
import 'package:aquamarina/models/sync_op.dart';
import 'package:flutter_test/flutter_test.dart';

const String _deviceA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

List<int> _bytes(Map<String, dynamic> json) => utf8.encode(jsonEncode(json));

void main() {
  test('meta 新版本字段可往返并保持 format_version=1', () {
    final meta = CloudDeviceMeta(
      deviceId: _deviceA,
      deviceName: '设备 A',
      platform: 'Windows',
      schemaVersion: 19,
      appVersion: '1.4.1+24',
      syncProtocolVersion: 2,
      lastSeen: DateTime.utc(2026, 10, 18, 2, 3, 4),
    );
    final parsed = CloudDeviceMetaCodec.parseMeta(
      CloudDeviceMetaCodec.encodeMeta(meta),
    );
    expect(parsed.formatVersion, 1);
    expect(parsed.appVersion, '1.4.1+24');
    expect(parsed.syncProtocolVersion, 2);
  });

  test('旧 meta 缺少版本字段时解析为 null', () {
    final parsed = CloudDeviceMetaCodec.parseMeta(
      _bytes({
        'format_version': 1,
        'device_id': _deviceA,
        'device_name': '旧设备',
        'platform': 'Windows',
        'schema_version': 19,
        'last_seen': DateTime.utc(2026, 10, 18).toIso8601String(),
      }),
    );
    expect(parsed.appVersion, isNull);
    expect(parsed.syncProtocolVersion, isNull);
    expect(parsed.schemaVersion, 19);
  });

  test('更高格式的 meta 返回 newerFormat 且尽量保留已知字段', () {
    final result = CloudDeviceMetaCodec.decodeMeta(
      _bytes({
        'format_version': 2,
        'device_id': _deviceA,
        'device_name': '未来设备',
        'platform': 'Windows',
        'schema_version': 20,
        'app_version': '1.5.0+25',
        'sync_protocol_version': 3,
        'last_seen': DateTime.utc(2026, 10, 18).toIso8601String(),
        'future_field': {'x': 1},
      }),
    );
    expect(result.status, CloudDeviceReadStatus.newerFormat);
    expect(result.remoteFormatVersion, 2);
    expect(result.value?.deviceName, '未来设备');
    expect(result.value?.schemaVersion, 20);
    expect(result.value?.appVersion, '1.5.0+25');
    expect(result.value?.syncProtocolVersion, 3);
  });

  test('更高格式但字段不兼容时仍返回 newerFormat', () {
    final result = CloudDeviceMetaCodec.decodeMeta(
      _bytes({'format_version': 2, 'future_only': true}),
    );
    expect(result.status, CloudDeviceReadStatus.newerFormat);
    expect(result.value, isNull);
    expect(result.remoteFormatVersion, 2);
  });

  test('损坏的 meta 返回 corrupted', () {
    final result = CloudDeviceMetaCodec.decodeMeta(
      _bytes({'format_version': 1}),
    );
    expect(result.status, CloudDeviceReadStatus.corrupted);
    expect(result.error, isNotNull);
  });

  test('head 也携带版本字段且可往返', () {
    final head = CloudDeviceHead(
      deviceId: _deviceA,
      deviceName: '设备 A',
      latestChunkKey: 'k',
      latestHlc: SyncHlc(1000, 0).value,
      chunkCount: 1,
      appVersion: '1.4.1+24',
      schemaVersion: 19,
      syncProtocolVersion: 2,
      updatedAt: DateTime.utc(2026, 10, 18),
    );
    final parsed = CloudDeviceMetaCodec.parseHead(
      CloudDeviceMetaCodec.encodeHead(head),
    );
    expect(parsed.appVersion, '1.4.1+24');
    expect(parsed.schemaVersion, 19);
    expect(parsed.syncProtocolVersion, 2);
  });
}
