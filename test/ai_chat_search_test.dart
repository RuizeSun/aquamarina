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
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await DatabaseService.ensureChatTables(db);
    service = AiChatService.withDatabase(() async => db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<AiChatSession> seedSession(
    String title,
    List<String> messages,
  ) async {
    final session = await service.createSession(title: title);
    for (final text in messages) {
      await service.appendMessage(
        AiChatMessage.create(
          sessionId: session.id,
          role: AiChatRole.user,
          content: text,
        ),
      );
    }
    return session;
  }

  group('searchSessions', () {
    test('空关键词不返回结果', () async {
      await seedSession('英语学习', ['今天背了 20 个单词']);
      expect(await service.searchSessions('   '), isEmpty);
    });

    test('按标题命中，且没有片段', () async {
      final session = await seedSession('旅行英语', ['机场问路怎么说']);
      final hits = await service.searchSessions('旅行');
      expect(hits, hasLength(1));
      expect(hits.single.session.id, session.id);
      expect(hits.single.matchedTitle, isTrue);
      expect(hits.single.snippet, isNull);
    });

    test('按正文命中并返回关键词附近片段', () async {
      final session = await seedSession('杂谈', [
        '这是一段很长的开场白，用来占位。中间提到了虚拟语气，后面还有很多别的内容。',
      ]);
      final hits = await service.searchSessions('虚拟语气');
      expect(hits, hasLength(1));
      expect(hits.single.session.id, session.id);
      expect(hits.single.matchedTitle, isFalse);
      expect(hits.single.snippet, contains('虚拟语气'));
    });

    test('标题与正文同时命中时只返回一条', () async {
      await seedSession('虚拟语气专题', ['虚拟语气的三种用法']);
      final hits = await service.searchSessions('虚拟语气');
      expect(hits, hasLength(1));
      expect(hits.single.matchedTitle, isTrue);
      expect(hits.single.snippet, isNotNull);
    });

    test('百分号按字面匹配，不当通配符', () async {
      await seedSession('正确率', ['这次正确率 100%，很棒']);
      expect(await service.searchSessions('50%'), isEmpty);
      final hits = await service.searchSessions('100%');
      expect(hits, hasLength(1));
    });

    test('结果按会话最近更新时间倒序', () async {
      await seedSession('旧的', ['keyword 在这里']);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await seedSession('新的', ['keyword 也在这里']);
      final hits = await service.searchSessions('keyword');
      expect(hits, hasLength(2));
      expect(hits.first.session.title, '新的');
    });

    test('没有命中时返回空列表', () async {
      await seedSession('英语学习', ['今天背了 20 个单词']);
      expect(await service.searchSessions('物理化学'), isEmpty);
    });
  });

  group('buildSearchSnippet', () {
    test('折叠空白并在两侧加省略号', () {
      final text = '${'前'.padLeft(80, '甲')}关键词${'后'.padLeft(80, '乙')}';
      final snippet = AiChatService.buildSearchSnippet(text, '关键词');
      expect(snippet, startsWith('…'));
      expect(snippet, endsWith('…'));
      expect(snippet, contains('关键词'));
    });

    test('短文本不加省略号', () {
      expect(AiChatService.buildSearchSnippet('查到 关键词 了', '关键词'), '查到 关键词 了');
    });

    test('未命中时取开头截断', () {
      final snippet = AiChatService.buildSearchSnippet('甲' * 200, '不存在');
      expect(snippet, endsWith('…'));
      expect(snippet.length, lessThan(200));
    });
  });
}
