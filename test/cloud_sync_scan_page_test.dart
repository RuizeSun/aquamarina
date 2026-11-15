import 'dart:io';

import 'package:aquamarina/models/cloud_sync_share_payload.dart';
import 'package:aquamarina/pages/settings/cloud_sync_scan_page.dart';
import 'package:aquamarina/services/cloud/cloud_sync_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 扫码页在桌面端只暴露「图片 / 剪贴板 / 粘贴文本」三种入口，
/// 本测试验证文本粘贴路径能正确解析并弹出导入确认。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  final secureValues = <String, String>{};
  String? clipboardText;

  setUp(() {
    secureValues.clear();
    clipboardText = null;
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
            default:
              return null;
          }
        });
    // Clipboard.getData 走 SystemChannels.platform。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.getData') {
            return clipboardText == null
                ? null
                : <String, dynamic>{'text': clipboardText};
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: CloudSyncQrScanPage()),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('桌面端不启动相机，展示图片与剪贴板入口', (tester) async {
    await pumpPage(tester);
    expect(find.text('从图片文件导入'), findsOneWidget);
    expect(find.text('从剪贴板导入图片'), findsOneWidget);
    expect(find.text('粘贴分享文本'), findsOneWidget);
    if (!Platform.isAndroid && !Platform.isIOS && !Platform.isMacOS) {
      expect(find.textContaining('没有可用的相机扫码能力'), findsOneWidget);
    }
  });

  testWidgets('粘贴合法文本会弹出导入确认并展示配置摘要', (tester) async {
    final payload = CloudSyncSharePayload.fromConfig(
      config: CloudSyncConfig.create(
        endpointInput: 'https://cn-nb1.rains3.com',
        bucket: 'aquamarina-test',
        region: 'cn-nb1',
      ),
      credentials: const CloudSyncCredentials(
        accessKey: 'AKIAEXAMPLE1234',
        secretKey: 'super-secret-value',
      ),
      deviceName: 'Windows-1a2b',
    );
    clipboardText = payload.encode();
    await pumpPage(tester);

    await tester.tap(find.text('粘贴分享文本'));
    await tester.pumpAndSettle();

    expect(find.text('导入云同步配置'), findsOneWidget);
    expect(find.textContaining('cn-nb1.rains3.com'), findsOneWidget);
    expect(find.textContaining('aquamarina-test'), findsOneWidget);
    expect(find.textContaining('Windows-1a2b'), findsOneWidget);
    // 预览里不能出现 Secret Key 明文。
    expect(find.textContaining('super-secret-value'), findsNothing);
  });

  testWidgets('粘贴无关文本给出中文提示且不打开确认框', (tester) async {
    clipboardText = 'https://example.com/not-a-payload';
    await pumpPage(tester);

    await tester.tap(find.text('粘贴分享文本'));
    await tester.pumpAndSettle();

    expect(find.text('导入云同步配置'), findsNothing);
    expect(find.text('这不是 Aquamarina 的云同步二维码'), findsOneWidget);
  });
}
