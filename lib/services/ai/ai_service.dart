import 'dart:convert';
import 'dart:async';
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

    final body = <String, dynamic>{
      'model': profile.model,
      'messages': messages,
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

          // 使用有状态的 utf8.decoder 转换流，正确处理跨 chunk 的
          // UTF-8 多字节字符拼接，避免 chunk 边界截断导致 FormatException
          await for (final chunk in utf8.decoder.bind(responseStream.stream)) {
            buffer += chunk;

            // 解析 SSE 格式：data: {...}\n\n
            while (buffer.contains('\n')) {
              final lineEnd = buffer.indexOf('\n');
              final line = buffer.substring(0, lineEnd).trim();
              buffer = buffer.substring(lineEnd + 1);

              if (line.isEmpty || line.startsWith(':')) continue;

              if (line == 'data: [DONE]') {
                _recordUsage(
                  cfg,
                  AiUsageRequestMode.stream,
                  usageMap,
                  onUsage: onUsage,
                );
                await controller.close();
                return;
              }

              if (line.startsWith('data: ')) {
                try {
                  final jsonStr = line.substring(6);
                  final data = jsonDecode(jsonStr) as Map<String, dynamic>;
                  // 捕获 usage（无论 choices 是否为空）
                  if (data['usage'] is Map) {
                    usageMap = data['usage'];
                  }
                  final choices = data['choices'] as List<dynamic>?;
                  if (choices != null && choices.isNotEmpty) {
                    final delta = choices[0]['delta'] as Map<String, dynamic>?;
                    if (delta != null) {
                      // 提取 content
                      final content = delta['content'] as String?;
                      if (content != null && content.isNotEmpty) {
                        controller.add(content);
                      }
                      // 提取 DeepSeek reasoning_content（思维链）
                      final reasoningContent =
                          delta['reasoning_content'] as String?;
                      if (includeReasoningContent &&
                          reasoningContent != null &&
                          reasoningContent.isNotEmpty) {
                        controller.add(reasoningContent);
                      }
                    }
                  }
                } catch (_) {
                  // 忽略解析错误，继续处理下一行
                }
              }
            }
          }

          // 流结束
          _recordUsage(
            cfg,
            AiUsageRequestMode.stream,
            usageMap,
            onUsage: onUsage,
          );
          if (!controller.isClosed) {
            await controller.close();
          }
        })
        .catchError((error) {
          if (!controller.isClosed) {
            logError('AiService', '流式请求异常: $error');
            if (error is DioException) {
              controller.addError(
                _mapError(error.response?.statusCode, error.response?.data),
              );
            } else {
              controller.addError(AiServiceException('请求失败：$error'));
            }
            controller.close();
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

          await for (final chunk in utf8.decoder.bind(responseStream.stream)) {
            buffer += chunk;
            while (buffer.contains('\n')) {
              final lineEnd = buffer.indexOf('\n');
              final line = buffer.substring(0, lineEnd).trim();
              buffer = buffer.substring(lineEnd + 1);

              if (line.isEmpty || line.startsWith(':')) continue;

              if (line == 'data: [DONE]') {
                _emitToolCalls(controller, toolBuffers, finishReason);
                _recordUsage(
                  cfg,
                  AiUsageRequestMode.stream,
                  usageMap,
                  onUsage: onUsage,
                );
                if (!controller.isClosed) {
                  controller.add(ChatDone(finishReason));
                  await controller.close();
                }
                return;
              }

              if (!line.startsWith('data: ')) continue;

              Map<String, dynamic> data;
              try {
                data = jsonDecode(line.substring(6)) as Map<String, dynamic>;
              } catch (_) {
                // 忽略解析错误，继续处理下一行
                continue;
              }

              if (data['usage'] is Map) {
                usageMap = data['usage'];
              }

              final choices = data['choices'] as List<dynamic>?;
              if (choices == null || choices.isEmpty) continue;

              final choice = choices.first;
              final reason = choice['finish_reason'] as String?;
              if (reason != null && reason.isNotEmpty) {
                finishReason = reason;
              }

              final delta = choice['delta'] as Map<String, dynamic>?;
              if (delta == null) continue;

              final content = delta['content'] as String?;
              if (content != null && content.isNotEmpty) {
                controller.add(ChatTextDelta(content));
              }

              final reasoning = delta['reasoning_content'] as String?;
              if (reasoning != null && reasoning.isNotEmpty) {
                controller.add(ChatReasoningDelta(reasoning));
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
            }
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
            controller.add(ChatDone(finishReason));
            await controller.close();
          }
        })
        .catchError((error) {
          if (controller.isClosed) return;
          logError('AiService', '对话流式请求异常: $error');
          if (error is DioException) {
            controller.add(
              ChatError(_mapError(error.response?.statusCode, error.response?.data)),
            );
          } else {
            controller.add(ChatError(AiServiceException('请求失败：$error')));
          }
          controller.close();
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
