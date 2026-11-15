import 'package:aquamarina/models/ai_chat.dart';
import 'package:aquamarina/services/ai/ai_chat_service.dart';
import 'package:aquamarina/services/data/database_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;
  late AiChatService service;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        singleInstance: false,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      ),
    );
    await DatabaseService.ensureChatTables(db);
    service = AiChatService.withDatabase(() async => db);
  });

  tearDown(() async {
    await db.close();
  });

  group('会话管理', () {
    test('创建会话后可读到，且默认标题为「新对话」', () async {
      final session = await service.createSession();
      final sessions = await service.listSessions();
      expect(sessions, hasLength(1));
      expect(sessions.first.id, session.id);
      expect(sessions.first.title, AiChatSession.defaultTitle);
    });

    test('重命名会截断到 24 字并更新 updated_at', () async {
      final session = await service.createSession();
      await service.renameSession(session.id, 'A' * 40);
      final reloaded = await service.getSession(session.id);
      expect(reloaded!.title.length, AiChatService.titleMaxChars);
    });

    test('会话列表按 updated_at 倒序', () async {
      final first = await service.createSession(title: '第一');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final second = await service.createSession(title: '第二');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await service.renameSession(first.id, '第一（更新）');

      final sessions = await service.listSessions();
      expect(sessions.first.id, first.id);
      expect(sessions.last.id, second.id);
    });

    test('删除会话会级联删除其消息', () async {
      final session = await service.createSession();
      await service.appendMessage(
        AiChatMessage.create(
          sessionId: session.id,
          role: AiChatRole.user,
          content: '你好',
        ),
      );
      expect(await service.countMessages(), 1);

      await service.deleteSession(session.id);
      expect(await service.countSessions(), 0);
      expect(await service.countMessages(), 0);
    });
  });

  group('消息管理', () {
    test('appendMessage 递增 sort_index 并保持顺序', () async {
      final session = await service.createSession();
      for (var i = 0; i < 3; i++) {
        await service.appendMessage(
          AiChatMessage.create(
            sessionId: session.id,
            role: AiChatRole.user,
            content: '第 $i 条',
          ),
        );
      }
      final messages = await service.loadMessages(session.id);
      expect(messages.map((m) => m.content), ['第 0 条', '第 1 条', '第 2 条']);
      expect(messages[2].sortIndex, greaterThan(messages[0].sortIndex));
    });

    test('工具调用与思维链可完整往返', () async {
      final session = await service.createSession();
      final call = AiToolCall.parse(
        id: 'call_1',
        name: 'search_dictionary',
        rawArguments: '{"word":"apple"}',
      );
      await service.appendMessage(
        AiChatMessage.create(
          sessionId: session.id,
          role: AiChatRole.assistant,
          content: '我查一下',
          reasoning: '先查词典',
          toolCalls: [call],
        ),
      );

      final loaded = (await service.loadMessages(session.id)).single;
      expect(loaded.reasoning, '先查词典');
      expect(loaded.toolCalls.single.name, 'search_dictionary');
      expect(loaded.toolCalls.single.arguments['word'], 'apple');
    });

    test('清空会话只删消息，保留会话本身', () async {
      final session = await service.createSession();
      await service.appendMessage(
        AiChatMessage.create(
          sessionId: session.id,
          role: AiChatRole.user,
          content: 'hi',
        ),
      );
      await service.clearSessionMessages(session.id);
      expect(await service.countMessages(), 0);
      expect(await service.getSession(session.id), isNotNull);
    });

    test('clearAll 清空所有会话与消息', () async {
      final a = await service.createSession();
      final b = await service.createSession();
      await service.appendMessage(
        AiChatMessage.create(sessionId: a.id, role: AiChatRole.user, content: 'a'),
      );
      await service.appendMessage(
        AiChatMessage.create(sessionId: b.id, role: AiChatRole.user, content: 'b'),
      );

      await service.clearAll();
      expect(await service.countSessions(), 0);
      expect(await service.countMessages(), 0);
    });

    test('超长内容入库时按 32KB 截断', () async {
      final session = await service.createSession();
      final longText = 'x' * (AiChatMessage.maxStoredChars + 100);
      await service.appendMessage(
        AiChatMessage.create(
          sessionId: session.id,
          role: AiChatRole.assistant,
          content: longText,
        ),
      );
      final loaded = (await service.loadMessages(session.id)).single;
      expect(loaded.content.length, lessThanOrEqualTo(AiChatMessage.maxStoredChars));
      expect(loaded.content.endsWith('已截断）'), isTrue);
    });
  });

  group('title 生成', () {
    test('折叠空白并只取前 24 字', () {
      expect(AiChatService.suggestTitle('  你好\n\n  世界 '), '你好 世界');
      expect(AiChatService.suggestTitle('a' * 100).length, AiChatService.titleMaxChars);
      expect(AiChatService.suggestTitle('   '), AiChatSession.defaultTitle);
    });
  });
}
