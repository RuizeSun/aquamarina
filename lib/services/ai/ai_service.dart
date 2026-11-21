import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import '../../models/ai_chat.dart';
import '../../models/ai_profile.dart';
import 'ai_usage_service.dart';
import '../system/log_service.dart';

/// OpenAI 兼容 API 聊天请求的封装
class AiService {
  final Dio _dio;

  /// Aquamarina 服务的内置公共 API Key
  static const String _aquamarinaApiKey = 'aquamarinapublicapi';

  AiService({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              // 必须在底层统一设置：chat / chatStream 都依赖默认配置。
              // 否则服务端只建立连接不返回数据时，UI 会永远停在「AI 正在批改」。
              connectTimeout: const Duration(seconds: 10),
              sendTimeout: const Duration(seconds: 60),
              receiveTimeout: const Duration(seconds: 120),
            ),
          );

  /// 构建请求头和 URL
  (Map<String, String>, String) _buildRequest(AiProfile profile) {
    final baseUrl = profile.baseUrl.replaceAll(RegExp(r'/+$'), '');
    final headers = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ${profile.apiKey}',
    };
    return (headers, '$baseUrl/chat/completions');
  }

  /// 构建请求 body（根据 profile 类型调整参数）
  Map<String, dynamic> _buildBody({
    required AiProfile profile,
    required List<Map<String, String>> messages,
    required bool stream,
  }) {
    return buildChatBody(
      profile: profile,
      messages: messages,
      stream: stream,
    );
  }

  /// 构建 OpenAI 兼容的 chat completions 请求体。
  ///
  /// 与 [chat] / [chatStream] 共用同一套参数分支（DeepSeek 思考模式、
  /// temperature 语义、流式 usage 开关），额外支持工具调用协议。
  /// Aquamarina 官方端点只提供句型批改，不支持通用对话，因此直接拒绝。
  Map<String, dynamic> buildChatBody({
    required AiProfile profile,
    required List<Map<String, dynamic>> messages,
    required bool stream,
    List<Map<String, dynamic>>? tools,
    String? toolChoice,
    double? temperatureOverride,
    int? maxTokensOverride,
  }) {
    if (profile.isAquamarina) {
      throw AiServiceException('Aquamarina 官方配置不支持通用对话，请切换到 OpenAI 兼容或 DeepSeek 配置');
    }

    // 清掉仅用于本地诊断的字段（image_size），避免污染服务端请求体
    final cleanMessages = _applyReasoningContent(
      messages.map(AiChatMessage.stripDiagnostics).toList(growable: false),
      profile: profile,
      hasTools: tools != null && tools.isNotEmpty,
    );

    final body = <String, dynamic>{
      'model': profile.model,
      'messages': cleanMessages,
      'max_tokens': maxTokensOverride ?? profile.maxTokens,
      'stream': stream,
    };

    final temperature = temperatureOverride ?? profile.temperature;

    // 流式请求显式要求服务端在最后一个分块返回 usage：
    // OpenAI 默认不返回，缺少 usage 就无法记录用量 / 学习预估偏差。
    if (stream) {
      body['stream_options'] = {'include_usage': true};
    }

    // 工具调用协议（仅 OpenAI 兼容 / DeepSeek 支持）。
    if (tools != null && tools.isNotEmpty) {
      body['tools'] = tools;
      body['tool_choice'] = toolChoice ?? 'auto';
    }

    // DeepSeek 思考模式：不支持 temperature、top_p 等参数
    if (profile.isDeepSeek && profile.enableThinking) {
      body['thinking'] = {'type': 'enabled'};
      if (profile.reasoningEffort != null) {
        body['reasoning_effort'] = profile.reasoningEffort;
      }
    } else if (profile.isDeepSeek && !profile.enableThinking) {
      // 显式关闭思考模式，避免服务端默认启用
      body['thinking'] = {'type': 'disabled'};
      if (temperature != null) {
        body['temperature'] = temperature;
      }
    } else if (temperature != null) {
      body['temperature'] = temperature;
    }

    return body;
  }

  /// 按厂商要求整理消息里的 `reasoning_content`。
  ///
  /// DeepSeek 思考模式 + tools 的规则（官方 thinking_mode 文档）：
  /// 只要请求带 `tools`，就必须把历史所有轮次的 reasoning_content 完整回传，
  /// 包括模型没发起工具调用的轮次；缺字段会被直接判 400。
  /// 其它情况（非 DeepSeek、未开思考模式、或没带 tools）一律剔除该字段，
  /// 避免 OpenAI 等严格校验的端点因未知字段报错。
  List<Map<String, dynamic>> _applyReasoningContent(
    List<Map<String, dynamic>> messages, {
    required AiProfile profile,
    required bool hasTools,
  }) {
    final keepReasoning = profile.isDeepSeek && profile.enableThinking;
    return messages.map((message) {
      final next = Map<String, dynamic>.from(message);
      if (!keepReasoning) {
        next.remove('reasoning_content');
        return next;
      }
      // 带 tools 时字段必须存在（即使是空串），否则历史里缺少思维链的
      // assistant 消息会让整个请求 400。
      if (hasTools &&
          next['role'] == 'assistant' &&
          next['reasoning_content'] is! String) {
        next['reasoning_content'] = '';
      }
      return next;
    }).toList(growable: false);
  }

  /// 调用 Aquamarina 官方 API（非标准 OpenAI 兼容）
  /// 返回从 data.content 中提取的原始 JSON 字符串
  Future<String> callAquamarinaSentence({
    required String mode,
    required Map<String, String> sentence,
    required String userAnswer,
    List<String>? shuffledWords,
    String? baseUrl,
    CancelToken? cancelToken,
  }) async {
    final url = '${baseUrl?.replaceAll(RegExp(r'/+$'), '')}/chat';
    logInfo('AiService', '调用 Aquamarina 句型 API mode=$mode');

    try {
      final body = <String, dynamic>{
        'mode': mode,
        'sentence': sentence,
        'userAnswer': userAnswer,
      };
      if (shuffledWords != null && shuffledWords.isNotEmpty) {
        body['shuffledWords'] = shuffledWords;
      }

      final response = await _dio.post(
        url,
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $_aquamarinaApiKey',
          },
          sendTimeout: const Duration(seconds: 30),
          receiveTimeout: const Duration(seconds: 60),
        ),
        data: body,
        cancelToken: cancelToken,
      );

      if (response.statusCode == 200) {
        final data = response.data as Map<String, dynamic>;
        if (data['success'] == true && data['data'] != null) {
          final innerData = data['data'] as Map<String, dynamic>;
          return innerData['content'] as String? ?? '';
        }
        throw AiServiceException('服务端返回失败：${data['error'] ?? '未知错误'}');
      } else {
        throw _mapError(response.statusCode, response.data);
      }
    } on DioException catch (e) {
      if (e.response != null) {
        throw _mapError(e.response?.statusCode, e.response?.data);
      }
      throw AiServiceException('网络请求失败：${e.message}');
    }
  }

  /// 非流式聊天请求
  Future<String> chat({
    required List<Map<String, String>> messages,
    AiProfile? profile,
    CancelToken? cancelToken,
    void Function(AiUsageSnapshot usage)? onUsage,
  }) async {
    final cfg = profile ?? _currentProfile;
    if (cfg == null || cfg.apiKey.isEmpty) {
      throw AiServiceException('请先在设置中配置 API Key');
    }

    final (headers, url) = _buildRequest(cfg);
    logInfo('AiService', '发起聊天请求 model=${cfg.model}');

    try {
      final response = await _dio.post(
        url,
        options: Options(headers: headers),
        data: _buildBody(profile: cfg, messages: messages, stream: false),
        cancelToken: cancelToken,
      );

      if (response.statusCode == 200) {
        final data = response.data as Map<String, dynamic>;
        // 记录用量（仅 OpenAI 兼容 / DeepSeek；Aquamarina 内部跳过）
        _recordUsage(
          cfg,
          AiUsageRequestMode.chat,
          data['usage'],
          onUsage: onUsage,
        );
        final choices = data['choices'] as List<dynamic>;
        if (choices.isNotEmpty) {
          final message = choices[0]['message'] as Map<String, dynamic>;
          final content = message['content'] as String? ?? '';
          logInfo('AiService', '聊天请求成功，响应长度: ${content.length}');
          return content;
        }
        return '';
      } else {
        logError('AiService', '聊天请求失败: HTTP ${response.statusCode}');
        throw _mapError(response.statusCode, response.data);
      }
    } on DioException catch (e) {
      logError('AiService', '聊天请求异常: ${e.message}');
      if (e.response != null) {
        throw _mapError(e.response?.statusCode, e.response?.data);
      }
      throw AiServiceException('网络请求失败：${e.message}');
    }
  }

  /// 流式聊天请求，返回字符串流
  /// 对于 DeepSeek 思考模式，会自动提取 reasoning_content 中的思维链内容
  Stream<String> chatStream({
    required List<Map<String, String>> messages,
    AiProfile? profile,
    bool includeReasoningContent = true,
    CancelToken? cancelToken,
    void Function(AiUsageSnapshot usage)? onUsage,
  }) {
    final cfg = profile ?? _currentProfile;
    if (cfg == null || cfg.apiKey.isEmpty) {
      throw AiServiceException('请先在设置中配置 API Key');
    }

    final (headers, url) = _buildRequest(cfg);
    logInfo('AiService', '发起流式聊天请求 model=${cfg.model}');

    // 使用 StreamController 将 Dio 流式响应转为字符串流
    final controller = StreamController<String>();

    _dio
        .post(
          url,
          options: Options(headers: headers, responseType: ResponseType.stream),
          data: _buildBody(profile: cfg, messages: messages, stream: true),
          cancelToken: cancelToken,
        )
        .then((response) async {
          final responseStream = response.data as ResponseBody;
          String buffer = '';
          dynamic usageMap; // 流式结束时携带的 usage（通常位于最后一个分块）
          var parseFailures = 0;
          var emitted = 0;
          var sawDone = false;

          /// 处理一整行 SSE 文本；返回 true 表示遇到提前收尾。
          bool handleLine(String rawLine) {
            final line = rawLine.trim();
            if (line.isEmpty || line.startsWith(':')) return false;

            if (line == 'data: [DONE]') {
              return true;
            }

            if (!line.startsWith('data: ')) return false;

            Map<String, dynamic> data;
            try {
              data = jsonDecode(line.substring(6)) as Map<String, dynamic>;
            } catch (_) {
              // 解析失败不再静默吞掉：计数后继续，流结束时若一个 token
              // 都没拿到就明确报错，避免用户看到空白回答。
              parseFailures += 1;
              return false;
            }

            // 捕获 usage（无论 choices 是否为空）
            if (data['usage'] is Map) {
              usageMap = data['usage'];
            }
            final choices = data['choices'] as List<dynamic>?;
            if (choices == null || choices.isEmpty) return false;

            final delta = choices[0]['delta'] as Map<String, dynamic>?;
            if (delta == null) return false;

            final content = delta['content'] as String?;
            if (content != null && content.isNotEmpty) {
              controller.add(content);
              emitted += 1;
            }
            // 提取 DeepSeek reasoning_content（思维链）
            final reasoningContent = delta['reasoning_content'] as String?;
            if (includeReasoningContent &&
                reasoningContent != null &&
                reasoningContent.isNotEmpty) {
              controller.add(reasoningContent);
              emitted += 1;
            }
            return false;
          }

          // 使用有状态的 utf8.decoder 转换流，正确处理跨 chunk 的
          // UTF-8 多字节字符拼接；allowMalformed 让代理插入的坏字节
          // 不再抛 FormatException 打断整条流。
          await for (final chunk
              in const Utf8Decoder(allowMalformed: true)
                  .bind(responseStream.stream)) {
            buffer += chunk;

            // 解析 SSE 格式：data: {...}\n\n
            while (buffer.contains('\n')) {
              final lineEnd = buffer.indexOf('\n');
              final line = buffer.substring(0, lineEnd);
              buffer = buffer.substring(lineEnd + 1);

              if (handleLine(line)) {
                sawDone = true;
                break;
              }
            }
            if (sawDone) break;
          }

          // 流结束时 buffer 里可能还残留最后一个分块（很多网关最后一条
          // data: 不带尾随换行）。不 flush 会丢掉最后几个 token 与 usage。
          if (!sawDone && buffer.trim().isNotEmpty) {
            handleLine(buffer);
          }

          _recordUsage(
            cfg,
            AiUsageRequestMode.stream,
            usageMap,
            onUsage: onUsage,
          );
          if (!controller.isClosed) {
            if (emitted == 0 && parseFailures > 0) {
              controller.addError(
                AiServiceException('响应格式异常：无法解析服务端返回的流式数据'),
              );
            }
            await controller.close();
          }
        })
        .catchError((error) async {
          if (!controller.isClosed) {
            logError('AiService', '流式请求异常: $error');
            if (error is DioException) {
              final body = await _readErrorBody(error.response?.data);
              logError(
                'AiService',
                '流式请求失败: HTTP ${error.response?.statusCode} $body',
              );
              controller.addError(
                _mapError(error.response?.statusCode, body),
              );
            } else {
              controller.addError(AiServiceException('请求失败：$error'));
            }
            await controller.close();
          }
        });

    return controller.stream;
  }

  /// 非流式对话（关闭流式输出时使用），不支持工具调用。
  Future<String> chatOnce({
    required List<Map<String, dynamic>> messages,
    AiProfile? profile,
    double? temperatureOverride,
    int? maxTokensOverride,
    CancelToken? cancelToken,
  }) async {
    final cfg = profile ?? _currentProfile;
    if (cfg == null || cfg.apiKey.isEmpty) {
      throw AiServiceException('请先在设置中配置 AI 服务与 API Key');
    }
    final (headers, url) = _buildRequest(cfg);
    final body = buildChatBody(
      profile: cfg,
      messages: messages,
      stream: false,
      temperatureOverride: temperatureOverride,
      maxTokensOverride: maxTokensOverride,
    );

    try {
      final response = await _dio.post(
        url,
        options: Options(headers: headers),
        data: body,
        cancelToken: cancelToken,
      );
      final data = response.data as Map<String, dynamic>;
      _recordUsage(cfg, AiUsageRequestMode.chat, data['usage']);
      final choices = data['choices'] as List<dynamic>?;
      if (choices == null || choices.isEmpty) return '';
      final message = choices.first['message'] as Map<String, dynamic>?;
      return (message?['content'] as String?) ?? '';
    } on DioException catch (e) {
      throw _mapError(e.response?.statusCode, e.response?.data);
    }
  }

  /// 流式对话（带工具调用协议），用于 AI 对话页。
  ///
  /// 与 [chatStream] 的区别：
  /// - 支持 `tools` / `tool_choice`；
  /// - 解析 `delta.tool_calls` 增量分片并按 index 累加，结束后一次性交付；
  /// - 以结构化事件输出正文、思维链、工具调用与结束原因。
  ///
  /// 请求参数错误（如官方配置、缺少 Key）以 [ChatError] 事件交付，不抛出。
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
    final cfg = profile ?? _currentProfile;
    final controller = StreamController<AiChatEvent>();

    Map<String, dynamic> body;
    try {
      if (cfg == null || cfg.apiKey.isEmpty) {
        throw AiServiceException('请先在设置中配置 AI 服务与 API Key');
      }
      body = buildChatBody(
        profile: cfg,
        messages: messages,
        stream: true,
        tools: tools,
        toolChoice: toolChoice,
        temperatureOverride: temperatureOverride,
        maxTokensOverride: maxTokensOverride,
      );
    } on AiServiceException catch (e) {
      controller.add(ChatError(e));
      controller.close();
      return controller.stream;
    }

    final (headers, url) = _buildRequest(cfg);
    logInfo('AiService', '发起对话流式请求 model=${cfg.model}');

    // 工具调用的增量累加器：index -> {id, name, arguments}
    final toolBuffers = <int, _ToolCallBuffer>{};
    var finishReason = 'stop';

    _dio
        .post(
          url,
          options: Options(headers: headers, responseType: ResponseType.stream),
          data: body,
          cancelToken: cancelToken,
        )
        .then((response) async {
          final responseStream = response.data as ResponseBody;
          String buffer = '';
          dynamic usageMap;
          var parseFailures = 0;
          var emitted = 0;
          var sawDone = false;

          /// 处理一整行 SSE 文本；返回 true 表示遇到需要收尾退出。
          bool handleLine(String rawLine) {
            final line = rawLine.trim();
            if (line.isEmpty || line.startsWith(':')) return false;

            if (line == 'data: [DONE]') {
              return true;
            }

            if (!line.startsWith('data: ')) return false;

            Map<String, dynamic> data;
            try {
              data = jsonDecode(line.substring(6)) as Map<String, dynamic>;
            } catch (_) {
              // 解析失败不再静默吞掉，流结束时统一判定是否属于格式异常。
              parseFailures += 1;
              return false;
            }

            if (data['usage'] is Map) {
              usageMap = data['usage'];
            }

            final choices = data['choices'] as List<dynamic>?;
            if (choices == null || choices.isEmpty) return false;

            final choice = choices.first;
            final reason = choice['finish_reason'] as String?;
            if (reason != null && reason.isNotEmpty) {
              finishReason = reason;
            }

            final delta = choice['delta'] as Map<String, dynamic>?;
            if (delta == null) return false;

            final content = delta['content'] as String?;
            if (content != null && content.isNotEmpty) {
              controller.add(ChatTextDelta(content));
              emitted += 1;
            }

            final reasoning = delta['reasoning_content'] as String?;
            if (reasoning != null && reasoning.isNotEmpty) {
              controller.add(ChatReasoningDelta(reasoning));
              emitted += 1;
            }

            final rawCalls = delta['tool_calls'] as List<dynamic>?;
            if (rawCalls != null) {
              for (final raw in rawCalls) {
                if (raw is! Map) continue;
                final index = (raw['index'] as num?)?.toInt() ?? 0;
                final acc = toolBuffers.putIfAbsent(
                  index,
                  () => _ToolCallBuffer(),
                );
                final id = raw['id'];
                if (id is String && id.isNotEmpty) {
                  acc.id = id;
                }
                final fn = raw['function'];
                if (fn is Map) {
                  final name = fn['name'];
                  if (name is String && name.isNotEmpty) {
                    acc.name = name;
                  }
                  final args = fn['arguments'];
                  if (args is String) {
                    acc.arguments.write(args);
                  } else if (args is Map) {
                    acc.arguments.write(jsonEncode(args));
                  }
                }
              }
            }
            return false;
          }

          // allowMalformed：代理插入的坏字节不应抛 FormatException 打断整条流。
          await for (final chunk
              in const Utf8Decoder(allowMalformed: true)
                  .bind(responseStream.stream)) {
            buffer += chunk;
            while (buffer.contains('\n')) {
              final lineEnd = buffer.indexOf('\n');
              final line = buffer.substring(0, lineEnd);
              buffer = buffer.substring(lineEnd + 1);
              if (handleLine(line)) {
                sawDone = true;
                break;
              }
            }
            if (sawDone) break;
          }

          // 流末尾残留的最后一条 data（无尾随换行）必须处理，否则会丢掉
          // 最后的 token 与 usage。
          if (!sawDone && buffer.trim().isNotEmpty) {
            handleLine(buffer);
          }

          // 流结束（服务端未发送 [DONE] 时的兜底）
          _emitToolCalls(controller, toolBuffers, finishReason);
          _recordUsage(
            cfg,
            AiUsageRequestMode.stream,
            usageMap,
            onUsage: onUsage,
          );
          if (!controller.isClosed) {
            if (emitted == 0 &&
                parseFailures > 0 &&
                toolBuffers.isEmpty) {
              controller.add(
                ChatError(
                  AiServiceException('响应格式异常：无法解析服务端返回的流式数据'),
                ),
              );
            }
            controller.add(ChatDone(finishReason));
            await controller.close();
          }
        })
        .catchError((error) async {
          if (controller.isClosed) return;
          if (error is DioException) {
            // 流式响应里 body 是未解码的 [ResponseBody]，
            // 这里先读出来，才能把服务端 400 的具体原因带进日志和 UI。
            final body = await _readErrorBody(error.response?.data);
            logError(
              'AiService',
              '对话流式请求异常: HTTP ${error.response?.statusCode} $body',
            );
            controller.add(
              ChatError(_mapError(error.response?.statusCode, body)),
            );
          } else {
            logError('AiService', '对话流式请求异常: $error');
            controller.add(ChatError(AiServiceException('请求失败：$error')));
          }
          await controller.close();
        });

    return controller.stream;
  }

  /// 把累加中的工具调用一次性交付给上层（仅当本轮流真的产生了工具调用）。
  void _emitToolCalls(
    StreamController<AiChatEvent> controller,
    Map<int, _ToolCallBuffer> buffers,
    String finishReason,
  ) {
    if (buffers.isEmpty || controller.isClosed) return;
    final indexes = buffers.keys.toList()..sort();
    final calls = <AiToolCall>[];
    for (final index in indexes) {
      final buffer = buffers[index]!;
      if (buffer.name.isEmpty) continue;
      calls.add(
        AiToolCall.parse(
          id: buffer.id.isEmpty ? 'call_${index}_${calls.length}' : buffer.id,
          name: buffer.name,
          rawArguments: buffer.arguments.toString(),
        ),
      );
    }
    if (calls.isEmpty) return;
    controller.add(ChatToolCallsCompleted(calls, finishReason));
  }

  AiProfile? _currentProfile;

  /// 设置当前使用的配置文件
  void setCurrentProfile(AiProfile profile) {
    _currentProfile = profile;
  }

  /// 解析 usage 并记录一次用量（异步、不阻塞主流程）。
  ///
  /// - Aquamarina 官方无 usage，直接跳过。
  /// - 兼容 OpenAI/DeepSeek 的 usage 字段与自定义缓存字段：
  ///   - DeepSeek：`prompt_cache_hit_tokens` / `prompt_cache_miss_tokens`
  ///   - OpenAI：`prompt_tokens_details.cached_tokens`，未命中 = 输入 - 命中
  ///   - 均无缓存信息时：整段输入视为「未命中缓存」。
  void _recordUsage(
    AiProfile profile,
    AiUsageRequestMode requestMode,
    dynamic usageData, {
    void Function(AiUsageSnapshot usage)? onUsage,
  }) {
    if (profile.isAquamarina) return;
    try {
      int numToInt(Map<dynamic, dynamic> map, String key) {
        final v = map[key];
        if (v is num) return v.toInt();
        if (v is double) return v.toInt();
        return 0;
      }

      int prompt = 0;
      int completion = 0;
      int total = 0;
      int cacheHit = 0;
      int cacheMiss = 0;

      if (usageData is Map<dynamic, dynamic>) {
        final usage = usageData;
        prompt = numToInt(usage, 'prompt_tokens');
        completion = numToInt(usage, 'completion_tokens');
        total = numToInt(usage, 'total_tokens');

        // DeepSeek 缓存命中/未命中自定义字段
        final deepHit = numToInt(usage, 'prompt_cache_hit_tokens');
        final deepMiss = numToInt(usage, 'prompt_cache_miss_tokens');

        // OpenAI 缓存明细
        int openaiCached = 0;
        bool hasOpenaiDetails = false;
        final details = usage['prompt_tokens_details'];
        if (details is Map<dynamic, dynamic>) {
          hasOpenaiDetails = details.containsKey('cached_tokens');
          openaiCached = numToInt(details, 'cached_tokens');
        }

        if (deepHit > 0 || deepMiss > 0) {
          cacheHit = deepHit;
          cacheMiss = deepMiss;
        } else if (hasOpenaiDetails) {
          cacheHit = openaiCached < 0 ? 0 : openaiCached;
          cacheMiss = prompt > cacheHit ? prompt - cacheHit : 0;
        } else {
          // 无缓存信息：整段输入视为未命中缓存
          cacheHit = 0;
          cacheMiss = prompt;
        }

        if (total <= 0) total = prompt + completion;

        // 把解析出的真实用量回传给上层（预估矫正等），无 usage 时不回调
        onUsage?.call(
          AiUsageSnapshot(
            promptTokens: prompt,
            cacheHitTokens: cacheHit,
            cacheMissTokens: cacheMiss,
            completionTokens: completion,
            totalTokens: total,
          ),
        );
      } else {
        // 无 usage：仍记录一次请求（tokens 记 0），保证请求数准确
      }

      unawaited(
        AiUsageService.instance.record(
          profile: profile,
          requestMode: requestMode,
          promptTokens: prompt,
          cacheHitTokens: cacheHit,
          cacheMissTokens: cacheMiss,
          completionTokens: completion,
          totalTokens: total,
        ),
      );
    } catch (e, stackTrace) {
      logError('AiService', '记录 AI usage 失败: $e', stackTrace);
    }
  }

  /// 尽力读取错误响应体。
  ///
  /// 流式请求（`responseType: stream`）失败时 Dio 给出的是未消费的
  /// [ResponseBody]，不读出来日志里就只有一句 "bad response"，看不到服务端
  /// 真正的 400 原因（例如缺少 reasoning_content）。
  Future<dynamic> _readErrorBody(dynamic data) async {
    if (data == null) return null;
    if (data is Map || data is String) {
      return data is String ? _decodeBodyText(data) : data;
    }
    if (data is! ResponseBody) return null;
    try {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in data.stream.timeout(
        const Duration(seconds: 3),
      )) {
        builder.add(chunk);
      }
      final text = utf8
          .decode(builder.takeBytes(), allowMalformed: true)
          .trim();
      if (text.isEmpty) return null;
      return _decodeBodyText(text);
    } catch (_) {
      return null;
    }
  }

  dynamic _decodeBodyText(String text) {
    try {
      return jsonDecode(text);
    } catch (_) {
      return text;
    }
  }

  AiServiceException _mapError(int? statusCode, dynamic data) {
    String? message;
    if (data is Map<String, dynamic>) {
      final error = data['error'];
      if (error is String) {
        message = error;
      } else if (error is Map<String, dynamic>) {
        message = error['message'] as String?;
      }
    }
    if (statusCode == null) {
      return AiServiceException(message ?? '请求失败');
    }
    switch (statusCode) {
      case 401:
      case 403:
        return AiServiceException('API Key 无效，请检查后重试');
      case 429:
        return AiServiceException(
          '请求过于频繁，请稍后重试${message != null ? '：$message' : ''}',
          type: 'rateLimit',
        );
      case 404:
        return AiServiceException('接口地址不存在，请检查 Base URL');
      case >= 500:
        return AiServiceException('服务端错误（HTTP $statusCode），请检查 Base URL');
      default:
        return AiServiceException(message ?? '请求失败（HTTP $statusCode）');
    }
  }
}

/// 对话流式请求的结构化事件。
sealed class AiChatEvent {
  const AiChatEvent();
}

/// 正文增量。
class ChatTextDelta extends AiChatEvent {
  final String text;
  const ChatTextDelta(this.text);
}

/// 思维链（DeepSeek reasoning_content）增量。
class ChatReasoningDelta extends AiChatEvent {
  final String text;
  const ChatReasoningDelta(this.text);
}

/// 本轮流式结束后交付的完整工具调用列表。
class ChatToolCallsCompleted extends AiChatEvent {
  final List<AiToolCall> calls;
  final String finishReason;
  const ChatToolCallsCompleted(this.calls, this.finishReason);
}

/// 流式结束（[finishReason] 为 stop / tool_calls / length 等）。
class ChatDone extends AiChatEvent {
  final String finishReason;
  const ChatDone(this.finishReason);
}

/// 请求失败，[error] 携带可直接展示的文案。
class ChatError extends AiChatEvent {
  final AiServiceException error;
  const ChatError(this.error);
}

/// 单次工具调用的增量累加缓冲。
class _ToolCallBuffer {
  String id = '';
  String name = '';
  final StringBuffer arguments = StringBuffer();
}

class AiServiceException implements Exception {
  final String message;
  final String? type;

  AiServiceException(this.message, {this.type});

  bool get isRateLimit => type == 'rateLimit';

  @override
  String toString() => message;
}
