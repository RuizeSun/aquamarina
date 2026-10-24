import 'package:aquamarina/models/cloud_sync_device_state.dart';
import 'package:aquamarina/models/cloud_sync_manifest.dart';
import 'package:aquamarina/services/cloud/cloud_sync_compatibility_service.dart';
import 'package:aquamarina/services/cloud/cloud_sync_settings.dart';
import 'package:aquamarina/services/data/database_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_s3_storage.dart';

const String _deviceA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const String _deviceB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

CloudSyncConfig _config() => CloudSyncConfig.create(
  endpointInput: 'https://cn-nb1.rains3.com',
  bucket: 'aquamarina-test',
  region: 'cn-nb1',
  prefix: 'aquamarina',
);

void _writeMeta(
  FakeS3Storage storage,
  CloudSyncConfig config, {
  required String deviceId,
  required String deviceName,
  required int schemaVersion,
  String? appVersion,
  int? protocolVersion,
  DateTime? lastSeen,
}) {
  final meta = CloudDeviceMeta(
    deviceId: deviceId,
    deviceName: deviceName,
    platform: 'Windows',
    schemaVersion: schemaVersion,
    appVersion: appVersion,
    syncProtocolVersion: protocolVersion,
    lastSeen: lastSeen ?? DateTime.now(),
  );
  storage.objects[config.metaKey(deviceId)] = CloudDeviceMetaCodec.encodeMeta(
    meta,
  );
}

void main() {
  late CloudSyncConfig config;
  late FakeS3Storage storage;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    config = _config();
    storage = FakeS3Storage(config);
  });

  test('版本号比较忽略 build number', () {
    expect(CloudSyncVersion.compare('1.4.2+30', '1.4.1+24'), 1);
    expect(CloudSyncVersion.compare('1.4.1+99', '1.4.1+24'), 0);
    expect(CloudSyncVersion.compare('v1.3.9', '1.4.0'), -1);
    expect(CloudSyncVersion.compare('unknown', '1.4.0'), isNull);
  });

  test('旧 meta 没有版本字段时视为未知，不阻断', () async {
    _writeMeta(
      storage,
      config,
      deviceId: _deviceB,
      deviceName: '旧设备',
      schemaVersion: DatabaseService.schemaVersion,
    );

    final result = await CloudSyncCompatibilityService.evaluate(
      config: config,
      storage: storage,
      localDeviceId: _deviceA,
      localAppVersion: '1.4.1+24',
    );
    expect(result.level, CloudSyncCompatibilityLevel.compatible);
    expect(result.isBlocked, isFalse);
  });

  test('对端 schema 更高时硬阻断', () async {
    _writeMeta(
      storage,
      config,
      deviceId: _deviceB,
      deviceName: '新设备',
      schemaVersion: DatabaseService.schemaVersion + 1,
      appVersion: '1.5.0+25',
      protocolVersion: 2,
    );

    final result = await CloudSyncCompatibilityService.evaluate(
      config: config,
      storage: storage,
      localDeviceId: _deviceA,
      localAppVersion: '1.4.1+24',
    );
    expect(result.level, CloudSyncCompatibilityLevel.blocked);
    expect(result.peerDeviceName, '新设备');
    expect(result.requiresUpgrade, isTrue);
    expect(result.reason, contains('schema'));
  });

  test('对端 App 版本更高但 schema 兼容时只软提示', () async {
    _writeMeta(
      storage,
      config,
      deviceId: _deviceB,
      deviceName: '新设备',
      schemaVersion: DatabaseService.schemaVersion,
      appVersion: '1.5.0+25',
      protocolVersion: 2,
    );

    final result = await CloudSyncCompatibilityService.evaluate(
      config: config,
      storage: storage,
      localDeviceId: _deviceA,
      localAppVersion: '1.4.1+24',
    );
    expect(result.level, CloudSyncCompatibilityLevel.softWarning);
    expect(result.isBlocked, isFalse);
    expect(result.reason, contains('版本不同'));
  });

  test('本机 meta 被更高 schema 写过时硬阻断（降级场景）', () async {
    _writeMeta(
      storage,
      config,
      deviceId: _deviceA,
      deviceName: '本机',
      schemaVersion: DatabaseService.schemaVersion + 1,
      appVersion: '1.5.0+25',
      protocolVersion: 2,
    );

    final result = await CloudSyncCompatibilityService.evaluate(
      config: config,
      storage: storage,
      localDeviceId: _deviceA,
      localAppVersion: '1.4.1+24',
    );
    expect(result.level, CloudSyncCompatibilityLevel.blocked);
  });

  test('超过活跃窗口的旧设备不参与硬阻断', () async {
    _writeMeta(
      storage,
      config,
      deviceId: _deviceB,
      deviceName: '陈旧设备',
      schemaVersion: DatabaseService.schemaVersion + 1,
      appVersion: '1.5.0+25',
      protocolVersion: 2,
      lastSeen: DateTime.now().subtract(const Duration(days: 60)),
    );

    final result = await CloudSyncCompatibilityService.evaluate(
      config: config,
      storage: storage,
      localDeviceId: _deviceA,
      localAppVersion: '1.4.1+24',
    );
    expect(result.level, CloudSyncCompatibilityLevel.compatible);
  });

  test('数据集清单的最低 schema 要求会阻断旧版本', () async {
    final manifest = CloudDeviceManifest(
      deviceId: 'dataset-1',
      deviceName: '云端数据',
      schemaVersion: DatabaseService.schemaVersion + 1,
      appVersion: '1.5.0+25',
      minSchemaVersion: DatabaseService.schemaVersion + 1,
      minProtocolVersion: 2,
      updatedAt: DateTime.now(),
      snapshots: const [],
    );
    storage.objects[config.datasetManifestKey] = CloudSyncUtils.encodeManifest(
      manifest,
    );

    final result = await CloudSyncCompatibilityService.evaluate(
      config: config,
      storage: storage,
      localDeviceId: _deviceA,
      localAppVersion: '1.4.1+24',
    );
    expect(result.level, CloudSyncCompatibilityLevel.blocked);
    expect(result.peerSchemaVersion, DatabaseService.schemaVersion + 1);
  });

  test('清单格式过新时转换为版本阻断而不是普通异常', () async {
    storage.objects[config.datasetManifestKey] = CloudSyncUtils.encodeManifest(
      CloudDeviceManifest(
        formatVersion: CloudDeviceManifest.currentFormatVersion + 1,
        deviceId: 'dataset-1',
        deviceName: '云端数据',
        schemaVersion: DatabaseService.schemaVersion,
        appVersion: '9.9.9+99',
        updatedAt: DateTime.now(),
        snapshots: const [],
      ),
    );

    final result = await CloudSyncCompatibilityService.evaluate(
      config: config,
      storage: storage,
      localDeviceId: _deviceA,
      localAppVersion: '1.4.1+24',
    );
    expect(result.level, CloudSyncCompatibilityLevel.blocked);
    expect(
      result.peerFormatVersion,
      CloudDeviceManifest.currentFormatVersion + 1,
    );
  });
}
