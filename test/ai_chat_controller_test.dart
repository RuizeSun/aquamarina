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
    test('系统提示词里带上 runtime 与 time 上下文', () async {
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

      final system = captured.first.firstWhere((m) => m['role'] == 'system');
      final content = system['content'] as String;
      expect(content, contains('<runtime-context>'));
      expect(content, contains('1.4.5+28'));
      expect(content, contains('<time-context>'));
      expect(content, contains('2026-11-15 20:50'));
    });

    test('关闭注入时系统提示词不含上下文标签', () async {
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

      final system = captured.first.firstWhere((m) => m['role'] == 'system');
      final content = system['content'] as String;
      // 默认提示词本身就提到这两个标签，因此要断言「实际注入的内容」没出现
      expect(content, isNot(contains('App: Aquamarina')));
      expect(content, isNot(contains('数据库 schema:')));
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
