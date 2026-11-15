import 'dart:convert';

import 'package:aquamarina/models/cloud_sync_manifest.dart';
import 'package:aquamarina/models/cloud_sync_share_payload.dart';
import 'package:aquamarina/services/cloud/cloud_sync_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  CloudSyncConfig buildConfig({
    String endpointInput = 'https://cn-nb1.rains3.com',
    String bucket = 'aquamarina-test',
    String region = 'cn-nb1',
    String prefix = 'aquamarina',
    bool pathStyle = true,
  }) {
    return CloudSyncConfig.create(
      endpointInput: endpointInput,
      bucket: bucket,
      region: region,
      prefix: prefix,
      pathStyle: pathStyle,
    );
  }

  group('CloudSyncSharePayload 编码往返', () {
    test('含密钥的载荷可完整还原', () {
      final payload = CloudSyncSharePayload.fromConfig(
        config: buildConfig(),
        credentials: const CloudSyncCredentials(
          accessKey: 'AKIAEXAMPLE1234',
          secretKey: 'c2VjcmV0LWV4YW1wbGUta2V5LXZhbHVl',
        ),
        deviceName: 'Windows-1a2b',
        now: DateTime.utc(2026, 11, 15, 12, 0, 0),
      );
      expect(payload.hasCredentials, isTrue);

      final decoded = CloudSyncSharePayload.decode(payload.encode());
      expect(decoded.endpoint, 'cn-nb1.rains3.com');
      expect(decoded.port, isNull);
      expect(decoded.useSsl, isTrue);
      expect(decoded.region, 'cn-nb1');
      expect(decoded.bucket, 'aquamarina-test');
      expect(decoded.prefix, 'aquamarina');
      expect(decoded.pathStyle, isTrue);
      expect(decoded.accessKey, 'AKIAEXAMPLE1234');
      expect(decoded.secretKey, 'c2VjcmV0LWV4YW1wbGUta2V5LXZhbHVl');
      expect(decoded.deviceName, 'Windows-1a2b');
    });

    test('不含密钥的载荷不会残留任何凭据', () {
      final payload = CloudSyncSharePayload.fromConfig(
        config: buildConfig(),
        credentials: null,
        deviceName: 'Android-9f8e',
      );
      expect(payload.hasCredentials, isFalse);
      expect(payload.accessKey, isNull);
      expect(payload.secretKey, isNull);

      final decoded = CloudSyncSharePayload.decode(payload.encode());
      expect(decoded.hasCredentials, isFalse);
      expect(decoded.toCredentials(), isNull);
    });

    test('支持 http 端点、显式端口与中文设备名', () {
      final payload = CloudSyncSharePayload.fromConfig(
        config: buildConfig(endpointInput: 'http://127.0.0.1:9000'),
        credentials: null,
        deviceName: '我的台式机',
      );
      final decoded = CloudSyncSharePayload.decode(payload.encode());
      expect(decoded.useSsl, isFalse);
      expect(decoded.port, 9000);
      expect(decoded.endpoint, '127.0.0.1');
      expect(decoded.deviceName, '我的台式机');

      final config = decoded.toConfig();
      expect(config.displayEndpoint, 'http://127.0.0.1:9000');
      expect(config.backendIdentity, payload.toConfig().backendIdentity);
    });

    test('含密钥载荷长度足够小，可放进二维码', () {
      final payload = CloudSyncSharePayload.fromConfig(
        config: buildConfig(endpointInput: 'https://cn-nb1.rains3.com'),
        credentials: const CloudSyncCredentials(
          accessKey: 'AKIAEXAMPLE1234567890',
          secretKey: 'c2VjcmV0LWV4YW1wbGUta2V5LXZhbHVlLXRoYXQtaXMtbG9uZw==',
        ),
        deviceName: 'Windows-1a2b',
      );
      expect(payload.encode().length, lessThan(600));
      expect(payload.encode().length, lessThan(CloudSyncSharePayload.maxPayloadChars));
    });

    test('encode 产出 aquamarina://cloud-sync/v1/ 前缀', () {
      final payload = CloudSyncSharePayload.fromConfig(
        config: buildConfig(),
        credentials: null,
      );
      expect(
        payload.encode(),
        startsWith('aquamarina://cloud-sync/v1/'),
      );
    });
  });

  group('CloudSyncSharePayload 校验', () {
    CloudSyncSharePayload bare() => CloudSyncSharePayload.fromConfig(
      config: buildConfig(),
      credentials: null,
    );

    String encodeJson(Map<String, dynamic> json) =>
        base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');

    Matcher throwsCloudSync([String? needle]) => throwsA(
      isA<CloudSyncException>().having(
        (e) => e.message,
        'message',
        needle == null ? anything : contains(needle),
      ),
    );

    test('拒绝空内容', () {
      expect(() => CloudSyncSharePayload.decode('   '), throwsCloudSync('为空'));
    });

    test('拒绝超长内容', () {
      final tooLong = List.filled(
        CloudSyncSharePayload.maxPayloadChars + 1,
        'a',
      ).join();
      expect(() => CloudSyncSharePayload.decode(tooLong), throwsCloudSync('过长'));
    });

    test('拒绝其它 scheme / host', () {
      expect(
        () => CloudSyncSharePayload.decode('https://example.com/v1/abc'),
        throwsCloudSync('不是 Aquamarina'),
      );
      expect(
        () => CloudSyncSharePayload.decode('aquamarina://other/v1/abc'),
        throwsCloudSync('不是 Aquamarina'),
      );
    });

    test('拒绝不支持的路径段', () {
      expect(
        () => CloudSyncSharePayload.decode('aquamarina://cloud-sync/v2/abc'),
        throwsCloudSync('不受支持'),
      );
    });

    test('拒绝损坏的 base64 与 JSON', () {
      expect(
        () => CloudSyncSharePayload.decode('aquamarina://cloud-sync/v1/***'),
        throwsCloudSync('已损坏'),
      );
      // 结构合法但不是本应用载荷：缺少版本字段。
      final notPayload = encodeJson({'hello': 'not-a-payload'});
      expect(
        () => CloudSyncSharePayload.decode('aquamarina://cloud-sync/v1/$notPayload'),
        throwsCloudSync('版本'),
      );
    });

    test('拒绝更新版本的载荷', () {
      final json = Map<String, dynamic>.from(bare().toJson())..['v'] = 2;
      final encoded = encodeJson(json);
      expect(
        () => CloudSyncSharePayload.decode('aquamarina://cloud-sync/v1/$encoded'),
        throwsCloudSync('升级'),
      );
    });

    test('拒绝只有一半的凭据', () {
      final json = Map<String, dynamic>.from(bare().toJson())..['ak'] = 'only-key';
      final encoded = encodeJson(json);
      expect(
        () => CloudSyncSharePayload.decode('aquamarina://cloud-sync/v1/$encoded'),
        throwsCloudSync('不完整'),
      );
    });

    test('拒绝非法桶名 / 区域 / 前缀', () {
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (json) => json['bk'] = 'Bad_Bucket',
        (json) => json['rg'] = 'us east 1',
        (json) => json['pf'] = '../etc',
        (json) => json['ep'] = 'https://example.com/path',
      ]) {
        final json = Map<String, dynamic>.from(bare().toJson());
        mutate(json);
        final encoded = encodeJson(json);
        expect(
          () => CloudSyncSharePayload.decode('aquamarina://cloud-sync/v1/$encoded'),
          throwsA(isA<CloudSyncException>()),
        );
      }
    });

    test('缺失字段时给出明确错误', () {
      final json = Map<String, dynamic>.from(bare().toJson())..remove('bk');
      final encoded = encodeJson(json);
      expect(
        () => CloudSyncSharePayload.decode('aquamarina://cloud-sync/v1/$encoded'),
        throwsCloudSync('不完整'),
      );
    });
  });

  group('CloudSyncSharePayload 展示摘要', () {
    test('摘要包含配置字段但不回显 Secret Key', () {
      final payload = CloudSyncSharePayload.fromConfig(
        config: buildConfig(),
        credentials: const CloudSyncCredentials(
          accessKey: 'AKIAEXAMPLE1234',
          secretKey: 'super-secret-value',
        ),
        deviceName: 'Windows-1a2b',
      );
      final summary = payload.maskedSummary;
      expect(summary, contains('cn-nb1.rains3.com'));
      expect(summary, contains('aquamarina-test'));
      expect(summary, contains('cn-nb1'));
      expect(summary, contains('Windows-1a2b'));
      expect(summary, contains('包含 Secret Key'));
      expect(summary, isNot(contains('super-secret-value')));
      expect(summary, isNot(contains('AKIAEXAMPLE1234')));
    });

    test('不含密钥时给出补填提示', () {
      final payload = CloudSyncSharePayload.fromConfig(
        config: buildConfig(),
        credentials: null,
      );
      expect(payload.maskedSummary, contains('不包含'));
    });
  });
}
