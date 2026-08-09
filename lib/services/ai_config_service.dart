import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import '../models/ai_config.dart';

class AiConfigService extends ChangeNotifier {
  static const String _prefsKey = 'ai_config_json';
  static const String _secureKey = 'ai_api_key';

  final FlutterSecureStorage _secureStorage;
  final Dio _dio;
  AiConfig _config = const AiConfig();

  AiConfigService({FlutterSecureStorage? secureStorage, Dio? dio})
    : _secureStorage = secureStorage ?? const FlutterSecureStorage(),
      _dio = dio ?? Dio();

  AiConfig get config => _config;

  /// 加载配置（从 SharedPreferences 加载非敏感字段，从安全存储加载 API Key）
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();

    // 读取非敏感配置
    final jsonStr = prefs.getString(_prefsKey);
    if (jsonStr != null) {
      try {
        final map = jsonDecode(jsonStr) as Map<String, dynamic>;
        _config = AiConfig(
          baseUrl: map['base_url'] as String? ?? _config.baseUrl,
          model: map['model'] as String? ?? _config.model,
          temperature:
              (map['temperature'] as num?)?.toDouble() ?? _config.temperature,
          maxTokens: map['max_tokens'] as int? ?? _config.maxTokens,
          apiKey: _config.apiKey,
        );
      } catch (_) {}
    }

    // 从安全存储读取 API Key
    try {
      final apiKey = await _secureStorage.read(key: _secureKey);
      if (apiKey != null) {
        _config = _config.copyWith(apiKey: apiKey);
      }
    } catch (_) {}

    notifyListeners();
  }

  /// 保存非敏感配置
  Future<void> saveConfig(AiConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(config.toJson()));
    _config = _config.copyWith(
      baseUrl: config.baseUrl,
      model: config.model,
      temperature: config.temperature,
      maxTokens: config.maxTokens,
    );
    notifyListeners();
  }

  /// 保存 API Key 到安全存储
  Future<void> saveApiKey(String apiKey) async {
    await _secureStorage.write(key: _secureKey, value: apiKey);
    _config = _config.copyWith(apiKey: apiKey);
    notifyListeners();
  }

  /// 保存完整配置（含 API Key）
  Future<void> saveAll(AiConfig config) async {
    await saveConfig(config);
    await saveApiKey(config.apiKey);
  }

  /// 清除所有 AI 配置
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
    await _secureStorage.delete(key: _secureKey);
    _config = const AiConfig();
    notifyListeners();
  }

  /// 测试连接：发送一个简单的 chat 请求验证配置是否可用
  Future<String> testConnection() async {
    final cfg = _config;
    if (cfg.apiKey.isEmpty) {
      throw AiConfigException('API Key 未设置');
    }

    final baseUrl = cfg.baseUrl.replaceAll(RegExp(r'/+$'), '');
    try {
      final response = await _dio.post(
        '$baseUrl/chat/completions',
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ${cfg.apiKey}',
          },
          connectTimeout: const Duration(seconds: 10),
          sendTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
        ),
        data: {
          'model': cfg.model,
          'messages': [
            {'role': 'user', 'content': 'Hello'},
          ],
          'max_tokens': 10,
          'temperature': cfg.temperature,
        },
      );

      if (response.statusCode == 200) {
        return '✅ 连接成功（${cfg.model}）';
      } else {
        throw _mapHttpError(response.statusCode, null);
      }
    } on DioException catch (e) {
      if (e.response != null) {
        throw _mapHttpError(e.response?.statusCode, e.message);
      }
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.connectionError) {
        throw AiConfigException('连接超时或失败，请检查网络或 Base URL');
      }
      throw AiConfigException('网络连接失败：${e.message}');
    }
  }

  AiConfigException _mapHttpError(int? statusCode, String? detail) {
    if (statusCode == null) {
      return AiConfigException('请求失败：$detail');
    }
    switch (statusCode) {
      case 401:
      case 403:
        return AiConfigException('API Key 无效，请检查后重试');
      case 429:
        return AiConfigException('请求过于频繁，请稍后重试');
      case 404:
        return AiConfigException('接口地址不存在，请检查 Base URL');
      case >= 500:
        return AiConfigException('服务端错误（HTTP $statusCode），请检查 Base URL');
      default:
        return AiConfigException(
          '请求失败（HTTP $statusCode${detail != null ? ': $detail' : ''}）',
        );
    }
  }
}

class AiConfigException implements Exception {
  final String message;
  AiConfigException(this.message);

  @override
  String toString() => message;
}
