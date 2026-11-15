import 'package:aquamarina/models/cloud_sync_share_payload.dart';
import 'package:aquamarina/pages/settings/cloud_sync_share_page.dart';
import 'package:aquamarina/services/cloud/cloud_sync_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
            default:
              return null;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
  });

  Future<void> seedConfig({bool withCredentials = true}) async {
    final config = CloudSyncConfig.create(
      endpointInput: 'https://cn-nb1.rains3.com',
      bucket: 'aquamarina-test',
      region: 'cn-nb1',
    );
    await CloudSyncSettings.saveConfig(config);
    if (withCredentials) {
      await CloudSyncSettings.saveCredentials(
        const CloudSyncCredentials(
          accessKey: 'AKIAEXAMPLE1234',
          secretKey: 'super-secret-value',
        ),
      );
    }
  }

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: CloudSyncQrSharePage()),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('未配置时提示先完成配置且不渲染二维码', (tester) async {
    await pumpPage(tester);
    expect(find.text('请先完成对象存储配置'), findsOneWidget);
    expect(find.byType(CloudSyncQrCode), findsNothing);
  });

  testWidgets('已配置时渲染二维码，默认包含密钥且不回显 Secret', (tester) async {
    await seedConfig();
    await pumpPage(tester);

    expect(find.text('二维码分享'), findsOneWidget);
    final qr = tester.widget<CloudSyncQrCode>(find.byType(CloudSyncQrCode));

    final payload = CloudSyncSharePayload.decode(qr.data);
    expect(payload.hasCredentials, isTrue);
    expect(payload.bucket, 'aquamarina-test');

    // 页面文案与二维码内容都不应出现 Secret Key 明文。
    expect(find.textContaining('super-secret-value'), findsNothing);
    expect(qr.data, isNot(contains('super-secret-value')));
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
  });

  testWidgets('关闭包含密钥后二维码不再携带凭据', (tester) async {
    await seedConfig();
    await pumpPage(tester);

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    final qr = tester.widget<CloudSyncQrCode>(find.byType(CloudSyncQrCode));
    final payload = CloudSyncSharePayload.decode(qr.data);
    expect(payload.hasCredentials, isFalse);
    expect(payload.accessKey, isNull);
    expect(payload.secretKey, isNull);
    expect(qr.data, isNot(contains('AKIAEXAMPLE1234')));
  });

  testWidgets('缺少凭据时二维码仍可生成（不含密钥）', (tester) async {
    await seedConfig(withCredentials: false);
    await pumpPage(tester);

    final qr = tester.widget<CloudSyncQrCode>(find.byType(CloudSyncQrCode));
    final payload = CloudSyncSharePayload.decode(qr.data);
    expect(payload.hasCredentials, isFalse);
    expect(find.textContaining('请补填'), findsNothing);
  });
}
