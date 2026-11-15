import 'dart:async';

import 'package:aquamarina/models/ai_chat.dart';
import 'package:aquamarina/models/ai_profile.dart';
import 'package:aquamarina/services/ai/ai_chat_controller.dart';
import 'package:aquamarina/services/ai/ai_chat_service.dart';
import 'package:aquamarina/services/ai/ai_chat_settings.dart';
import 'package:aquamarina/services/ai/ai_context_builder.dart';
import 'package:aquamarina/services/ai/ai_image_service.dart';
import 'package:aquamarina/services/ai/ai_profile_service.dart';
import 'package:aquamarina/services/ai/ai_service.dart';
import 'package:aquamarina/services/ai/ai_usage_service.dart';
import 'package:dio/dio.dart';
import 'package:aquamarina/services/ai/tools/ai_tool.dart';
import 'package:aquamarina/services/ai/tools/ai_tool_registry.dart';
import 'package:aquamarina/services/ai/tools/tool_approval.dart';
import 'package:aquamarina/services/data/database_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 可编排的假 AI 服务：按调用顺序依次放出预设的流事件。
class _FakeAiService extends AiService {
  _FakeAiService(this.rounds);

  final List<List<AiChatEvent>> rounds;
  int calls = 0;
  bool cancelled = false;

  @override
  Stream<AiChatEvent> chatStreamEvents({
    required List<Map<String, dynamic>> messages,
    AiProfile? profile,
    List<Map<String, dynamic>>? tools,
    String? toolChoice,
    double? temperatureOverride,
    int? maxTokensOverride,
    CancelToken? cancelToken,
    void Function(AiUsageSnapshot usage)? onUsage,
  }) {
    final events = calls < rounds.length ? rounds[calls] : const <AiChatEvent>[];
    calls += 1;
    final controller = StreamController<AiChatEvent>();
    scheduleMicrotask(() async {
      for (final event in events) {
        if (controller.isClosed) return;
        controller.add(event);
      }
      if (!controller.isClosed) await controller.close();
    });
    return controller.stream;
  }
}

/// 记录每次请求消息的假服务。
class _CapturingAiService extends AiService {
  _CapturingAiService(this.captured);

  final List<List<Map<String, dynamic>>> captured;

  @override
  Stream<AiChatEvent> chatStreamEvents({
    required List<Map<String, dynamic>> messages,
    AiProfile? profile,
    List<Map<String, dynamic>>? tools,
    String? toolChoice,
    double? temperatureOverride,
    int? maxTokensOverride,
    CancelToken? cancelToken,
    void Function(AiUsageSnapshot usage)? onUsage,
  }) {
    captured.add(messages);
    return Stream<AiChatEvent>.fromIterable(const [
      ChatTextDelta('好的'),
      ChatDone('stop'),
    ]);
  }
}

/// 只实现非流式接口的假服务，用于验证「关闭流式」分支。
class _NonStreamFakeAiService extends AiService {
  _NonStreamFakeAiService(this.reply);

  final String reply;
  int chatOnceCalls = 0;
  int streamCalls = 0;

  @override
  Future<String> chatOnce({
    required List<Map<String, dynamic>> messages,
    AiProfile? profile,
    double? temperatureOverride,
    int? maxTokensOverride,
    CancelToken? cancelToken,
  }) async {
    chatOnceCalls += 1;
    return reply;
  }

  @override
  Stream<AiChatEvent> chatStreamEvents({
    required List<Map<String, dynamic>> messages,
    AiProfile? profile,
    List<Map<String, dynamic>>? tools,
    String? toolChoice,
    double? temperatureOverride,
    int? maxTokensOverride,
    CancelToken? cancelToken,
    void Function(AiUsageSnapshot usage)? onUsage,
  }) {
    streamCalls += 1;
    return const Stream<AiChatEvent>.empty();
  }
}

class _FakeProfileService extends AiProfileService {
  _FakeProfileService(this.profile);

  final AiProfile? profile;

  @override
  Future<void> load({bool force = false}) async {}

  @override
  AiProfile? get defaultProfile => profile;

  @override
  AiProfile? getProfile(String id) => profile;
}

AiProfile _profile() => const AiProfile(
  id: 'p1',
  name: '测试',
  type: AiProfileType.openai,
  apiKey: 'sk-test',
  model: 'gpt-4o-mini',
  // 多模态用例需要声明模型支持图片输入
  enableVision: true,
);

AiToolDescriptor _readTool(String name) => AiToolDescriptor(
  name: name,
  description: '只读工具',
  risk: AiToolRisk.readOnly,
  parameters: {'type': 'object', 'properties': {}},
  execute: (args) async => AiToolResult.success('read-ok'),
);

AiToolDescriptor _writeTool(String name) => AiToolDescriptor(
  name: name,
  description: '写工具',
  risk: AiToolRisk.mutating,
  parameters: {'type': 'object', 'properties': {}},
  execute: (args) async => AiToolResult.success('write-ok'),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;
  late AiChatService chatService;

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
    chatService = AiChatService.withDatabase(() async => db);
  });

  tearDown(() async {
    await db.close();
  });

  AiChatController build(
    _FakeAiService ai,
    AiToolRegistry registry, {
    AiToolApprovalHandler? handler,
  }) {
    return AiChatController(
      chatService: chatService,
      aiService: ai,
      profileService: _FakeProfileService(_profile()),
      settings: AiChatSettings(),
      toolRegistry: registry,
      approvalHandler: handler,
    );
  }

  group('trimContext', () {
    AiChatMessage msg(AiChatRole role, String content, {double index = 0}) =>
        AiChatMessage.create(
          sessionId: 's',
          role: role,
          content: content,
          sortIndex: index,
        );

    test('保留 system 与最近 N 条', () {
      final all = [
        msg(AiChatRole.user, 'u1'),
        msg(AiChatRole.assistant, 'a1'),
        msg(AiChatRole.user, 'u2'),
      ];
      final trimmed = AiChatController.trimContext(all, 2, system: 'SYS');
      expect(trimmed.first['role'], 'system');
      expect(trimmed.skip(1).map((m) => m['content']), ['a1', 'u2']);
    });

    test('tool_call 与 tool 结果成对保留', () {
      final call = AiToolCall.parse(
        id: 'c1',
        name: 'search_dictionary',
        rawArguments: '{}',
      );
      final all = [
        msg(AiChatRole.user, 'u1'),
        AiChatMessage.create(
          sessionId: 's',
          role: AiChatRole.assistant,
          content: '',
          toolCalls: [call],
        ),
        AiChatMessage.create(
          sessionId: 's',
          role: AiChatRole.tool,
          content: '结果',
          toolCallId: 'c1',
          toolName: 'search_dictionary',
        ),
        msg(AiChatRole.user, 'u2'),
      ];
      // 只保留 2 条时，边界落在 tool 上 → 回退到 assistant(tool_calls)
      final trimmed = AiChatController.trimContext(all, 2, system: 'SYS');
      final roles = trimmed.map((m) => m['role']).toList();
      expect(roles.first, 'system');
      expect(roles.contains('tool'), isTrue);
      expect(roles.contains('assistant'), isTrue);
    });

    test('空 system 不注入', () {
      final trimmed = AiChatController.trimContext([
        msg(AiChatRole.user, 'u'),
      ], 10, system: '   ');
      expect(trimmed, hasLength(1));
    });
  });

  group('工具批准', () {
    test('只读工具在自动批准开启时不询问用户', () async {
      var asked = 0;
      final ai = _FakeAiService([
        [
          ChatToolCallsCompleted(
            [
              AiToolCall.parse(id: 'c1', name: 'read_tool', rawArguments: '{}'),
            ],
            'tool_calls',
          ),
          ChatDone('tool_calls'),
        ],
        [ChatTextDelta('完成'), ChatDone('stop')],
      ]);
      final controller = build(
        ai,
        AiToolRegistry([_readTool('read_tool')]),
        handler: (call, tool) async {
          asked += 1;
          return AiToolApprovalDecision.approved;
        },
      );
      await controller.createSession();
      await controller.send('帮我查一下');

      expect(asked, 0);
      final toolMessages = controller.messages
          .where((m) => m.role == AiChatRole.tool)
          .toList();
      expect(toolMessages, hasLength(1));
      expect(toolMessages.single.content, 'read-ok');
    });

    test('写工具会询问，拒绝时不执行', () async {
      var asked = 0;
      var executed = 0;
      final writeTool = AiToolDescriptor(
        name: 'write_tool',
        description: '写',
        risk: AiToolRisk.mutating,
        parameters: {'type': 'object', 'properties': {}},
        execute: (args) async {
          executed += 1;
          return AiToolResult.success('done');
        },
      );
      final ai = _FakeAiService([
        [
          ChatToolCallsCompleted(
            [
              AiToolCall.parse(id: 'c1', name: 'write_tool', rawArguments: '{}'),
            ],
            'tool_calls',
          ),
          ChatDone('tool_calls'),
        ],
        [ChatTextDelta('好的'), ChatDone('stop')],
      ]);
      final controller = build(
        ai,
        AiToolRegistry([writeTool]),
        handler: (call, tool) async {
          asked += 1;
          return AiToolApprovalDecision.denied;
        },
      );
      await controller.createSession();
      await controller.send('帮我加词');

      expect(asked, 1);
      expect(executed, 0);
      final toolMessage = controller.messages
          .firstWhere((m) => m.role == AiChatRole.tool);
      expect(toolMessage.content, contains('用户拒绝'));
      expect(toolMessage.errorMessage, 'denied_by_user');
    });

    test('alwaysAllowedInSession 后同一工具不再询问', () async {
      var asked = 0;
      final ai = _FakeAiService([
        [
          ChatToolCallsCompleted(
            [
              AiToolCall.parse(id: 'c1', name: 'write_tool', rawArguments: '{}'),
            ],
            'tool_calls',
          ),
          ChatDone('tool_calls'),
        ],
        [
          ChatToolCallsCompleted(
            [
              AiToolCall.parse(id: 'c2', name: 'write_tool', rawArguments: '{}'),
            ],
            'tool_calls',
          ),
          ChatDone('tool_calls'),
        ],
        [ChatTextDelta('完成'), ChatDone('stop')],
      ]);
      final controller = build(
        ai,
        AiToolRegistry([_writeTool('write_tool')]),
        handler: (call, tool) async {
          asked += 1;
          return AiToolApprovalDecision.alwaysAllowedInSession;
        },
      );
      await controller.createSession();
      await controller.send('批量处理');

      expect(asked, 1);
      expect(controller.messages.where((m) => m.role == AiChatRole.tool), hasLength(2));
    });

    test('无 handler（页面已销毁）时一律拒绝', () async {
      final ai = _FakeAiService([
        [
          ChatToolCallsCompleted(
            [
              AiToolCall.parse(id: 'c1', name: 'write_tool', rawArguments: '{}'),
            ],
            'tool_calls',
          ),
          ChatDone('tool_calls'),
        ],
        [ChatTextDelta('ok'), ChatDone('stop')],
      ]);
      final controller = build(ai, AiToolRegistry([_writeTool('write_tool')]));
      await controller.createSession();
      await controller.send('做点什么');

      final toolMessage = controller.messages
          .firstWhere((m) => m.role == AiChatRole.tool);
      expect(toolMessage.errorMessage, 'denied_by_user');
    });

    test('工具轮次上限生效', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        AiChatSettings.maxToolRoundsKey: 1,
      });
      List<AiChatEvent> toolRound(int i) => [
        ChatToolCallsCompleted(
          [AiToolCall.parse(id: 'c$i', name: 'read_tool', rawArguments: '{}')],
          'tool_calls',
        ),
        ChatDone('tool_calls'),
      ];
      final ai = _FakeAiService([
        toolRound(1),
        toolRound(2),
        toolRound(3),
      ]);
      final controller = build(ai, AiToolRegistry([_readTool('read_tool')]));
      await controller.createSession();
      await controller.send('循环调用');

      // 第一轮执行工具后，达到上限会插入停止提示
      final notices = controller.messages
          .where((m) => m.toolName == 'system')
          .toList();
      expect(notices, hasLength(1));
      expect(notices.single.content, contains('上限'));
    });
  });

  group('上下文自动注入', () {
    test('上下文追加到最后一条 user 消息，且不改动 system 提示词', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final captured = <List<Map<String, dynamic>>>[];
      final controller = AiChatController(
        chatService: chatService,
        aiService: _CapturingAiService(captured),
        profileService: _FakeProfileService(_profile()),
        settings: AiChatSettings(),
        toolRegistry: AiToolRegistry(const []),
        contextBuilder: AiContextBuilder(
          packageInfoLoader: () async => PackageInfo(
            appName: 'Aquamarina',
            packageName: 'app.aquamarina',
            version: '1.4.5',
            buildNumber: '28',
          ),
          schemaVersionLoader: () => 21,
          clock: () => DateTime(2026, 11, 15, 20, 50),
        ),
      );
      addTearDown(controller.dispose);
      await controller.createSession();
      await controller.send('现在几点？');

      final sent = captured.first;

      // system 提示词必须逐字等于基础提示词：不能混入每轮变化的上下文
      final system = sent.firstWhere((m) => m['role'] == 'system');
      final systemText = system['content'] as String;
      expect(systemText, AiChatSettings.defaultSystemPrompt);
      expect(systemText, isNot(contains('<runtime-context>')));

      // 上下文是紧跟其后的**独立消息**，不改写用户内容
      expect(sent[1]['role'], 'user');
      expect(sent[1]['content'], '现在几点？');
      expect(sent[2]['role'], 'user');

      final note = sent[2]['content'] as String;
      expect(note, contains('<context-note>'));
      expect(note, contains('不是用户输入的内容'));
      expect(note, contains('1.4.5+28'));
      expect(note, contains('2026-11-15 20:50'));
      // 上下文里不含用户原话以外的内容改动
      expect(note, contains('</context-note>'));
    });

    test('历史轮次前缀逐字不变，保证缓存命中', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final captured = <List<Map<String, dynamic>>>[];
      var now = DateTime(2026, 11, 15, 20, 50);
      final controller = AiChatController(
        chatService: chatService,
        aiService: _CapturingAiService(captured),
        profileService: _FakeProfileService(_profile()),
        settings: AiChatSettings(),
        toolRegistry: AiToolRegistry(const []),
        contextBuilder: AiContextBuilder(
          packageInfoLoader: () async => PackageInfo(
            appName: 'Aquamarina',
            packageName: 'app.aquamarina',
            version: '1.4.5',
            buildNumber: '28',
          ),
          schemaVersionLoader: () => 21,
          clock: () => now,
        ),
      );
      addTearDown(controller.dispose);
      await controller.createSession();
      await controller.send('第一问');
      now = DateTime(2026, 11, 15, 21, 30);
      await controller.send('第二问');

      final first = captured[0];
      final second = captured[1];

      // 第一轮：system, user(第一问), user(上下文)
      // 第二轮：system, user(第一问), user(旧上下文), assistant, user(第二问), user(新上下文)
      expect(first, hasLength(3));
      expect(second.length, greaterThan(first.length));

      // 关键：第二轮的前 3 条必须与第一轮逐字相同 → 前缀缓存可命中
      for (var i = 0; i < first.length; i++) {
        expect(second[i]['role'], first[i]['role']);
        expect(second[i]['content'], first[i]['content']);
      }

      // 历史上下文冻结在 20:50，最新的才用 21:30
      expect(first[2]['content'] as String, contains('20:50'));
      expect(second[2]['content'] as String, contains('20:50'));
      expect(second.last['content'] as String, contains('21:30'));
    });

    test('上下文作为独立消息紧随用户消息', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final captured = <List<Map<String, dynamic>>>[];
      final controller = AiChatController(
        chatService: chatService,
        aiService: _CapturingAiService(captured),
        profileService: _FakeProfileService(_profile()),
        settings: AiChatSettings(),
        toolRegistry: AiToolRegistry(const []),
        contextBuilder: AiContextBuilder(
          packageInfoLoader: () async => PackageInfo(
            appName: 'Aquamarina',
            packageName: 'app.aquamarina',
            version: '1.4.5',
            buildNumber: '28',
          ),
          schemaVersionLoader: () => 21,
          clock: () => DateTime(2026, 11, 15, 20, 50),
        ),
      );
      addTearDown(controller.dispose);
      await controller.createSession();
      await controller.send('现在几点？');

      final sent = captured.first;
      expect(sent[1]['content'], '现在几点？');
      final note = sent[2]['content'] as String;
      expect(note, contains('<runtime-context>'));
      expect(note, contains('1.4.5+28'));
      expect(note, contains('<time-context>'));
      expect(note, contains('2026-11-15 20:50'));
    });

    test('关闭注入时既不注入上下文，也不改动 system 提示词', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        AiChatSettings.injectRuntimeContextKey: false,
        AiChatSettings.injectTimeContextKey: false,
      });
      final captured = <List<Map<String, dynamic>>>[];
      final controller = AiChatController(
        chatService: chatService,
        aiService: _CapturingAiService(captured),
        profileService: _FakeProfileService(_profile()),
        settings: AiChatSettings(),
        toolRegistry: AiToolRegistry(const []),
      );
      addTearDown(controller.dispose);
      await controller.createSession();
      await controller.send('你好');

      final sent = captured.first;
      // 只有 system + user
      expect(sent, hasLength(2));
      expect(sent[1]['content'], '你好');
      // 默认提示词本身提到 <context-note>，这里只看非 system 消息
      expect(
        sent.where(
          (m) =>
              m['role'] != 'system' &&
              '${m['content']}'.contains('<context-note>'),
        ),
        isEmpty,
      );
    });
  });

  group('上下文按变化注入', () {
    AiChatController build(
      List<List<Map<String, dynamic>>> captured,
      DateTime Function() clock,
    ) {
      return AiChatController(
        chatService: chatService,
        aiService: _CapturingAiService(captured),
        profileService: _FakeProfileService(_profile()),
        settings: AiChatSettings(),
        toolRegistry: AiToolRegistry(const []),
        contextBuilder: AiContextBuilder(
          packageInfoLoader: () async => PackageInfo(
            appName: 'Aquamarina',
            packageName: 'app.aquamarina',
            version: '1.4.5',
            buildNumber: '28',
          ),
          schemaVersionLoader: () => 21,
          clock: clock,
        ),
      );
    }

    test('同一分钟内第二轮不再重复注入', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final captured = <List<Map<String, dynamic>>>[];
      final controller = build(captured, () => DateTime(2026, 11, 15, 20, 50, 10));
      addTearDown(controller.dispose);

      await controller.createSession();
      await controller.send('第一问');
      await controller.send('第二问');

      // 第一轮：system, user, context
      expect(captured[0], hasLength(3));
      // 第二轮：上下文无变化 → 不再新增注入消息
      final notes = captured[1]
          .where((m) => m['role'] != 'system')
          .where((m) => '${m['content']}'.contains('<context-note>'))
          .toList();
      expect(notes, hasLength(1), reason: '只有第一轮那份，历史原样重发');
    });

    test('时间跨分钟后会补一条新的注入', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final captured = <List<Map<String, dynamic>>>[];
      var now = DateTime(2026, 11, 15, 20, 50, 10);
      final controller = build(captured, () => now);
      addTearDown(controller.dispose);

      await controller.createSession();
      await controller.send('第一问');
      now = DateTime(2026, 11, 15, 21, 30, 0);
      await controller.send('第二问');

      final notes = captured[1]
          .where((m) => m['role'] != 'system')
          .where((m) => '${m['content']}'.contains('<context-note>'))
          .toList();
      expect(notes, hasLength(2), reason: '历史一份 + 本轮新增一份');
      expect(notes.first['content'] as String, contains('20:50'));
      expect(notes.last['content'] as String, contains('21:30'));
    });

    test('runtime 恒定则只在首轮出现一次', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final captured = <List<Map<String, dynamic>>>[];
      var now = DateTime(2026, 11, 15, 20, 50, 0);
      final controller = build(captured, () => now);
      addTearDown(controller.dispose);

      await controller.createSession();
      await controller.send('一');
      now = DateTime(2026, 11, 15, 22, 0, 0);
      await controller.send('二');

      final runtimeNotes = captured[1]
          .where((m) => m['role'] != 'system')
          .where((m) => '${m['content']}'.contains('<runtime-context>'));
      expect(runtimeNotes, hasLength(1), reason: 'runtime 未变化，不重复注入');
    });
  });

  group('上下文注入标签解析', () {
    test('解析出注入的分块名', () {
      const note = '<context-note>\n<runtime-context>\nA\n</runtime-context>\n'
          '<time-context>\nB\n</time-context>\n</context-note>';
      expect(
        AiChatController.contextTagsOf(note),
        ['runtime-context', 'time-context'],
      );
    });

    test('只注入时间时只返回 time-context', () {
      const note = '<context-note>\n<time-context>\nB\n</time-context>\n</context-note>';
      expect(AiChatController.contextTagsOf(note), ['time-context']);
    });

    test('没有分块时返回空列表', () {
      expect(AiChatController.contextTagsOf('纯文本'), isEmpty);
    });
  });

  group('多模态', () {
    AiChatAttachment attachment() => AiChatAttachment(
      id: 'a1',
      localPath: null,
      fileName: 'x.png',
      width: 8,
      height: 8,
      thumbnailBase64:
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8AAAwAB/AL+2QAAAABJRU5ErkJggg==',
      thumbnailSize: AiChatAttachment.thumbSizeLarge,
    );

    test('只给最近一条带图消息注入图片 payload', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        AiChatSettings.imageSendModeKey: AiImageSendMode.thumbnail.name,
      });
      final captured = <List<Map<String, dynamic>>>[];
      final ai = _CapturingAiService(captured);
      final controller = AiChatController(
        chatService: chatService,
        aiService: ai,
        profileService: _FakeProfileService(_profile()),
        settings: AiChatSettings(),
        toolRegistry: AiToolRegistry(const []),
      );
      await controller.createSession();

      await controller.send('第一张', attachments: [attachment()]);
      await controller.send('第二张', attachments: [attachment()]);

      expect(captured, hasLength(2));
      // 第二轮请求里：历史那条不再带 image_url，只有最新一条带
      final second = captured[1];
      final imageParts = <Map>[];
      for (final message in second) {
        final content = message['content'];
        if (content is List) {
          for (final part in content) {
            if (part is Map && part['type'] == 'image_url') imageParts.add(part);
          }
        }
      }
      expect(imageParts, hasLength(1));
      expect(
        ((imageParts.single['image_url'] as Map)['url'] as String),
        startsWith('data:image/png;base64,'),
      );
    });
  });

  group('流式与错误', () {
    test('正文与思维链分开累计并落库', () async {
      final ai = _FakeAiService([
        [
          ChatReasoningDelta('先想想'),
          ChatTextDelta('你好，'),
          ChatTextDelta('世界'),
          ChatDone('stop'),
        ],
      ]);
      final controller = build(ai, AiToolRegistry(const []));
      await controller.createSession();
      await controller.send('打招呼');

      final assistant = controller.messages
          .lastWhere((m) => m.role == AiChatRole.assistant);
      expect(assistant.content, '你好，世界');
      expect(assistant.reasoning, '先想想');
      expect(assistant.status, AiChatMessageStatus.complete);
    });

    test('关闭流式输出时走单次请求且不启用工具', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        AiChatSettings.streamEnabledKey: false,
      });
      final ai = _NonStreamFakeAiService('一次性回答');
      final controller = AiChatController(
        chatService: chatService,
        aiService: ai,
        profileService: _FakeProfileService(_profile()),
        settings: AiChatSettings(),
        toolRegistry: AiToolRegistry([_readTool('read_tool')]),
      );
      await controller.createSession();
      await controller.send('你好');

      expect(ai.chatOnceCalls, 1);
      expect(ai.streamCalls, 0);
      final assistant = controller.messages
          .lastWhere((m) => m.role == AiChatRole.assistant);
      expect(assistant.content, '一次性回答');
    });

    test('请求失败时消息标 error 并保留已生成内容', () async {
      final ai = _FakeAiService([
        [
          ChatTextDelta('半句'),
          ChatError(AiServiceException('网络请求失败')),
        ],
      ]);
      final controller = build(ai, AiToolRegistry(const []));
      await controller.createSession();
      await controller.send('你好');

      expect(controller.error, contains('网络请求失败'));
      final assistant = controller.messages
          .lastWhere((m) => m.role == AiChatRole.assistant);
      expect(assistant.content, '半句');
      expect(assistant.status, AiChatMessageStatus.error);
    });
  });
}
