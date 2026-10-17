import 'dart:io';
import 'dart:typed_data';

import 'package:aquamarina/models/cloud_sync_manifest.dart';
import 'package:aquamarina/services/cloud_sync_service.dart';
import 'package:aquamarina/services/cloud_sync_settings.dart';
import 'package:aquamarina/services/s3_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// 真实对象存储集成测试（默认跳过）。
///
/// 运行前设置环境变量：
///   S3_ENDPOINT / S3_BUCKET / S3_REGION / S3_ACCESS_KEY / S3_SECRET_KEY
/// 可选：S3_PATH_STYLE=true|false（默认 true）、S3_PREFIX（默认 aquamarina-ci）
void main() {
  final env = Platform.environment;
  final accessKey = env['S3_ACCESS_KEY'];
  final secretKey = env['S3_SECRET_KEY'];
  final hasCredentials =
      accessKey != null &&
      accessKey.isNotEmpty &&
      secretKey != null &&
      secretKey.isNotEmpty;
  final config = hasCredentials
      ? CloudSyncConfig.create(
          endpointInput: env['S3_ENDPOINT'] ?? 'cn-nb1.rains3.com',
          bucket: env['S3_BUCKET'] ?? 'aquamarina-test',
          region: env['S3_REGION'] ?? 'cn-nb1',
          prefix: env['S3_PREFIX'] ?? 'aquamarina-ci',
          pathStyle: (env['S3_PATH_STYLE'] ?? 'true').toLowerCase() != 'false',
        )
      : null;

  test('连接测试（Bucket/PUT/GET/LIST/DELETE）', () async {
    final service = S3StorageService(
      config: config!,
      accessKey: accessKey!,
      secretKey: secretKey!,
    );
    final message = await service.testConnection();
    expect(message, contains('连接成功'));
  }, skip: hasCredentials ? false : '未设置 S3_* 环境变量，跳过真实存储集成测试');

  test('设备清单上传/列举/清理（真实存储）', () async {
    const deviceId = '99999999-9999-4999-8999-999999999999';
    final storage = S3StorageService(
      config: config!,
      accessKey: accessKey!,
      secretKey: secretKey!,
    );
    final service = CloudSyncService.forTesting(
      config: config,
      deviceId: deviceId,
      deviceName: 'CI 测试设备',
      storage: storage,
    );

    final now = DateTime.now().toUtc();
    final snapshotKey = config.snapshotKey(
      deviceId,
      CloudSyncUtils.utcTimestamp(now),
    );
    final payload = Uint8List.fromList([1, 2, 3, 4, 5]);
    final snapshot = CloudSnapshotInfo(
      key: snapshotKey,
      size: payload.length,
      sha256: CloudSyncUtils.sha256Hex(payload),
      createdAt: now,
      containsApiKeys: false,
    );
    final manifest = CloudDeviceManifest(
      deviceId: deviceId,
      deviceName: 'CI 测试设备',
      schemaVersion: 12,
      appVersion: 'test',
      updatedAt: now,
      snapshots: [snapshot],
    );

    try {
      await storage.putBytes(snapshotKey, payload);
      await storage.putBytes(
        config.manifestKey(deviceId),
        CloudSyncUtils.encodeManifest(manifest),
      );

      final devices = await service.listDevices();
      final found = devices.where((d) => d.manifest.deviceId == deviceId);
      expect(found, isNotEmpty);
      expect(found.first.latest?.sha256, snapshot.sha256);

      final fetched = await service.fetchManifest(deviceId);
      expect(fetched?.snapshots.length, 1);
      expect(fetched?.latest?.size, payload.length);

      final bytes = await storage.getBytes(snapshotKey);
      expect(bytes, payload);
    } finally {
      await service.deleteOwnCloudData();
    }

    expect(await service.fetchManifest(deviceId), isNull);
  }, skip: hasCredentials ? false : '未设置 S3_* 环境变量，跳过真实存储集成测试');
}
