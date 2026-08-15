import 'dart:convert';
import 'dart:async';
import 'package:dio/dio.dart';
import '../models/ai_profile.dart';

/// OpenAI 兼容 API 聊天请求的封装
class AiService {
  final Dio _dio;

  /// Aquamarina 服务的内置公共 API Key
  static const String _aquamarinaApiKey = 'aquamarinapublicapi';

  AiService({Dio? dio}) : _dio = dio ?? Dio();

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
    final body = <String, dynamic>{
      'model': profile.model,
      'messages': messages,
      'max_tokens': profile.maxTokens,
      'stream': stream,
    };

    // DeepSeek 思考模式：不支持 temperature、top_p 等参数
    if (profile.isDeepSeek && profile.enableThinking) {
      body['thinking'] = {'type': 'enabled'};
      if (profile.reasoningEffort != null) {
        body['reasoning_effort'] = profile.reasoningEffort;
      }
    } else if (profile.isDeepSeek && !profile.enableThinking) {
      // 显式关闭思考模式，避免服务端默认启用
      body['thinking'] = {'type': 'disabled'};
      if (profile.temperature != null) {
        body['temperature'] = profile.temperature;
      }
    } else if (profile.temperature != null) {
      body['temperature'] = profile.temperature;
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
  }) async {
    final cfg = profile ?? _currentProfile;
    if (cfg == null || cfg.apiKey.isEmpty) {
      throw AiServiceException('请先在设置中配置 API Key');
    }

    final (headers, url) = _buildRequest(cfg);

    try {
      final response = await _dio.post(
        url,
        options: Options(headers: headers),
        data: _buildBody(profile: cfg, messages: messages, stream: false),
        cancelToken: cancelToken,
      );

      if (response.statusCode == 200) {
        final data = response.data as Map<String, dynamic>;
        final choices = data['choices'] as List<dynamic>;
        if (choices.isNotEmpty) {
          final message = choices[0]['message'] as Map<String, dynamic>;
          return message['content'] as String? ?? '';
        }
        return '';
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

  /// 流式聊天请求，返回字符串流
  /// 对于 DeepSeek 思考模式，会自动提取 reasoning_content 中的思维链内容
  Stream<String> chatStream({
    required List<Map<String, String>> messages,
    AiProfile? profile,
    bool includeReasoningContent = true,
  }) {
    final cfg = profile ?? _currentProfile;
    if (cfg == null || cfg.apiKey.isEmpty) {
      throw AiServiceException('请先在设置中配置 API Key');
    }

    final (headers, url) = _buildRequest(cfg);

    // 使用 StreamController 将 Dio 流式响应转为字符串流
    final controller = StreamController<String>();

    _dio
        .post(
          url,
          options: Options(headers: headers, responseType: ResponseType.stream),
          data: _buildBody(profile: cfg, messages: messages, stream: true),
        )
        .then((response) async {
          final responseStream = response.data as ResponseBody;
          String buffer = '';

          await for (final chunk in responseStream.stream) {
            buffer += utf8.decode(chunk.toList());

            // 解析 SSE 格式：data: {...}\n\n
            while (buffer.contains('\n')) {
              final lineEnd = buffer.indexOf('\n');
              final line = buffer.substring(0, lineEnd).trim();
              buffer = buffer.substring(lineEnd + 1);

              if (line.isEmpty || line.startsWith(':')) continue;

              if (line == 'data: [DONE]') {
                await controller.close();
                return;
              }

              if (line.startsWith('data: ')) {
                try {
                  final jsonStr = line.substring(6);
                  final data = jsonDecode(jsonStr) as Map<String, dynamic>;
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
          if (!controller.isClosed) {
            await controller.close();
          }
        })
        .catchError((error) {
          if (!controller.isClosed) {
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

  AiProfile? _currentProfile;

  /// 设置当前使用的配置文件
  void setCurrentProfile(AiProfile profile) {
    _currentProfile = profile;
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

class AiServiceException implements Exception {
  final String message;
  final String? type;

  AiServiceException(this.message, {this.type});

  bool get isRateLimit => type == 'rateLimit';

  @override
  String toString() => message;
}
