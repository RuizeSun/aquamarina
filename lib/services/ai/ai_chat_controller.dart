import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../models/ai_chat.dart';
import '../../models/ai_profile.dart';
import '../system/log_service.dart';
import 'ai_chat_service.dart';
import 'ai_chat_settings.dart';
import 'ai_context_builder.dart';
import 'ai_image_service.dart';
import 'ai_profile_service.dart';
import 'ai_service.dart';
import 'tools/ai_tool.dart';
import 'tools/app_tools.dart';
import 'tools/ai_tool_registry.dart';
import 'tools/tool_approval.dart';

/// 对话页的运行状态。
enum AiChatStreamState {
  /// 空闲
  idle,

  /// 正在接收模型增量
  streaming,

  /// 等待用户批准工具调用
  awaitingApproval,

  /// 正在执行工具
  waitingTool,
}

/// AI 对话的编排层。
///
/// 只依赖服务，不依赖 Widget，便于单测。页面通过 [ChangeNotifier] 监听状态。
///
/// 落库策略：流式期间消息只驻留内存，一轮结束后一次性写入数据库，
/// 避免逐帧写库与 oplog 洪峰。
class AiChatController extends ChangeNotifier {
  AiChatController({
    AiChatService? chatService,
    AiService? aiService,
    AiProfileService? profileService,
    AiChatSettings? settings,
    AiToolRegistry? toolRegistry,
    AiToolApprovalHandler? approvalHandler,
    AiImageService? imageService,
    AiContextBuilder? contextBuilder,
  }) : _chatService = chatService ?? AiChatService.instance,
       _contextBuilder = contextBuilder ?? AiContextBuilder(),
       _imageService = imageService ?? AiImageService.instance,
       _aiService = aiService ?? AiService(),
       _profileService = profileService ?? AiProfileService(),
       _settings = settings ?? AiChatSettings(),
       _registry = toolRegistry ?? AiToolRegistry(AppTools.build()),
       _approvalHandler = approvalHandler;

  final AiChatService _chatService;
  final AiService _aiService;
  final AiProfileService _profileService;
  final AiChatSettings _settings;
  final AiToolRegistry _registry;
  final AiImageService _imageService;
  final AiContextBuilder _contextBuilder;

  /// 页面注入的批准回调；页面销毁后置空 → 所有写操作自动拒绝。
  AiToolApprovalHandler? _approvalHandler;

  set approvalHandler(AiToolApprovalHandler? handler) {
    _approvalHandler = handler;
  }

  // ── 状态 ──────────────────────────────────────────

  AiChatSession? _session;
  AiChatSession? get session => _session;

  final List<AiChatMessage> _messages = [];
  List<AiChatMessage> get messages => List.unmodifiable(_messages);

  AiChatStreamState _state = AiChatStreamState.idle;
  AiChatStreamState get state => _state;

  String _streamingText = '';
  String get streamingText => _streamingText;

  String _streamingReasoning = '';
  String get streamingReasoning => _streamingReasoning;

  final List<AiToolCallRecord> _activeToolCalls = [];
  List<AiToolCallRecord> get activeToolCalls =>
      List.unmodifiable(_activeToolCalls);

  String? _error;
  String? get error => _error;

  /// 图片降级提示（原图不可用、实际只发了缩略图）。
  String? _imageWarning;
  String? get imageWarning => _imageWarning;

  bool get isBusy => _state != AiChatStreamState.idle;

  /// 本会话内「总是允许」的工具名（内存，不落库）。
  final Set<String> _sessionApprovedTools = {};

  /// 每条 user 消息对应的上下文快照（messageId → 注入文本）。
  ///
  /// 冻结在首次注入时刻，保证同一会话里历史前缀逐字不变 → 缓存可命中。
  final Map<String, String> _contextNotes = {};

  /// 上一次已注入过的运行环境 / 时间原值。
  ///
  /// 只有内容真的变化时才重新注入：runtime 在会话内基本恒定，
  /// 每轮重发纯属浪费 token；时间按分钟粒度比较，同一分钟内不重复。
  String? _lastRuntimeSnapshot;
  String? _lastTimeSnapshot;

  CancelToken? _cancelToken;

  // ── 会话切换 ──────────────────────────────────────

  /// 加载会话的消息（切 Tab / 重启后恢复）。
  Future<void> openSession(AiChatSession session) async {
    _session = session;
    _messages
      ..clear()
      ..addAll(await _chatService.loadMessages(session.id));
    _error = null;
    _resetStreamBuffers();
    notifyListeners();
  }

  /// 新建一个空会话并打开它。
  Future<AiChatSession> createSession() async {
    final session = await _chatService.createSession();
    await openSession(session);
    return session;
  }

  /// 删除当前会话并清空视图。
  ///
  /// 同时清理本机原图文件（跨设备同步过来的消息本来就没有原图）。
  Future<void> deleteSession(String id) async {
    cancel();
    if (_session?.id == id) {
      await _imageService.deleteLocalFiles(
        _messages.expand((m) => m.attachments),
      );
    }
    await _chatService.deleteSession(id);
    if (_session?.id == id) {
      _session = null;
      _messages.clear();
      notifyListeners();
    }
  }

  /// 清空当前会话的消息。
  Future<void> clearCurrentSession() async {
    final session = _session;
    if (session == null) return;
    cancel();
    await _chatService.clearSessionMessages(session.id);
    _messages.clear();
    notifyListeners();
  }

  // ── 发送 ──────────────────────────────────────────

  /// 发送一条用户消息，并驱动完整的流式 + 工具调用循环。
  /// 发送一条用户消息（可附带图片）。
  Future<void> send(
    String userText, {
    List<AiChatAttachment> attachments = const [],
  }) async {
    final text = userText.trim();
    if (text.isEmpty && attachments.isEmpty) return;
    if (isBusy) return;

    final session = _session ?? await createSession();
    _error = null;
    _imageWarning = null;

    final userMessage = await _persist(
      AiChatMessage.create(
        sessionId: session.id,
        role: AiChatRole.user,
        content: text,
        attachments: attachments,
      ),
    );
    _messages.add(userMessage);

    // 首条用户消息顺带命名会话
    if (_messages.where((m) => m.role == AiChatRole.user).length == 1) {
      final title = AiChatService.suggestTitle(
        text.isEmpty ? (attachments.isEmpty ? '' : '图片对话') : text,
      );
      await _chatService.renameSession(session.id, title);
      _session = _session?.copyWith(title: title);
    }

    _notify();
    await _runConversation();
  }

  /// 重试最后一条失败/取消的消息。
  Future<void> retryLast() async {
    if (isBusy) return;
    final hasUser = _messages.any((m) => m.role == AiChatRole.user);
    if (!hasUser) return;

    // 删除尾部失败的 assistant 消息，避免重复堆积
    while (_messages.isNotEmpty &&
        _messages.last.role != AiChatRole.user &&
        _messages.last.role != AiChatRole.tool) {
      final removed = _messages.removeLast();
      await _chatService.deleteMessage(removed.id);
    }
    _error = null;
    _notify();
    await _runConversation();
  }

  /// 取消当前生成（保留已生成的部分内容）。
  void cancel() {
    _cancelToken?.cancel('用户取消');
    _cancelToken = null;
    if (_state != AiChatStreamState.idle) {
      _state = AiChatStreamState.idle;
      _notify();
    }
  }

  // ── 核心循环 ──────────────────────────────────────

  Future<void> _runConversation() async {
    final session = _session;
    if (session == null) return;

    final settings = _settings;
    final toolsEnabled = await settings.getToolsEnabled();
    final autoApprove = await settings.getAutoApproveReadOnly();
    final maxRounds = await settings.getMaxToolRounds();
    final maxMessages = await settings.getContextMessages();
    final baseSystemPrompt = await settings.getSystemPrompt();
    final temperature = await settings.getTemperatureOverride();
    final maxTokens = await settings.getMaxTokensOverride();

    final streamEnabled = await settings.getStreamEnabled();

    final profile = await _resolveProfile();
    if (profile == null) {
      await _failWith('请先在设置中配置可用的 AI 服务（OpenAI 兼容或 DeepSeek）');
      return;
    }

    final enabledNames = toolsEnabled
        ? await settings.enabledToolNames(_registry.all.map((t) => t.name))
        : <String>{};
    final openAiTools = toolsEnabled
        ? _registry.openAiTools(enabledNames: enabledNames)
        : const <Map<String, dynamic>>[];

    final policy = AiToolApprovalPolicy(
      autoApproveReadOnly: autoApprove,
      handler: _approvalHandler,
      alwaysAllowed: _sessionApprovedTools,
    );

    final injectRuntime = await settings.getInjectRuntimeContext();
    final injectTime = await settings.getInjectTimeContext();

    // system 提示词必须稳定：任何每轮变化的内容都不能塞进来，
    // 否则整个前缀缓存失效（DeepSeek 上下文缓存按前缀命中）。
    final systemPrompt = baseSystemPrompt;

    // 关闭流式输出时走一次性请求，且不启用工具调用
    if (!streamEnabled) {
      await _runSingleShot(
        profile: profile,
        maxMessages: maxMessages,
        systemPrompt: systemPrompt,
        temperatureOverride: temperature,
        maxTokensOverride: maxTokens,
        injectRuntime: injectRuntime,
        injectTime: injectTime,
      );
      return;
    }

    var round = 0;
    while (true) {
      final requestMessages = await injectContext(
        trimContext(
          await _withImagePayload(
            _messages,
            visionEnabled: profile.enableVision,
          ),
          maxMessages,
          system: systemPrompt,
        ),
        injectRuntime: injectRuntime,
        injectTime: injectTime,
      );
      _logImagePayload(requestMessages);
      final result = await _streamOnce(
        profile: profile,
        messages: requestMessages,
        tools: openAiTools,
        temperatureOverride: temperature,
        maxTokensOverride: maxTokens,
      );

      if (result == null) return; // 出错或已取消

      final calls = result.toolCalls;
      if (calls.isEmpty) {
        await _finishAssistant(
          sessionId: session.id,
          content: result.text,
          reasoning: result.reasoning,
        );
        return;
      }

      // 模型请求调用工具：先落 assistant（含 tool_calls），再逐个批准执行
      final assistant = await _persist(
        AiChatMessage.create(
          sessionId: session.id,
          role: AiChatRole.assistant,
          content: result.text,
          reasoning: result.reasoning.isEmpty ? null : result.reasoning,
          toolCalls: calls,
        ),
      );
      _messages.add(assistant);
      _notify();

      round += 1;
      if (round > maxRounds) {
        await _appendSystemNotice(
          session.id,
          '已达到工具调用轮数上限（$maxRounds 轮），本轮停止继续调用工具。',
        );
        return;
      }

      for (final call in calls) {
        final tool = _registry.lookup(call.name);
        if (tool == null) {
          final denial = AiToolResult.failure(
            'unknown_tool',
            '工具 "${call.name}" 不存在。',
          );
          await _recordToolResult(session.id, call, denial);
          continue;
        }

        // 工具被用户关停 → 直接以 disabled 回灌，不打扰也不执行
        if (!enabledNames.contains(tool.name)) {
          await _recordToolResult(
            session.id,
            call,
            AiToolResult.failure(
              'tool_disabled',
              '用户已在设置中关闭工具 "${tool.name}"，本次不执行。',
            ),
          );
          continue;
        }

        _state = AiChatStreamState.awaitingApproval;
        _notify();

        final approved = await policy.ensureApproved(call, tool);
        if (!approved) {
          await _recordToolResult(
            session.id,
            call,
            AiToolResult.failure('denied_by_user', '用户拒绝执行该操作。'),
          );
          continue;
        }

        if (policy.alwaysAllowedTools.contains(tool.name)) {
          _sessionApprovedTools.add(tool.name);
        }

        _state = AiChatStreamState.waitingTool;
        _notify();
        final result = await _registry.execute(call);
        await _recordToolResult(session.id, call, result);
      }

      if (_cancelToken?.isCancelled ?? false) return;
    }
  }

  /// 非流式一次性请求（设置里关闭流式时使用，不启用工具）。
  Future<void> _runSingleShot({
    required AiProfile profile,
    required int maxMessages,
    required String systemPrompt,
    required double? temperatureOverride,
    required int? maxTokensOverride,
    required bool injectRuntime,
    required bool injectTime,
  }) async {
    final session = _session;
    if (session == null) return;

    _state = AiChatStreamState.streaming;
    _notify();

    final token = CancelToken();
    _cancelToken = token;
    try {
      final content = await _aiService.chatOnce(
        messages: await injectContext(
          trimContext(
            await _withImagePayload(
              _messages,
              visionEnabled: profile.enableVision,
            ),
            maxMessages,
            system: systemPrompt,
          ),
          injectRuntime: injectRuntime,
          injectTime: injectTime,
        ),
        profile: profile,
        temperatureOverride: temperatureOverride,
        maxTokensOverride: maxTokensOverride,
        cancelToken: token,
      );
      final saved = await _persist(
        AiChatMessage.create(
          sessionId: session.id,
          role: AiChatRole.assistant,
          content: content,
          status: AiChatMessageStatus.complete,
        ),
      );
      _messages.add(saved);
    } catch (e) {
      final message = e is AiServiceException ? e.message : e.toString();
      _error = message;
      final cancelled = token.isCancelled;
      final saved = await _persist(
        AiChatMessage.create(
          sessionId: session.id,
          role: AiChatRole.assistant,
          content: '',
          status: cancelled
              ? AiChatMessageStatus.cancelled
              : AiChatMessageStatus.error,
          errorMessage: cancelled ? null : message,
        ),
      );
      _messages.add(saved);
    } finally {
      if (identical(_cancelToken, token)) _cancelToken = null;
      _state = AiChatStreamState.idle;
      _notify();
    }
  }

  /// 给需要发送的 user 消息注入图片 data URL（按设置形态）。
  ///
  /// 原图丢失（跨设备同步后）或解码失败时自动跳过该图，不阻断请求。
  Future<List<AiChatMessage>> _withImagePayload(
    List<AiChatMessage> messages, {
    required bool visionEnabled,
  }) async {
    // 配置未声明支持图片时一律不发送图片，只保留文本（附件元数据仍然可见）
    if (!visionEnabled) return messages;

    final mode = await _settings.getImageSendMode();

    // 只有最近一条带图消息需要重发图片：历史轮次保留附件元数据（UI 可展示）
    // 但不再消耗图片 token。
    var lastWithImage = -1;
    for (var i = messages.length - 1; i >= 0; i--) {
      if (messages[i].hasAttachments) {
        lastWithImage = i;
        break;
      }
    }

    final result = <AiChatMessage>[];
    for (var i = 0; i < messages.length; i++) {
      final message = messages[i];
      if (i != lastWithImage) {
        // 历史图片只保留元数据与缩略图，不发 data URL
        result.add(message);
        continue;
      }
      final prepared = await _imageService.prepareForSend(
        message.attachments,
        mode,
      );
      if (prepared.hasDegradation) {
        // 只有真的一路退到缩略图才需要警告；压缩图仍然清晰，不必打扰用户
        final actual = prepared.attachments.firstWhere(
          (a) => a.sentWidth > 0,
          orElse: () => prepared.attachments.first,
        );
        final onlyThumbnail =
            actual.sentWidth <= AiChatAttachment.thumbSizeLarge &&
            actual.sentHeight <= AiChatAttachment.thumbSizeLarge;
        if (onlyThumbnail) {
          _imageWarning =
              '本机原图已不可用，${prepared.degradedFileNames.length} 张图片只能按 '
              '${actual.sentWidth}px 缩略图发送，模型很可能看不清内容。'
              '请重新添加图片后再发送。';
          logWarning('AiChatController', _imageWarning!);
        }
      }
      result.add(message.copyWith(attachments: prepared.attachments));
    }
    return result;
  }

  /// 按需注入上下文：**只在内容发生变化时**才追加，且不改动 system 提示词。

  /// 两个原因：
  /// 1. system 提示词必须逐字稳定。改动它会让整段前缀缓存失效
  ///    （DeepSeek 的上下文缓存按前缀命中）；
  /// 2. 若把注入内容混进历史轮次的 system 里，模型回头看自己早先的回答
  ///    会发现「当时的系统提示词」和现在不同，容易开始自我质疑、质量下降。

  /// 放在最后一条 user 消息里，历史前缀逐字不变，且明确标注这不是用户说的话。
  ///
  /// 两个原因：
  /// 1. system 提示词必须逐字稳定。改动它会让整段前缀缓存失效
  ///    （DeepSeek 的上下文缓存按前缀命中）；
  /// 2. 若把注入内容混进历史轮次的 system 里，模型回头看自己早先的回答
  ///    会发现「当时的系统提示词」和现在不同，容易开始自我质疑、质量下降。
  ///
  /// 放在最后一条 user 消息里，历史前缀逐字不变，且明确标注这不是用户说的话。
  @visibleForTesting
  Future<List<Map<String, dynamic>>> injectContext(
    List<Map<String, dynamic>> messages, {
    required bool injectRuntime,
    required bool injectTime,
  }) async {
    if (!injectRuntime && !injectTime) return messages;
    if (messages.isEmpty) return messages;

    // 只拼「发生了变化」的块：runtime 恒定就不重复占位，
    // 时间同一分钟内也不重复。
    final blocks = <String>[];
    if (injectRuntime) {
      final runtime = await _contextBuilder.buildRuntimeContext();
      if (runtime.trim().isNotEmpty && runtime != _lastRuntimeSnapshot) {
        _lastRuntimeSnapshot = runtime;
        blocks.add(AiContextBuilder.wrapBlock('runtime-context', runtime));
      }
    }
    if (injectTime) {
      final time = _contextBuilder.buildTimeContext();
      if (time != _lastTimeSnapshot) {
        _lastTimeSnapshot = time;
        blocks.add(AiContextBuilder.wrapBlock('time-context', time));
      }
    }
    final extra = blocks.join('\n\n');
    // 本轮没有变化：不追加任何内容（历史快照仍然随请求重发）
    final hasFresh = extra.trim().isNotEmpty;

    // 只在最后一条 user 消息上追加；没有 user 消息就原样返回
    var index = -1;
    for (var i = messages.length - 1; i >= 0; i--) {
      if (messages[i]['role'] == 'user') {
        index = i;
        break;
      }
    }
    if (index < 0) return messages;

    // 本轮有变化才生成新快照；否则最新这条 user 消息不挂上下文
    final fresh = hasFresh ? _wrapContext(extra) : null;

    // 关键：历史轮次的上下文必须逐字冻结，否则前缀缓存每轮都会失效。
    // 这里按「紧随其后的那条 user 消息」配对，已记录的沿用它，
    // 只有最新的那条 user 消息才可能拿到新算出来的内容。
    final lastUserId = _messageIdOf(messages[index]);

    final result = <Map<String, dynamic>>[];
    for (var i = 0; i < messages.length; i++) {
      final message = messages[i];
      result.add(message);

      // 只给 user 消息挂上下文；assistant/tool 后面不插
      if (message['role'] != 'user') continue;

      final id = _messageIdOf(message);
      String? note;
      if (i == index) {
        note = fresh;
        if (id != null && fresh != null) _contextNotes[id] = fresh;
      } else if (id != null) {
        note = _contextNotes[id];
      }
      if (note == null) continue;

      // 独立成一条消息：绝不改写用户内容，也不改 system 提示词
      result.add({'role': 'user', 'content': note});
    }

    // 没有任何 user 消息时把上下文放在最后，避免丢失
    if (result.length == messages.length && lastUserId == null && fresh != null) {
      result.add({'role': 'user', 'content': fresh});
    }
    return result;
  }

  /// 某条 user 消息在请求时冻结的上下文（用于 UI 展示）。
  ///
  /// 返回 null 表示这条消息没有注入过上下文。
  String? contextNoteFor(String messageId) => _contextNotes[messageId];

  /// 从上下文文本里解析出注入分块的名字（runtime-context / time-context）。
  static List<String> contextTagsOf(String note) {
    final tags = <String>[];
    for (final match in RegExp(r'<([a-z-]+-context)>').allMatches(note)) {
      final tag = match.group(1)!;
      if (!tags.contains(tag)) tags.add(tag);
    }
    return tags;
  }

  /// 把上下文包成一条自我说明的消息体。
  String _wrapContext(String extra) {
    return [
      '<context-note>',
      '以下是系统自动注入的上下文，**不是用户输入的内容，也不是对上一个问题的追问**。',
      '它每轮可能更新，请不要据此推断用户改变过话题，也不要因此质疑你之前的回答。',
      '',
      extra,
      '</context-note>',
    ].join('\n');
  }

  /// 取消息的稳定 id（用于冻结上下文）。
  String? _messageIdOf(Map<String, dynamic> message) {
    final id = message['_message_id'];
    return id is String && id.isNotEmpty ? id : null;
  }

  /// 记录本轮请求携带的图片张数与**实际像素尺寸**。
  ///
  /// 排查「截图很清晰但模型说看不清」时，这条日志是唯一可靠的依据：
  /// 若显示 32x32，说明发的是缩略图而不是原图。
  void _logImagePayload(List<Map<String, dynamic>> messages) {
    if (messages.isEmpty) return;
    var images = 0;
    final details = <String>[];
    for (final message in messages) {
      final content = message['content'];
      if (content is! List) continue;
      for (final part in content) {
        if (part is! Map || part['type'] != 'image_url') continue;
        images += 1;
        final extra = part['image_size'];
        details.add(extra is Map ? '${extra['w']}x${extra['h']}' : '未知尺寸');
      }
    }
    if (images == 0) {
      logInfo('AiChatController', '本轮请求未携带图片');
      return;
    }
    logInfo(
      'AiChatController',
      '本轮请求携带图片 $images 张，实际尺寸: ${details.join(', ')}',
    );
  }

  /// 单轮流式请求；返回 null 表示本轮失败或已被取消。
  Future<_RoundResult?> _streamOnce({
    required AiProfile profile,
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
    required double? temperatureOverride,
    required int? maxTokensOverride,
  }) async {
    _resetStreamBuffers();
    _state = AiChatStreamState.streaming;
    _notify();

    final token = CancelToken();
    _cancelToken = token;

    final text = StringBuffer();
    final reasoning = StringBuffer();
    var toolCalls = const <AiToolCall>[];
    String? failure;

    try {
      final stream = _aiService.chatStreamEvents(
        messages: messages,
        profile: profile,
        tools: tools.isEmpty ? null : tools,
        temperatureOverride: temperatureOverride,
        maxTokensOverride: maxTokensOverride,
        cancelToken: token,
      );
      await for (final event in stream) {
        switch (event) {
          case ChatTextDelta(text: final delta):
            text.write(delta);
            _streamingText = text.toString();
            _notify();
          case ChatReasoningDelta(text: final delta):
            reasoning.write(delta);
            _streamingReasoning = reasoning.toString();
            _notify();
          case ChatToolCallsCompleted(calls: final calls):
            toolCalls = calls;
          case ChatDone():
            break;
          case ChatError(error: final err):
            failure = err.message;
        }
      }
    } on DioException catch (e) {
      failure = e.message ?? '网络请求失败';
    } catch (e) {
      failure = e.toString();
    } finally {
      if (identical(_cancelToken, token)) _cancelToken = null;
    }

    if (failure != null) {
      _state = AiChatStreamState.idle;
      final cancelled = token.isCancelled;
      if (cancelled) {
        // 取消：保留已生成的正文，状态标 cancelled
        final session = _session;
        if (session != null && text.isNotEmpty) {
          await _persist(
            AiChatMessage.create(
              sessionId: session.id,
              role: AiChatRole.assistant,
              content: text.toString(),
              reasoning: reasoning.isEmpty ? null : reasoning.toString(),
              status: AiChatMessageStatus.cancelled,
            ),
          );
        }
        _resetStreamBuffers();
        _notify();
        return null;
      }
      _error = failure;
      final failed = await _persist(
        AiChatMessage.create(
          sessionId: _session?.id ?? '',
          role: AiChatRole.assistant,
          content: text.toString(),
          reasoning: reasoning.isEmpty ? null : reasoning.toString(),
          status: AiChatMessageStatus.error,
          errorMessage: failure,
        ),
      );
      _messages.add(failed);
      _resetStreamBuffers();
      _notify();
      return null;
    }

    _state = AiChatStreamState.idle;
    return _RoundResult(
      text: text.toString(),
      reasoning: reasoning.toString(),
      toolCalls: toolCalls,
    );
  }

  // ── 内部工具 ──────────────────────────────────────

  Future<AiProfile?> _resolveProfile() async {
    await _profileService.load();
    final id = await _settings.getProfileId();
    final profile = id == null
        ? _profileService.defaultProfile
        : _profileService.getProfile(id);
    if (profile == null) return null;
    if (profile.isAquamarina) return null;
    if (profile.apiKey.isEmpty) return null;
    _aiService.setCurrentProfile(profile);
    return profile;
  }

  Future<void> _finishAssistant({
    required String sessionId,
    required String content,
    required String reasoning,
  }) async {
    if (content.isEmpty && reasoning.isEmpty) {
      _resetStreamBuffers();
      _state = AiChatStreamState.idle;
      _notify();
      return;
    }
    final saved = await _persist(
      AiChatMessage.create(
        sessionId: sessionId,
        role: AiChatRole.assistant,
        content: content,
        reasoning: reasoning.isEmpty ? null : reasoning,
      ),
    );
    _messages.add(saved);
    _resetStreamBuffers();
    _state = AiChatStreamState.idle;
    _notify();
  }

  Future<void> _recordToolResult(
    String sessionId,
    AiToolCall call,
    AiToolResult result,
  ) async {
    final saved = await _persist(
      AiChatMessage.create(
        sessionId: sessionId,
        role: AiChatRole.tool,
        content: result.content,
        toolCallId: call.id,
        toolName: call.name,
        status: result.ok
            ? AiChatMessageStatus.complete
            : AiChatMessageStatus.error,
        errorMessage: result.errorCode,
      ),
    );
    _messages.add(saved);

    _activeToolCalls.add(
      AiToolCallRecord(
        call: call,
        toolDescription: _registry.lookup(call.name)?.description ?? '',
        isMutating: _registry.lookup(call.name)?.isMutating ?? false,
        state: result.ok ? AiToolCallState.done : AiToolCallState.failed,
        resultPreview: result.content,
        errorCode: result.errorCode,
      ),
    );
    _notify();
  }

  Future<void> _appendSystemNotice(String sessionId, String text) async {
    final saved = await _persist(
      AiChatMessage.create(
        sessionId: sessionId,
        role: AiChatRole.tool,
        content: text,
        toolName: 'system',
      ),
    );
    _messages.add(saved);
    _state = AiChatStreamState.idle;
    _notify();
  }

  Future<void> _failWith(String message) async {
    _error = message;
    _state = AiChatStreamState.idle;
    _notify();
  }

  Future<AiChatMessage> _persist(AiChatMessage message) async {
    final saved = await _chatService.appendMessage(message);
    return saved ?? message;
  }

  void _resetStreamBuffers() {
    _streamingText = '';
    _streamingReasoning = '';
    _activeToolCalls.clear();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _cancelToken?.cancel('页面已关闭');
    _cancelToken = null;
    super.dispose();
  }

  // ── 上下文裁剪 ────────────────────────────────────

  /// 按条数裁剪上下文，并保证 assistant(tool_calls) 与其 tool 结果不被拆散。
  ///
  /// 规则：
  /// 1. system 提示词总是放在最前面（单独参数传入）；
  /// 2. 保留最近 [maxMessages] 条；
  /// 3. 若裁剪边界落在某个工具调用组中间，则整体前移到该组之前。
  @visibleForTesting
  static List<Map<String, dynamic>> trimContext(
    List<AiChatMessage> all,
    int maxMessages, {
    String? system,
  }) {
    final result = <Map<String, dynamic>>[];
    if (system != null && system.trim().isNotEmpty) {
      result.add({'role': 'system', 'content': system.trim()});
    }

    // 只保留有内容的、非运行期的消息
    final usable = all
        .where((m) => m.role != AiChatRole.system)
        .where((m) => m.status != AiChatMessageStatus.pending)
        .toList(growable: false);

    final limit = maxMessages <= 0 ? usable.length : maxMessages;
    var start = usable.length > limit ? usable.length - limit : 0;

    // 边界落在 tool 消息上时，向前回退到其 assistant(tool_calls) 之前
    while (start > 0 && usable[start].role == AiChatRole.tool) {
      start -= 1;
    }
    // 边界落在 assistant(tool_calls) 上时，同样回退，避免只带工具声明不带结果
    while (start > 0 &&
        usable[start].role == AiChatRole.assistant &&
        usable[start].hasToolCalls) {
      start -= 1;
    }

    // 保留窗口内的消息，再剔除「工具调用组不完整」的片段：
    // 只要 assistant(tool_calls) 的所有调用没有一一对应的 tool 结果
    // （例如执行到一半 App 被杀、或整组被裁断），DeepSeek 会直接 400，
    // 因此这里按组丢弃，而不是把残缺的协议发给服务端。
    final selected = usable.sublist(start);
    result.addAll(dropIncompleteToolGroups(selected)
        .map((message) => message.toOpenAiMessage()));

    return result;
  }

  /// 丢弃「工具调用组不完整」的消息。
  ///
  /// 规则：assistant(tool_calls) 之后必须紧跟覆盖全部 id 的 tool 消息。
  /// 缺任意一条（例如执行到一半 App 被杀、或整组被裁断）就整组丢弃，
  /// 否则 OpenAI / DeepSeek 都会以 400 拒绝整个请求。
  @visibleForTesting
  static List<AiChatMessage> dropIncompleteToolGroups(
    List<AiChatMessage> messages,
  ) {
    final result = <AiChatMessage>[];
    var i = 0;
    while (i < messages.length) {
      final message = messages[i];
      if (message.role == AiChatRole.tool) {
        // 孤立的 tool 结果（父调用被裁掉或已丢弃）：跳过，避免 400
        i += 1;
        continue;
      }
      if (message.role != AiChatRole.assistant || !message.hasToolCalls) {
        result.add(message);
        i += 1;
        continue;
      }

      final pending = message.toolCalls.map((c) => c.id).toSet();
      final replies = <AiChatMessage>[];
      var j = i + 1;
      var consistent = true;
      while (j < messages.length && messages[j].role == AiChatRole.tool) {
        final id = messages[j].toolCallId;
        if (id == null || !pending.remove(id)) consistent = false;
        replies.add(messages[j]);
        j += 1;
      }

      if (consistent && pending.isEmpty) {
        result.add(message);
        result.addAll(replies);
      } else {
        logInfo(
          'AiChatController',
          '丢弃不完整的工具调用组：缺 ${pending.length} 条工具结果',
        );
      }
      i = j;
    }
    return result;
  }
}

/// 单轮流式请求的聚合结果。
class _RoundResult {
  final String text;
  final String reasoning;
  final List<AiToolCall> toolCalls;

  const _RoundResult({
    required this.text,
    required this.reasoning,
    required this.toolCalls,
  });
}
