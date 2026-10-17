import 'package:aquamarina/pages/settings/cloud_sync_config_page.dart';
import 'package:aquamarina/pages/settings/sections/cloud_sync_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (call) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
  });

  testWidgets('未配置时展示引导入口并可进入配置页', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: CloudSyncSection())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('云同步'), findsOneWidget);
    expect(find.text('对象存储配置'), findsOneWidget);
    expect(find.text('尚未完成配置'), findsOneWidget);
    expect(find.text('立即上传备份'), findsOneWidget);
    expect(find.text('从云端恢复'), findsOneWidget);

    await tester.tap(find.text('对象存储配置'));
    await tester.pumpAndSettle();

    expect(find.text('访问端点'), findsOneWidget);
    expect(find.text('存储桶'), findsOneWidget);
    expect(find.text('区域'), findsOneWidget);
    expect(find.text('路径前缀'), findsOneWidget);

    final listView = find.descendant(
      of: find.byType(CloudSyncConfigPage),
      matching: find.byType(ListView),
    );
    await tester.drag(listView, const Offset(0, -700));
    await tester.pumpAndSettle();
    expect(find.text('Access Key'), findsOneWidget);
    expect(find.text('Secret Key'), findsOneWidget);

    await tester.drag(listView, const Offset(0, -900));
    await tester.pumpAndSettle();
    expect(find.text('测试连接'), findsOneWidget);
    expect(find.text('保存配置'), findsOneWidget);
  });
}
