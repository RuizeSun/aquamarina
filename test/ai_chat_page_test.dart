import 'package:aquamarina/models/ai_chat.dart';
import 'package:aquamarina/models/ai_profile.dart';
import 'package:aquamarina/pages/ai_chat_page.dart';
import 'package:aquamarina/services/ai/ai_chat_controller.dart';
import 'package:aquamarina/services/ai/ai_chat_service.dart';
import 'package:aquamarina/services/ai/ai_profile_service.dart';
import 'package:aquamarina/services/data/database_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 避免测试环境访问安全存储与网络。
class _FakeProfileService extends AiProfileService {
  _FakeProfileService(this.profile);

  final AiProfile? profile;

  @override
  Future<void> load({bool force = false}) async {}

  @override
  AiProfile? get defaultProfile => profile;

  @override
  AiProfile? getProfile(String id) => profile;

  @override
  List<AiProfile> get profiles => profile == null ? const [] : [profile!];
}

AiProfile _profile() => const AiProfile(
  id: 'p1',
  name: '测试配置',
  type: AiProfileType.openai,
  apiKey: 'sk-test',
  model: 'gpt-4o-mini',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;
  late AiChatService service;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        singleInstance: false,
        onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
      ),
    );
    await DatabaseService.ensureChatTables(db);
    service = AiChatService.withDatabase(() async => db);
  });

  tearDown(() async {
    await db.close();
  });

  /// sqflite ffi 的真实 I/O 需要跑在 runAsync 里，否则 fake-async 区域会一直挂起。
  Future<void> pumpPage(
    WidgetTester tester,
    AiChatController controller,
  ) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: AiChatPage(
            controller: controller,
            chatService: service,
            profileService: _FakeProfileService(_profile()),
          ),
        ),
      );
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pump();
  }

  testWidgets('宽屏展示会话侧栏与空态引导', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = AiChatController(chatService: service);
    addTearDown(controller.dispose);

    await pumpPage(tester, controller);

    expect(find.text('会话'), findsOneWidget);
    expect(find.text('开始一段新对话'), findsOneWidget);
    expect(find.byIcon(Icons.list_alt), findsNothing);
  });

  testWidgets('已有消息时渲染两侧气泡', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = AiChatController(chatService: service);
    addTearDown(controller.dispose);

    await tester.runAsync(() async {
      final session = await service.createSession(title: '测试会话');
      await service.appendMessage(
        AiChatMessage.create(
          sessionId: session.id,
          role: AiChatRole.user,
          content: '你好呀',
        ),
      );
      await service.appendMessage(
        AiChatMessage.create(
          sessionId: session.id,
          role: AiChatRole.assistant,
          content: '你好！有什么可以帮你？',
        ),
      );
    });

    await pumpPage(tester, controller);

    expect(find.text('你好呀'), findsOneWidget);
    expect(find.textContaining('有什么可以帮你'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('一次问答只渲染一个 AI 气泡，工具结果收进思考过程', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = AiChatController(chatService: service);
    addTearDown(controller.dispose);

    await tester.runAsync(() async {
      final session = await service.createSession(title: '工具会话');
      await service.appendMessage(
        AiChatMessage.create(
          sessionId: session.id,
          role: AiChatRole.user,
          content: '查一下 ephemeral',
        ),
      );
      await service.appendMessage(
        AiChatMessage.create(
          sessionId: session.id,
          role: AiChatRole.assistant,
          reasoning: '先查词典',
          content: '',
          toolCalls: [
            AiToolCall.parse(
              id: 'c1',
              name: 'search_dictionary',
              rawArguments: '{"word":"ephemeral"}',
            ),
          ],
        ),
      );
      await service.appendMessage(
        AiChatMessage.create(
          sessionId: session.id,
          role: AiChatRole.tool,
          content: '【英文词条】ephemeral /ɪˈfemərəl/',
          toolCallId: 'c1',
          toolName: 'search_dictionary',
        ),
      );
      await service.appendMessage(
        AiChatMessage.create(
          sessionId: session.id,
          role: AiChatRole.assistant,
          content: 'ephemeral 意为短暂的。',
        ),
      );
    });

    await pumpPage(tester, controller);

    // 正式回答直接可见
    expect(find.textContaining('意为短暂的'), findsWidgets);
    // 折叠行本地化，不暴露协议里的工具名
    expect(find.textContaining('思考过程 · 查词典'), findsOneWidget);
    expect(find.textContaining('search_dictionary'), findsNothing);
    expect(tester.takeException(), isNull);

    // 展开后工具卡片与参数可见，工具结果不再单独占一行灰条
    await tester.tap(find.textContaining('思考过程 · 查词典'));
    await tester.pumpAndSettle();
    expect(find.text('查词典'), findsWidgets);
    expect(find.textContaining('工具 search_dictionary：'), findsNothing);
  });

  testWidgets('窄屏隐藏侧栏并使用抽屉入口', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = AiChatController(chatService: service);
    addTearDown(controller.dispose);

    await pumpPage(tester, controller);

    expect(find.text('会话'), findsNothing);
    expect(find.byIcon(Icons.list_alt), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
