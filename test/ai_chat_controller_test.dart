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

/// 假服务基类：默认的非流式调用返回空串，避免自动标题用例触发真实网络。
class _BaseFakeAiService extends AiService {
  @override
  Future<String> chatOnce({
    required List<Map<String, dynamic>> messages,
    AiProfile? profile,
    double? temperatureOverride,
    int? maxTokensOverride,
    CancelToken? cancelToken,
  }) async {
    return '';
  }
}

/// 可编排的假 AI 服务：按调用顺序依次放出预设的流事件。
class _FakeAiService extends _BaseFakeAiService {
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
    final events = calls < rounds.length
        ? rounds[calls]
        : const <AiChatEvent>[];
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

/// 可观察时序的假服务：第一轮/首个增量送达后放行测试回调，
/// 便于在流式途中注入 cancel 或切换会话。
class _ControllableAiService extends _BaseFakeAiService {
  _ControllableAiService(this.rounds);

  final List<List<AiChatEvent>> rounds;
  int calls = 0;
  final Completer<void> firstDeltaSent = Completer<void>();
  final Completer<void> firstRoundDone = Completer<void>();

  /// 第一轮送出首个文本增量后暂停，直到测试调用 [release]。
  /// 让「取消/切换会话」严格发生在流式途中，避免竞态。
  final Completer<void> _gate = Completer<void>();

  /// 放行第一轮继续发送剩余事件。
  void release() {
    if (!_gate.isCompleted) _gate.complete();
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
    final index = calls;
    calls += 1;
    final events = index < rounds.length
        ? rounds[index]
        : const <AiChatEvent>[];
    final controller = StreamController<AiChatEvent>();
    scheduleMicrotask(() async {
      for (final event in events) {
        // 每条事件之间让出一次微任务，测试才有机会在流式途中介入。
        await Future<void>.delayed(Duration.zero);
        if (controller.isClosed) {
          return;
        }
        controller.add(event);
        if (index == 0 && event is ChatTextDelta) {
          if (!firstDeltaSent.isCompleted) firstDeltaSent.complete();
          await _gate.future;
        }
      }
      await Future<void>.delayed(Duration.zero);
      if (!controller.isClosed) await controller.close();
      if (index == 0 && !firstRoundDone.isCompleted) {
        firstRoundDone.complete();
      }
    });
    return controller.stream;
  }
}

/// 记录每次请求消息的假服务。
class _CapturingAiService extends _BaseFakeAiService {
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

/// 会回调 usage 的假服务，用于验证消息级 token / 费用角标。
class _UsageAiService extends _BaseFakeAiService {
  _UsageAiService(this.snapshot);

  final AiUsageSnapshot snapshot;

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
  }) async* {
    onUsage?.call(snapshot);
    yield const ChatTextDelta('好的');
    yield const ChatDone('stop');
  }
}

/// 只实现非流式接口的假服务，用于验证「关闭流式」分支。
class _NonStreamFakeAiService extends _BaseFakeAiService {
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

/// 自动标题用例：记录非流式调用次数，可返回固定标题或等待外部放行。
class _TitleAiService extends _FakeAiService {
  _TitleAiService(super.rounds, {this.reply = '', this.gate, this.error});

  final String reply;
  final Completer<String>? gate;
  final Object? error;
  int titleCalls = 0;

  @override
  Future<String> chatOnce({
    required List<Map<String, dynamic>> messages,
    AiProfile? profile,
    double? temperatureOverride,
    int? maxTokensOverride,
    CancelToken? cancelToken,
  }) async {
    titleCalls += 1;
    if (gate != null) return gate!.future;
    if (error != null) throw error!;
    return reply;
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
    AiService ai,
    AiToolRegistry registry, {
    AiToolApprovalHandler? handler,
    AiProfile? profile,
  }) {
    return AiChatController(
      chatService: chatService,
      aiService: ai,
      profileService: _FakeProfileService(profile ?? _profile()),
      settings: AiChatSettings(),
      toolRegistry: registry,
      approvalHandler: handler,
    );
  }

  group('上下文处理', () {
    test('压缩后仍超限时落一条可见错误，不发起模型请求', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'ai_chat_context_compression_enabled': true,
        'ai_chat_context_threshold_mode': 'absolute',
        'ai_chat_context_threshold_tokens': 500,
      });
      final ai = _FakeAiService(const []);
      final controller = build(
        ai,
        AiToolRegistry([]),
        profile: _profile().copyWith(contextWindow: 500),
      );
      await controller.createSession();
      await controller.send(List.filled(600, '字').join());

      expect(ai.calls, 0);
      expect(controller.state, AiChatStreamState.idle);
      expect(controller.messages.last.status, AiChatMessageStatus.error);
      expect(controller.messages.last.errorMessage, contains('超出模型上下文窗口'));
    });

    test('会话用量达到提示比例时暴露 contextUsage', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'ai_chat_context_compression_enabled': false,
        'ai_chat_context_usage_warning_enabled': true,
        'ai_chat_context_usage_warning_ratio': 0.7,
      });
      final ai = _FakeAiService([
        [const ChatTextDelta('好的'), const ChatDone('stop')],
      ]);
      final controller = build(
        ai,
        AiToolRegistry([]),
        profile: _profile().copyWith(contextWindow: 20000),
      );
      await controller.createSession();
      await controller.send(List.filled(16000, '字').join());

      final usage = controller.contextUsage;
      expect(usage, isNotNull);
      expect(usage!.windowTokens, 20000);
      expect(usage.warningTokens, 14000);
      expect(usage.usedTokens, greaterThanOrEqualTo(14000));
      expect(usage.isWarning, isTrue);
      expect(
        controller.messages.where((m) => m.status == AiChatMessageStatus.error),
        isEmpty,
      );
    });

    test('用量提示关闭时不暴露提示状态', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'ai_chat_context_compression_enabled': false,
        'ai_chat_context_usage_warning_enabled': false,
      });
      final ai = _FakeAiService([
        [const ChatTextDelta('好的'), const ChatDone('stop')],
      ]);
      final controller = build(
        ai,
        AiToolRegistry([]),
        profile: _profile().copyWith(contextWindow: 20000),
      );
      await controller.createSession();
      await controller.send(List.filled(16000, '字').join());

      final usage = controller.contextUsage;
      expect(usage, isNotNull);
      expect(usage!.warningTokens, 0);
      expect(usage.isWarning, isFalse);
    });
  });

  group('用量角标', () {
    test('回答记录本轮真实用量与费用，并随消息落库', () async {
      const pricing = AiUsagePricing(
        unit: AiPriceUnit.perMillion,
        cacheHitPrice: 1,
        cacheMissPrice: 5,
        outputPrice: 10,
      );
      final ai = _UsageAiService(
        const AiUsageSnapshot(
          promptTokens: 1000,
          cacheHitTokens: 400,
          cacheMissTokens: 600,
          completionTokens: 200,
          totalTokens: 1200,
        ),
      );
      final controller = build(
        ai,
        AiToolRegistry([]),
        profile: _profile().copyWith(pricing: pricing),
      );
      await controller.createSession();
      await controller.send('你好');

      final assistant = controller.messages.last;
      expect(assistant.role, AiChatRole.assistant);
      final usage = assistant.usage;
      expect(usage, isNotNull);
      expect(usage!.promptTokens, 1000);
      expect(usage.completionTokens, 200);
      expect(usage.totalTokens, 1200);
      // 400/1M*1 + 600/1M*5 + 200/1M*10 = 0.0054
      expect(usage.cost, closeTo(0.0054, 1e-9));

      // 落库后 JSON 往返仍然完整
      final reloaded = await chatService.loadMessages(controller.session!.id);
      expect(reloaded.last.usage, isNotNull);
      expect(reloaded.last.usage!.totalTokens, 1200);
      expect(reloaded.last.usage!.cost, closeTo(0.0054, 1e-9));
    });

    test('没有 usage 时不写角标', () async {
      final ai = _FakeAiService([
        [const ChatTextDelta('好的'), const ChatDone('stop')],
      ]);
      final controller = build(ai, AiToolRegistry([]));
      await controller.createSession();
      await controller.send('你好');
      expect(controller.messages.last.usage, isNull);
    });

    test('配置未启用计费时只有 token 没有费用', () async {
      final ai = _UsageAiService(
        const AiUsageSnapshot(
          promptTokens: 100,
          cacheHitTokens: 0,
          cacheMissTokens: 100,
          completionTokens: 20,
          totalTokens: 120,
        ),
      );
      final controller = build(ai, AiToolRegistry([]));
      await controller.createSession();
      await controller.send('你好');
      final usage = controller.messages.last.usage;
      expect(usage, isNotNull);
      expect(usage!.cost, isNull);
    });
  });

  group('自动标题', () {
    Future<bool> waitTitle(String sessionId, String expected) async {
      for (var i = 0; i < 200; i++) {
        final session = await chatService.getSession(sessionId);
        if (session?.title == expected) {
          return true;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return false;
    }

    Future<void> waitUntil(bool Function() predicate) async {
      for (var i = 0; i < 200; i++) {
        if (predicate()) {
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    test('首轮回答完成后用模型总结替换占位标题', () async {
      final ai = _TitleAiService([
        [const ChatTextDelta('prevalent 是形容词，意思是普遍的。'), const ChatDone('stop')],
      ], reply: '「prevalent 的常见用法。」');
      final controller = build(ai, AiToolRegistry([]));
      final session = await controller.createSession();
      await controller.send('帮我看看 prevalent 怎么用在句子里');

      expect(await waitTitle(session.id, 'prevalent 的常见用法'), isTrue);
      expect(ai.titleCalls, 1);
      expect(controller.session?.title, 'prevalent 的常见用法');
      expect(controller.titleRevision, 1);
    });

    test('关闭自动标题时不发起请求，保留本地占位标题', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'ai_chat_auto_title_enabled': false,
      });
      final ai = _TitleAiService([
        [const ChatTextDelta('好的'), const ChatDone('stop')],
      ], reply: '不应出现');
      final controller = build(ai, AiToolRegistry([]));
      final session = await controller.createSession();
      await controller.send('帮我看看 prevalent 怎么用');
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(ai.titleCalls, 0);
      final saved = await chatService.getSession(session.id);
      expect(saved?.title, AiChatService.suggestTitle('帮我看看 prevalent 怎么用'));
      expect(controller.titleRevision, 0);
    });

    test('用户手动改名后不被自动标题覆盖', () async {
      final gate = Completer<String>();
      final ai = _TitleAiService([
        [const ChatTextDelta('好的'), const ChatDone('stop')],
      ], gate: gate);
      final controller = build(ai, AiToolRegistry([]));
      final session = await controller.createSession();
      await controller.send('帮我看看 prevalent 怎么用');

      await waitUntil(() => ai.titleCalls == 1);
      await chatService.renameSession(session.id, '我的标题');
      gate.complete('自动标题');
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final saved = await chatService.getSession(session.id);
      expect(saved?.title, '我的标题');
      expect(controller.titleRevision, 0);
    });

    test('模型调用失败时保留占位标题且不报错', () async {
      final ai = _TitleAiService([
        [const ChatTextDelta('好的'), const ChatDone('stop')],
      ], error: StateError('boom'));
      final controller = build(ai, AiToolRegistry([]));
      final session = await controller.createSession();
      await controller.send('帮我看看 prevalent 怎么用');
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final saved = await chatService.getSession(session.id);
      expect(saved?.title, AiChatService.suggestTitle('帮我看看 prevalent 怎么用'));
      expect(controller.titleRevision, 0);
    });
  });

  group('工具批准', () {
    test('只读工具在自动批准开启时不询问用户', () async {
      var asked = 0;
      final ai = _FakeAiService([
        [
          ChatToolCallsCompleted([
            AiToolCall.parse(id: 'c1', name: 'read_tool', rawArguments: '{}'),
          ], 'tool_calls'),
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
          ChatToolCallsCompleted([
            AiToolCall.parse(id: 'c1', name: 'write_tool', rawArguments: '{}'),
          ], 'tool_calls'),
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
      final toolMessage = controller.messages.firstWhere(
        (m) => m.role == AiChatRole.tool,
      );
      expect(toolMessage.content, contains('用户拒绝'));
      expect(toolMessage.errorMessage, 'denied_by_user');
    });

    test('alwaysAllowedInSession 后同一工具不再询问', () async {
      var asked = 0;
      final ai = _FakeAiService([
        [
          ChatToolCallsCompleted([
            AiToolCall.parse(id: 'c1', name: 'write_tool', rawArguments: '{}'),
          ], 'tool_calls'),
          ChatDone('tool_calls'),
        ],
        [
          ChatToolCallsCompleted([
            AiToolCall.parse(id: 'c2', name: 'write_tool', rawArguments: '{}'),
          ], 'tool_calls'),
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
      expect(
        controller.messages.where((m) => m.role == AiChatRole.tool),
        hasLength(2),
      );
    });

    test('无 handler（页面已销毁）时一律拒绝', () async {
      final ai = _FakeAiService([
        [
          ChatToolCallsCompleted([
            AiToolCall.parse(id: 'c1', name: 'write_tool', rawArguments: '{}'),
          ], 'tool_calls'),
          ChatDone('tool_calls'),
        ],
        [ChatTextDelta('ok'), ChatDone('stop')],
      ]);
      final controller = build(ai, AiToolRegistry([_writeTool('write_tool')]));
      await controller.createSession();
      await controller.send('做点什么');

      final toolMessage = controller.messages.firstWhere(
        (m) => m.role == AiChatRole.tool,
      );
      expect(toolMessage.errorMessage, 'denied_by_user');
    });

    test('工具轮次上限生效', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        AiChatSettings.maxToolRoundsKey: 1,
      });
      List<AiChatEvent> toolRound(int i) => [
        ChatToolCallsCompleted([
          AiToolCall.parse(id: 'c$i', name: 'read_tool', rawArguments: '{}'),
        ], 'tool_calls'),
        ChatDone('tool_calls'),
      ];
      final ai = _FakeAiService([toolRound(1), toolRound(2), toolRound(3)]);
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
      final controller = build(
        captured,
        () => DateTime(2026, 11, 15, 20, 50, 10),
      );
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
      const note =
          '<context-note>\n<runtime-context>\nA\n</runtime-context>\n'
          '<time-context>\nB\n</time-context>\n</context-note>';
      expect(AiChatController.contextTagsOf(note), [
        'runtime-context',
        'time-context',
      ]);
    });

    test('只注入时间时只返回 time-context', () {
      const note =
          '<context-note>\n<time-context>\nB\n</time-context>\n</context-note>';
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
            if (part is Map && part['type'] == 'image_url') {
              imageParts.add(part);
            }
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

      final assistant = controller.messages.lastWhere(
        (m) => m.role == AiChatRole.assistant,
      );
      expect(assistant.content, '你好，世界');
      expect(assistant.reasoning, '先想想');
      expect(assistant.status, AiChatMessageStatus.complete);
    });

    test('关闭流式输出时走单次请求且不启用工具', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        AiChatSettings.streamEnabledKey: false,
        // 本用例只验证单次请求分支，关闭自动标题避免额外请求干扰计数。
        AiChatSettings.autoTitleEnabledKey: false,
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
      final assistant = controller.messages.lastWhere(
        (m) => m.role == AiChatRole.assistant,
      );
      expect(assistant.content, '一次性回答');
    });

    test('请求失败时消息标 error 并保留已生成内容', () async {
      final ai = _FakeAiService([
        [ChatTextDelta('半句'), ChatError(AiServiceException('网络请求失败'))],
      ]);
      final controller = build(ai, AiToolRegistry(const []));
      await controller.createSession();
      await controller.send('你好');

      expect(controller.error, contains('网络请求失败'));
      final assistant = controller.messages.lastWhere(
        (m) => m.role == AiChatRole.assistant,
      );
      expect(assistant.content, '半句');
      expect(assistant.status, AiChatMessageStatus.error);
    });
  });

  group('取消与会话切换', () {
    test('工具轮次中途取消后不再发起下一轮请求', () async {
      final ai = _ControllableAiService([
        [
          ChatToolCallsCompleted([
            AiToolCall.parse(id: 'c1', name: 'read_tool', rawArguments: '{}'),
          ], 'tool_calls'),
          ChatDone('tool_calls'),
        ],
        const [ChatTextDelta('第二轮'), ChatDone('stop')],
      ]);
      final controller = build(ai, AiToolRegistry([_readTool('read_tool')]));
      addTearDown(controller.dispose);
      await controller.createSession();

      final future = controller.send('循环调用');
      // 等第一轮响应结束（此时正在执行工具/准备下一轮），再取消
      await ai.firstRoundDone.future;
      controller.cancel();
      await future;

      // 取消后不得再发起第二轮
      expect(ai.calls, 1);
      expect(controller.state, AiChatStreamState.idle);
    });

    test('切换会话后旧流式内容不会污染新会话', () async {
      final ai = _ControllableAiService([
        const [ChatTextDelta('旧会话回答'), ChatDone('stop')],
        const [ChatTextDelta('新会话回答'), ChatDone('stop')],
      ]);
      final controller = build(ai, AiToolRegistry(const []));
      addTearDown(controller.dispose);
      await controller.createSession();

      final future = controller.send('旧问题');
      await ai.firstDeltaSent.future;
      final newSession = await controller.createSession();
      ai.release();
      await future;
      await controller.send('新问题');

      // 旧会话仍在数据库里，但不应该出现在新会话视图中
      expect(controller.session?.id, newSession.id);
      final contents = controller.messages
          .where((m) => m.role == AiChatRole.assistant)
          .map((m) => m.content)
          .toList();
      expect(contents, isNot(contains('旧会话回答')));
    });
  });
}
