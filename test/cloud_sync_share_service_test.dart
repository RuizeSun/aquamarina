import 'package:aquamarina/models/cloud_sync_share_payload.dart';
import 'package:aquamarina/services/cloud/cloud_sync_share_service.dart';
import 'package:aquamarina/services/cloud/cloud_sync_settings.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 用纯 Dart 把载荷渲染成一张 PNG，模拟「手机截屏 / 分享图片」。
///
/// 不依赖 Flutter 渲染管线与相机插件，因此可以在 CI 里稳定复现
/// 「图片 → 二维码 → 配置」的完整链路。
Uint8List renderQrPng(String data, {int scale = 8, int quietModules = 4}) {
  final code = QrCode.fromData(
    data: data,
    errorCorrectLevel: QrErrorCorrectLevel.M,
  );
  final image = QrImage(code);
  final modules = image.moduleCount;
  final size = (modules + quietModules * 2) * scale;
  final canvas = img.Image(width: size, height: size);
  img.fill(canvas, color: img.ColorRgb8(255, 255, 255));
  for (var y = 0; y < modules; y++) {
    for (var x = 0; x < modules; x++) {
      if (!image.isDark(y, x)) continue;
      img.fillRect(
        canvas,
        x1: (x + quietModules) * scale,
        y1: (y + quietModules) * scale,
        x2: (x + quietModules + 1) * scale - 1,
        y2: (y + quietModules + 1) * scale - 1,
        color: img.ColorRgb8(0, 0, 0),
      );
    }
  }
  return Uint8List.fromList(img.encodePng(canvas));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  final secureValues = <String, String>{};

  setUp(() {
    secureValues.clear();
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (call) async {
          final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
          final key = args['key'] as String?;
          switch (call.method) {
            case 'write':
              if (key != null) {
                final value = args['value'];
                if (value is String) {
                  secureValues[key] = value;
                } else {
                  secureValues.remove(key);
                }
              }
              return null;
            case 'read':
              return key == null ? null : secureValues[key];
            case 'delete':
              if (key != null) secureValues.remove(key);
              return null;
            case 'readAll':
              return Map<String, String>.from(secureValues);
            case 'deleteAll':
              secureValues.clear();
              return null;
            case 'containsKey':
              return key != null && secureValues.containsKey(key);
            default:
              return null;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
  });

  CloudSyncConfig buildConfig({String bucket = 'aquamarina-test'}) {
    return CloudSyncConfig.create(
      endpointInput: 'https://cn-nb1.rains3.com',
      bucket: bucket,
      region: 'cn-nb1',
    );
  }

  group('图片解码', () {
    test('二维码 PNG 可以被纯 Dart 解码回文本', () {
      final payload = CloudSyncSharePayload.fromConfig(
        config: buildConfig(),
        credentials: const CloudSyncCredentials(
          accessKey: 'AKIAEXAMPLE1234',
          secretKey: 'secret-value-for-qr',
        ),
        deviceName: 'Windows-1a2b',
      );
      final png = renderQrPng(payload.encode());
      final text = CloudSyncShareService.decodeImageBytes(png);
      expect(text, payload.encode());

      final parsed = CloudSyncShareService.parseImageBytes(png);
      expect(parsed, isNotNull);
      expect(parsed!.bucket, 'aquamarina-test');
      expect(parsed.accessKey, 'AKIAEXAMPLE1234');
      expect(parsed.secretKey, 'secret-value-for-qr');
    });

    test('纯色图片返回 null 而不是抛异常', () {
      final blank = img.Image(width: 64, height: 64);
      img.fill(blank, color: img.ColorRgb8(255, 255, 255));
      final bytes = Uint8List.fromList(img.encodePng(blank));
      expect(CloudSyncShareService.decodeImageBytes(bytes), isNull);
    });

    test('非图片字节返回 null', () {
      expect(
        CloudSyncShareService.decodeImageBytes(Uint8List.fromList([1, 2, 3, 4])),
        isNull,
      );
    });

    test('超过大小上限直接拒绝', () {
      final huge = Uint8List(CloudSyncShareService.maxImageBytes + 1);
      expect(CloudSyncShareService.decodeImageBytes(huge), isNull);
    });
  });

  group('tryDecodeText', () {
    test('非本应用文本返回 null', () {
      expect(CloudSyncShareService.tryDecodeText(null), isNull);
      expect(CloudSyncShareService.tryDecodeText('   '), isNull);
      expect(CloudSyncShareService.tryDecodeText('https://example.com'), isNull);
      expect(CloudSyncShareService.tryDecodeText('随便一段文字'), isNull);
    });

    test('合法载荷可解析', () {
      final payload = CloudSyncSharePayload.fromConfig(
        config: buildConfig(),
        credentials: null,
      );
      final parsed = CloudSyncShareService.tryDecodeText(payload.encode());
      expect(parsed, isNotNull);
      expect(parsed!.hasCredentials, isFalse);
    });
  });

  group('applyPayload', () {
    test('含密钥的载荷会覆盖配置与凭据', () async {
      final payload = CloudSyncSharePayload.fromConfig(
        config: buildConfig(),
        credentials: const CloudSyncCredentials(
          accessKey: 'AKIA-NEW',
          secretKey: 'SECRET-NEW',
        ),
        deviceName: 'macOS-abcd',
      );
      final result = await CloudSyncShareService.applyPayload(payload);

      expect(result.backendChanged, isTrue);
      expect(result.isReady, isTrue);
      expect(result.credentialsCleared, isFalse);

      final saved = await CloudSyncSettings.loadConfig();
      expect(saved?.bucket, 'aquamarina-test');
      expect(saved?.endpoint, 'cn-nb1.rains3.com');

      final credentials = await CloudSyncSettings.loadCredentials();
      expect(credentials?.accessKey, 'AKIA-NEW');
      expect(credentials?.secretKey, 'SECRET-NEW');

      final deviceId = await CloudSyncSettings.getOrCreateDeviceId();
      expect(
        await CloudSyncSettings.getOrCreateDeviceName(deviceId),
        'macOS-abcd',
      );
    });

    test('不含密钥但后端未变化时保留原有凭据', () async {
      await CloudSyncSettings.saveConfig(buildConfig());
      await CloudSyncSettings.saveCredentials(
        const CloudSyncCredentials(
          accessKey: 'AKIA-OLD',
          secretKey: 'SECRET-OLD',
        ),
      );

      final payload = CloudSyncSharePayload.fromConfig(
        config: buildConfig(),
        credentials: null,
      );
      final result = await CloudSyncShareService.applyPayload(payload);

      expect(result.backendChanged, isFalse);
      expect(result.credentialsCleared, isFalse);
      expect(result.isReady, isTrue);

      final credentials = await CloudSyncSettings.loadCredentials();
      expect(credentials?.accessKey, 'AKIA-OLD');
      expect(credentials?.secretKey, 'SECRET-OLD');
    });

    test('不含密钥且后端变化时清除旧凭据，避免把旧密钥发给新后端', () async {
      await CloudSyncSettings.saveConfig(buildConfig());
      await CloudSyncSettings.saveCredentials(
        const CloudSyncCredentials(
          accessKey: 'AKIA-OLD',
          secretKey: 'SECRET-OLD',
        ),
      );

      final payload = CloudSyncSharePayload.fromConfig(
        config: buildConfig(bucket: 'another-bucket'),
        credentials: null,
      );
      final result = await CloudSyncShareService.applyPayload(payload);

      expect(result.backendChanged, isTrue);
      expect(result.credentialsCleared, isTrue);
      expect(result.isReady, isFalse);
      expect(await CloudSyncSettings.loadCredentials(), isNull);
      expect(
        (await CloudSyncSettings.loadConfig())?.bucket,
        'another-bucket',
      );
    });

    test('重复导入同一份载荷是幂等的', () async {
      final payload = CloudSyncSharePayload.fromConfig(
        config: buildConfig(),
        credentials: const CloudSyncCredentials(
          accessKey: 'AKIA-NEW',
          secretKey: 'SECRET-NEW',
        ),
      );
      await CloudSyncShareService.applyPayload(payload);
      final second = await CloudSyncShareService.applyPayload(payload);
      expect(second.backendChanged, isFalse);
      expect(second.isReady, isTrue);
    });
  });

  group('loadCurrent', () {
    test('未配置时返回 null', () async {
      expect(await CloudSyncShareService.loadCurrent(), isNull);
    });

    test('已配置时按开关决定是否包含密钥', () async {
      await CloudSyncSettings.saveConfig(buildConfig());
      await CloudSyncSettings.saveCredentials(
        const CloudSyncCredentials(
          accessKey: 'AKIA-1',
          secretKey: 'SECRET-1',
        ),
      );

      final withSecrets = await CloudSyncShareService.loadCurrent();
      expect(withSecrets, isNotNull);
      expect(withSecrets!.hasCredentials, isTrue);
      expect(withSecrets.bucket, 'aquamarina-test');

      final without = await CloudSyncShareService.loadCurrent(
        includeCredentials: false,
      );
      expect(without, isNotNull);
      expect(without!.hasCredentials, isFalse);
      expect(without.encode(), isNot(contains('SECRET-1')));
    });
  });
}
