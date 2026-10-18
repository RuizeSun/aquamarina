import 'dart:convert';

import 'package:aquamarina/models/cloud_sync_manifest.dart';
import 'package:aquamarina/services/cloud_sync_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('S3Endpoint', () {
    test('解析完整 HTTPS 端点', () {
      final endpoint = S3Endpoint.parse('https://cn-nb1.rains3.com');
      expect(endpoint.host, 'cn-nb1.rains3.com');
      expect(endpoint.port, isNull);
      expect(endpoint.useSsl, isTrue);
      expect(endpoint.display, 'https://cn-nb1.rains3.com');
    });

    test('解析不带协议与带端口的端点', () {
      final endpoint = S3Endpoint.parse('minio.local:9000');
      expect(endpoint.host, 'minio.local');
      expect(endpoint.port, 9000);
      expect(endpoint.useSsl, isTrue);
      expect(endpoint.display, 'https://minio.local:9000');
    });

    test('允许显式 HTTP（仅调试用途）', () {
      final endpoint = S3Endpoint.parse('http://127.0.0.1:9000');
      expect(endpoint.useSsl, isFalse);
      expect(endpoint.host, '127.0.0.1');
      expect(endpoint.port, 9000);
    });

    test('拒绝空端点、非法协议、带路径、带查询串与用户信息', () {
      expect(() => S3Endpoint.parse(''), throwsA(isA<CloudSyncException>()));
      expect(
        () => S3Endpoint.parse('ftp://example.com'),
        throwsA(isA<CloudSyncException>()),
      );
      expect(
        () => S3Endpoint.parse('https://example.com/bucket'),
        throwsA(isA<CloudSyncException>()),
      );
      expect(
        () => S3Endpoint.parse('https://example.com?x=1'),
        throwsA(isA<CloudSyncException>()),
      );
      expect(
        () => S3Endpoint.parse('https://user:pass@example.com'),
        throwsA(isA<CloudSyncException>()),
      );
    });
  });

  group('CloudSyncConfig', () {
    test('创建配置并生成设备隔离对象键', () {
      final config = CloudSyncConfig.create(
        endpointInput: 'https://cn-nb1.rains3.com',
        bucket: 'aquamarina-test',
        region: 'cn-nb1',
      );
      expect(config.endpoint, 'cn-nb1.rains3.com');
      expect(config.useSsl, isTrue);
      expect(config.prefix, 'aquamarina');
      expect(config.retainCount, CloudSyncConfig.defaultRetainCount);
      expect(config.pathStyle, isTrue);
      expect(
        config.snapshotKey(
          'a1b2c3d4-e5f6-7890-abcd-ef1234567890',
          '20261017T130719123Z',
        ),
        'aquamarina/devices/a1b2c3d4-e5f6-7890-abcd-ef1234567890/'
        'snapshots/20261017T130719123Z.zip',
      );
      expect(
        config.manifestKey('a1b2c3d4-e5f6-7890-abcd-ef1234567890'),
        'aquamarina/devices/a1b2c3d4-e5f6-7890-abcd-ef1234567890/'
        'manifest.json',
      );
    });

    test('归一化路径前缀', () {
      expect(CloudSyncConfig.normalizePrefix('  /foo//bar/  '), 'foo/bar');
      expect(CloudSyncConfig.normalizePrefix('   '), 'aquamarina');
      expect(
        () => CloudSyncConfig.normalizePrefix('../etc'),
        throwsA(isA<CloudSyncException>()),
      );
      expect(
        () => CloudSyncConfig.normalizePrefix('foo bar'),
        throwsA(isA<CloudSyncException>()),
      );
    });

    test('校验存储桶与区域', () {
      expect(CloudSyncConfig.isValidBucketName('aquamarina-test'), isTrue);
      expect(CloudSyncConfig.isValidBucketName('ab'), isFalse);
      expect(CloudSyncConfig.isValidBucketName('Aquamarina'), isFalse);
      expect(CloudSyncConfig.isValidBucketName('bucket_name'), isFalse);
      expect(CloudSyncConfig.isValidBucketName('192.168.1.1'), isFalse);

      expect(
        () => CloudSyncConfig.create(
          endpointInput: 'https://example.com',
          bucket: 'Bad_Bucket',
          region: 'us-east-1',
        ),
        throwsA(isA<CloudSyncException>()),
      );
      expect(
        () => CloudSyncConfig.create(
          endpointInput: 'https://example.com',
          bucket: 'valid-bucket',
          region: 'us east 1',
        ),
        throwsA(isA<CloudSyncException>()),
      );
      expect(
        () => CloudSyncConfig.create(
          endpointInput: 'https://example.com',
          bucket: 'valid-bucket',
          region: 'us-east-1',
          retainCount: 0,
        ),
        throwsA(isA<CloudSyncException>()),
      );
    });

    test('JSON 往返', () {
      final config = CloudSyncConfig.create(
        endpointInput: 'http://localhost:9000',
        bucket: 'test-bucket',
        region: 'us-east-1',
        prefix: 'app/data',
        pathStyle: false,
        retainCount: 10,
      );
      final restored = CloudSyncConfig.fromJson(
        jsonDecode(jsonEncode(config.toJson())) as Map<String, dynamic>,
      );
      expect(restored.endpoint, 'localhost');
      expect(restored.port, 9000);
      expect(restored.useSsl, isFalse);
      expect(restored.bucket, 'test-bucket');
      expect(restored.prefix, 'app/data');
      expect(restored.pathStyle, isFalse);
      expect(restored.retainCount, 10);
      expect(restored.autoSync, isTrue);
    });

    test('auto_sync 缺省为 true，显式关闭可持久化', () {
      final open = CloudSyncConfig.create(
        endpointInput: 'https://example.com',
        bucket: 'valid-bucket',
        region: 'us-east-1',
        autoSync: false,
      );
      final fromJson = CloudSyncConfig.fromJson(open.toJson());
      expect(fromJson.autoSync, isFalse);

      final legacy = open.toJson()..remove('auto_sync');
      expect(CloudSyncConfig.fromJson(legacy).autoSync, isTrue);
    });

    test('自动同步间隔持久化、旧配置兼容与范围校验', () {
      final config = CloudSyncConfig.create(
        endpointInput: 'https://example.com',
        bucket: 'valid-bucket',
        region: 'us-east-1',
        autoSyncIntervalMinutes: 15,
      );
      expect(config.autoSyncIntervalMinutes, 15);
      final restored = CloudSyncConfig.fromJson(
        jsonDecode(jsonEncode(config.toJson())) as Map<String, dynamic>,
      );
      expect(restored.autoSyncIntervalMinutes, 15);

      final legacy = config.toJson()..remove('auto_sync_interval_minutes');
      expect(CloudSyncConfig.fromJson(legacy).autoSyncIntervalMinutes, 5);

      expect(
        () => CloudSyncConfig.create(
          endpointInput: 'https://example.com',
          bucket: 'valid-bucket',
          region: 'us-east-1',
          autoSyncIntervalMinutes: 0,
        ),
        throwsA(isA<CloudSyncException>()),
      );
    });
  });

  group('CloudSyncSettings.isCompleteConfiguration', () {
    test('只有配置与凭据同时完整时才视为已配置', () {
      final config = CloudSyncConfig.create(
        endpointInput: 'https://example.com',
        bucket: 'valid-bucket',
        region: 'us-east-1',
      );
      const complete = CloudSyncCredentials(
        accessKey: 'access',
        secretKey: 'secret',
      );
      const missingSecret = CloudSyncCredentials(
        accessKey: 'access',
        secretKey: '   ',
      );

      expect(
        CloudSyncSettings.isCompleteConfiguration(null, complete),
        isFalse,
      );
      expect(CloudSyncSettings.isCompleteConfiguration(config, null), isFalse);
      expect(
        CloudSyncSettings.isCompleteConfiguration(config, missingSecret),
        isFalse,
      );
      expect(
        CloudSyncSettings.isCompleteConfiguration(config, complete),
        isTrue,
      );
    });
  });

  group('CloudSyncUtils', () {
    test('SHA-256 与已知向量一致', () {
      expect(
        CloudSyncUtils.sha256Hex(utf8.encode('abc')),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });

    test('UTC 时间戳格式可安全用于对象键', () {
      final stamp = CloudSyncUtils.utcTimestamp(
        DateTime.utc(2026, 10, 17, 13, 7, 19, 123),
      );
      expect(stamp, '20261017T130719123Z');
      expect(RegExp(r'^[0-9TZ]+$').hasMatch(stamp), isTrue);
    });

    test('文件大小格式化', () {
      expect(CloudSyncUtils.formatBytes(0), '0 B');
      expect(CloudSyncUtils.formatBytes(1023), '1023 B');
      expect(CloudSyncUtils.formatBytes(1024), '1.0 KB');
      expect(CloudSyncUtils.formatBytes(1024 * 1024), '1.0 MB');
    });
  });

  group('CloudSyncSettings.resetDeviceId', () {
    test('重置后把旧设备 ID 记入忽略列表，避免本机重放旧 chunk', () async {
      const oldId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
      SharedPreferences.setMockInitialValues({
        'cloud_sync_device_id_v1': oldId,
      });

      final newId = await CloudSyncSettings.resetDeviceId();
      expect(newId, isNot(oldId));
      expect(await CloudSyncSettings.loadIgnoredDeviceIds(), contains(oldId));
      expect(await CloudSyncSettings.getOrCreateDeviceId(), newId);
    });
  });
}
