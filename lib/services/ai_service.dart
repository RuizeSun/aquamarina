import 'dart:convert';
import 'dart:async';
import 'package:dio/dio.dart';
import '../models/ai_config.dart';
import 'ai_config_service.dart';

/// OpenAI 兼容 API 聊天请求的封装
class AiService {
  final Dio _dio;

  AiService({Dio? dio}) : _dio = dio ?? Dio();

  /// 构建请求头和 URL
  (Map<String, String>, String) _buildRequest(AiConfig config) {
    final baseUrl = config.baseUrl.replaceAll(RegExp(r'/+$'), '');
    final headers = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ${config.apiKey}',
    };
    return (headers, '$baseUrl/chat/completions');
  }

  /// 构建请求 body
  Map<String, dynamic> _buildBody({
    required AiConfig config,
    required List<Map<String, String>> messages,
    required bool stream,
  }) {
    return {
      'model': config.model,
      'messages': messages,
      'temperature': config.temperature,
      'max_tokens': config.maxTokens,
      'stream': stream,
    };
  }

  /// 非流式聊天请求
  Future<String> chat({
    required List<Map<String, String>> messages,
    AiConfig? config,
  }) async {
    final cfg = config ?? _currentConfig;
    if (cfg == null || cfg.apiKey.isEmpty) {
      throw AiConfigException('请先在设置中配置 API Key');
    }

    final (headers, url) = _buildRequest(cfg);

    try {
      final response = await _dio.post(
        url,
        options: Options(headers: headers),
        data: _buildBody(config: cfg, messages: messages, stream: false),
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
      throw AiConfigException('网络请求失败：${e.message}');
    }
  }

  /// 流式聊天请求，返回字符串流
  Stream<String> chatStream({
    required List<Map<String, String>> messages,
    AiConfig? config,
  }) {
    final cfg = config ?? _currentConfig;
    if (cfg == null || cfg.apiKey.isEmpty) {
      throw AiConfigException('请先在设置中配置 API Key');
    }

    final (headers, url) = _buildRequest(cfg);

    // 使用 StreamController 将 Dio 流式响应转为字符串流
    final controller = StreamController<String>();

    _dio
        .post(
          url,
          options: Options(headers: headers, responseType: ResponseType.stream),
          data: _buildBody(config: cfg, messages: messages, stream: true),
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
                    final content = delta?['content'] as String?;
                    if (content != null && content.isNotEmpty) {
                      controller.add(content);
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
              controller.addError(AiConfigException('请求失败：$error'));
            }
            controller.close();
          }
        });

    return controller.stream;
  }

  AiConfig? _currentConfig;

  /// 设置当前使用的配置（可选，不传则从 AiConfigService 读取）
  void setCurrentConfig(AiConfig config) {
    _currentConfig = config;
  }

  AiConfigException _mapError(int? statusCode, dynamic data) {
    String? message;
    if (data is Map<String, dynamic>) {
      message = data['error']?['message'] as String?;
    }
    if (statusCode == null) {
      return AiConfigException(message ?? '请求失败');
    }
    switch (statusCode) {
      case 401:
      case 403:
        return AiConfigException('API Key 无效，请检查后重试');
      case 429:
        return AiConfigException(
          '请求过于频繁，请稍后重试${message != null ? '：$message' : ''}',
        );
      case 404:
        return AiConfigException('接口地址不存在，请检查 Base URL');
      case >= 500:
        return AiConfigException('服务端错误（HTTP $statusCode），请检查 Base URL');
      default:
        return AiConfigException(message ?? '请求失败（HTTP $statusCode）');
    }
  }
}
