import 'dart:io';
import 'dart:typed_data';

import 'package:aquamarina/models/cloud_sync_manifest.dart';
import 'package:aquamarina/services/cloud_sync_device_meta_service.dart';
import 'package:aquamarina/services/cloud_sync_engine.dart';
import 'package:aquamarina/services/cloud_sync_service.dart';
import 'package:aquamarina/services/cloud_sync_settings.dart';
import 'package:aquamarina/services/s3_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sync_test_support.dart';

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
  }, timeout: const Timeout(Duration(minutes: 2)), skip: hasCredentials ? false : '未设置 S3_* 环境变量，跳过真实存储集成测试');

  test('流式文件上传/下载与 SHA-256 校验（真实存储）', () async {
    final storage = S3StorageService(
      config: config!,
      accessKey: accessKey!,
      secretKey: secretKey!,
    );
    final key =
        '${config.prefix}/streaming/${DateTime.now().microsecondsSinceEpoch}.bin';
    final tmpDir = await Directory.systemTemp.createTemp('aquamarina-stream-');
    final source = File('${tmpDir.path}/source.bin');
    final target = File('${tmpDir.path}/target.bin');
    final payload = Uint8List.fromList(
      List<int>.generate(256 * 1024, (i) => i % 251),
    );
    await source.writeAsBytes(payload, flush: true);
    try {
      final uploaded = await storage.putFile(key, source);
      expect(uploaded.size, payload.length);
      expect(uploaded.sha256, CloudSyncUtils.sha256Hex(payload));

      final downloaded = await storage.downloadToFile(key, target);
      expect(downloaded, isNotNull);
      expect(downloaded!.size, payload.length);
      expect(downloaded.sha256, uploaded.sha256);
      expect(await target.readAsBytes(), payload);
    } finally {
      try {
        await storage.delete(key);
      } catch (_) {}
      await tmpDir.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)), skip: hasCredentials ? false : '未设置 S3_* 环境变量，跳过真实存储集成测试');

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
  }, timeout: const Timeout(Duration(minutes: 2)), skip: hasCredentials ? false : '未设置 S3_* 环境变量，跳过真实存储集成测试');

  test('两台设备通过真实 S3 增量同步并收敛', () async {
    final e2eConfig = CloudSyncConfig.create(
      endpointInput: env['S3_ENDPOINT'] ?? 'cn-nb1.rains3.com',
      bucket: env['S3_BUCKET'] ?? 'aquamarina-test',
      region: env['S3_REGION'] ?? 'cn-nb1',
      prefix: '${config!.prefix}/e2e-${DateTime.now().millisecondsSinceEpoch}',
      pathStyle: config.pathStyle,
    );
    const deviceA = 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa';
    const deviceB = 'bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb';

    final storageA = S3StorageService(
      config: e2eConfig,
      accessKey: accessKey!,
      secretKey: secretKey!,
    );
    final storageB = S3StorageService(
      config: e2eConfig,
      accessKey: accessKey,
      secretKey: secretKey,
    );
    final dbA = await openSyncTestDb();
    final dbB = await openSyncTestDb();

    try {
      await dbA.insert('word_notes', {
        'word': 'apple',
        'note': 'from A',
        'is_favorited': 0,
        'updated_at': '2026-10-01T00:00:00Z',
      });
      final engineA = CloudSyncEngine.forTesting(
        config: e2eConfig,
        deviceId: deviceA,
        deviceName: '设备 A',
        storage: storageA,
        database: dbA,
      );
      final engineB = CloudSyncEngine.forTesting(
        config: e2eConfig,
        deviceId: deviceB,
        deviceName: '设备 B',
        storage: storageB,
        database: dbB,
      );

      var result = await engineA.run(pull: false);
      expect(result.pushedOps, greaterThanOrEqualTo(1));
      final metaA = CloudSyncDeviceMetaService(
        config: e2eConfig,
        storage: storageA,
      );
      final metaB = CloudSyncDeviceMetaService(
        config: e2eConfig,
        storage: storageB,
      );
      final headA = await metaA.fetchHead(deviceA);
      expect(headA, isNotNull);
      expect(headA!.latestChunkKey, contains('/chunks/'));

      result = await engineB.run(pull: true, push: false);
      expect(result.pulledOps, greaterThanOrEqualTo(1));
      expect((await dbB.query('word_notes')).single['note'], 'from A');
      final stateB = await metaB.fetchState(deviceB);
      expect(stateB?.appliedFor(deviceA), isNotNull);
      expect(await metaB.listDeviceIds(), containsAll([deviceA, deviceB]));

      // head 未变化时，下一次拉取应完全跳过该设备。
      result = await engineB.run(pull: true, push: false);
      expect(result.skippedByHead, greaterThanOrEqualTo(1));

      await dbB.update(
        'word_notes',
        {
          'note': 'from B',
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        where: 'word = ?',
        whereArgs: ['apple'],
      );
      result = await engineB.run(pull: false);
      expect(result.pushedOps, greaterThanOrEqualTo(1));

      result = await engineA.run(pull: true, push: false);
      expect(result.pulledOps, greaterThanOrEqualTo(1));
      expect((await dbA.query('word_notes')).single['note'], 'from B');
      final stateA = await metaA.fetchState(deviceA);
      expect(stateA?.appliedFor(deviceB), isNotNull);
    } finally {
      try {
        final objects = await storageA.list('${e2eConfig.prefix}/');
        await storageA.deleteMany(objects.map((e) => e.key));
      } catch (_) {}
      await dbA.close();
      await dbB.close();
    }
  }, timeout: const Timeout(Duration(minutes: 2)), skip: hasCredentials ? false : '未设置 S3_* 环境变量，跳过真实存储集成测试');
}
