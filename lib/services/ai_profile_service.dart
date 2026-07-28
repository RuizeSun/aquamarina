import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/ai_profile.dart';

/// DeepSeek 余额信息
class DeepSeekBalance {
  final bool isAvailable;
  final List<BalanceInfo> balanceInfos;

  const DeepSeekBalance({
    required this.isAvailable,
    this.balanceInfos = const [],
  });

  factory DeepSeekBalance.fromJson(Map<String, dynamic> json) {
    return DeepSeekBalance(
      isAvailable: json['is_available'] as bool? ?? false,
      balanceInfos:
          (json['balance_infos'] as List<dynamic>?)
              ?.map((e) => BalanceInfo.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}

class BalanceInfo {
  final String currency;
  final String totalBalance;
  final String grantedBalance;
  final String toppedUpBalance;

  const BalanceInfo({
    required this.currency,
    required this.totalBalance,
    required this.grantedBalance,
    required this.toppedUpBalance,
  });

  factory BalanceInfo.fromJson(Map<String, dynamic> json) {
    return BalanceInfo(
      currency: json['currency'] as String? ?? '',
      totalBalance: json['total_balance'] as String? ?? '0',
      grantedBalance: json['granted_balance'] as String? ?? '0',
      toppedUpBalance: json['topped_up_balance'] as String? ?? '0',
    );
  }

  double get totalAsDouble => double.tryParse(totalBalance) ?? 0;
}

/// AI 配置文件管理服务
class AiProfileService extends ChangeNotifier {
  static const String _prefsProfilesKey = 'ai_profiles_v2';
  static const String _prefsDefaultIdKey = 'ai_default_profile_id';

  final FlutterSecureStorage _secureStorage;
  final Dio _dio;
  List<AiProfile> _profiles = [];
  bool _loaded = false;

  AiProfileService({FlutterSecureStorage? secureStorage, Dio? dio})
    : _secureStorage = secureStorage ?? const FlutterSecureStorage(),
      _dio = dio ?? Dio();

  List<AiProfile> get profiles => List.unmodifiable(_profiles);

  bool get loaded => _loaded;

  /// 获取默认配置文件
  AiProfile? get defaultProfile {
    if (!_loaded) return null;
    try {
      return _profiles.firstWhere((p) => p.isDefault);
    } catch (_) {
      // 没有默认配置则返回第一个
      return _profiles.isNotEmpty ? _profiles.first : null;
    }
  }

  /// 获取指定 ID 的配置
  AiProfile? getProfile(String id) {
    try {
      return _profiles.firstWhere((p) => p.id == id);
    } catch (_) {
      return null;
    }
  }

  /// 加载所有配置
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();

    // 读取配置列表
    final jsonStr = prefs.getString(_prefsProfilesKey);
    if (jsonStr != null) {
      try {
        final list = jsonDecode(jsonStr) as List<dynamic>;
        _profiles = list
            .map((e) => AiProfile.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {
        _profiles = [];
      }
    }

    // 加载每个配置的 API Key
    for (int i = 0; i < _profiles.length; i++) {
      try {
        final apiKey = await _secureStorage.read(
          key: _secureKeyFor(_profiles[i].id),
        );
        if (apiKey != null && apiKey.isNotEmpty) {
          _profiles[i] = _profiles[i].copyWith(apiKey: apiKey);
        }
      } catch (_) {}
    }

    _loaded = true;
    notifyListeners();
  }

  /// 添加新配置
  Future<void> addProfile(AiProfile profile) async {
    // 如果是第一个配置，自动设为默认
    final isFirst = _profiles.isEmpty;
    final p = isFirst ? profile.copyWith(isDefault: true) : profile;

    _profiles.add(p);
    await _saveProfiles();
    await _saveApiKey(p.id, p.apiKey);
    notifyListeners();
  }

  /// 更新配置
  Future<void> updateProfile(AiProfile profile) async {
    final index = _profiles.indexWhere((p) => p.id == profile.id);
    if (index == -1) {
      throw AiConfigException('配置不存在：${profile.id}');
    }

    _profiles[index] = profile;
    await _saveProfiles();
    await _saveApiKey(profile.id, profile.apiKey);
    notifyListeners();
  }

  /// 删除配置
  Future<void> deleteProfile(String id) async {
    _profiles.removeWhere((p) => p.id == id);
    await _saveProfiles();
    await _secureStorage.delete(key: _secureKeyFor(id));
    notifyListeners();
  }

  /// 设为默认配置
  Future<void> setDefault(String id) async {
    _profiles = _profiles.map((p) {
      return p.copyWith(isDefault: p.id == id);
    }).toList();
    await _saveProfiles();
    notifyListeners();
  }

  /// 获取默认配置 ID（用于快速读取）
  Future<String?> getDefaultProfileId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefsDefaultIdKey);
  }

  /// 保存配置列表到 SharedPreferences
  Future<void> _saveProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = _profiles.map((p) {
      // 保存时不包含 API Key（敏感字段单独存储）
      final json = p.toJson();
      json.remove('api_key');
      return json;
    }).toList();
    await prefs.setString(_prefsProfilesKey, jsonEncode(jsonList));

    // 保存默认配置 ID
    final defaultProfile = _profiles.cast<AiProfile?>().firstWhere(
      (p) => p?.isDefault == true,
      orElse: () => null,
    );
    if (defaultProfile != null) {
      await prefs.setString(_prefsDefaultIdKey, defaultProfile.id);
    } else {
      await prefs.remove(_prefsDefaultIdKey);
    }
  }

  String _secureKeyFor(String profileId) => 'ai_api_key_$profileId';

  Future<void> _saveApiKey(String profileId, String apiKey) async {
    if (apiKey.isNotEmpty) {
      await _secureStorage.write(key: _secureKeyFor(profileId), value: apiKey);
    }
  }

  // ===== 测试连接 =====

  /// 测试连接
  Future<String> testConnection(AiProfile profile) async {
    if (profile.apiKey.isEmpty) {
      throw AiConfigException('API Key 未设置');
    }

    final baseUrl = profile.baseUrl.replaceAll(RegExp(r'/+$'), '');
    try {
      // 构建请求体
      final body = <String, dynamic>{
        'model': profile.model,
        'messages': [
          {'role': 'user', 'content': 'Hello'},
        ],
        'max_tokens': 10,
        'stream': false,
      };

      // DeepSeek 思考模式下不传 temperature
      if (profile.isDeepSeek && profile.enableThinking) {
        body['thinking'] = {'type': 'enabled'};
        if (profile.reasoningEffort != null) {
          body['reasoning_effort'] = profile.reasoningEffort;
        }
      } else if (profile.temperature != null) {
        body['temperature'] = profile.temperature;
      }

      final response = await _dio.post(
        '$baseUrl/chat/completions',
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ${profile.apiKey}',
          },
          sendTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
        ),
        data: body,
      );

      if (response.statusCode == 200) {
        return '✅ 连接成功（${profile.model}）';
      } else {
        throw _mapHttpError(response.statusCode, null);
      }
    } on DioException catch (e) {
      if (e.response != null) {
        throw _mapHttpError(e.response?.statusCode, e.message);
      }
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        throw AiConfigException('连接超时，请检查网络或 Base URL');
      }
      throw AiConfigException('网络连接失败：${e.message}');
    }
  }

  // ===== DeepSeek 专用接口 =====

  /// 查询余额
  Future<DeepSeekBalance> checkBalance(AiProfile profile) async {
    if (!profile.isDeepSeek) {
      throw AiConfigException('仅 DeepSeek 类型支持余额查询');
    }
    if (profile.apiKey.isEmpty) {
      throw AiConfigException('API Key 未设置');
    }

    final baseUrl = profile.baseUrl.replaceAll(RegExp(r'/+$'), '');
    try {
      final response = await _dio.get(
        '$baseUrl/user/balance',
        options: Options(
          headers: {
            'Accept': 'application/json',
            'Authorization': 'Bearer ${profile.apiKey}',
          },
          sendTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
        ),
      );

      if (response.statusCode == 200) {
        return DeepSeekBalance.fromJson(response.data as Map<String, dynamic>);
      } else {
        throw _mapHttpError(response.statusCode, null);
      }
    } on DioException catch (e) {
      if (e.response != null) {
        throw _mapHttpError(e.response?.statusCode, e.message);
      }
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        throw AiConfigException('连接超时，请检查网络或 Base URL');
      }
      throw AiConfigException('网络连接失败：${e.message}');
    }
  }

  /// 获取模型列表（仅 DeepSeek）
  Future<List<String>> fetchModels(AiProfile profile) async {
    if (!profile.isDeepSeek && !profile.isOpenAI) {
      throw AiConfigException('该类型不支持模型列表查询');
    }
    if (profile.apiKey.isEmpty) {
      throw AiConfigException('API Key 未设置');
    }

    final baseUrl = profile.baseUrl.replaceAll(RegExp(r'/+$'), '');
    try {
      final response = await _dio.get(
        '$baseUrl/models',
        options: Options(
          headers: {
            'Accept': 'application/json',
            'Authorization': 'Bearer ${profile.apiKey}',
          },
          sendTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
        ),
      );

      if (response.statusCode == 200) {
        final data = response.data as Map<String, dynamic>;
        final modelsList = data['data'] as List<dynamic>;
        return modelsList
            .map((e) => (e as Map<String, dynamic>)['id'] as String)
            .toList();
      } else {
        throw _mapHttpError(response.statusCode, null);
      }
    } on DioException catch (e) {
      if (e.response != null) {
        throw _mapHttpError(e.response?.statusCode, e.message);
      }
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        throw AiConfigException('连接超时，请检查网络或 Base URL');
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

  /// 检查余额是否低于阈值
  bool isBalanceBelowThreshold(AiProfile profile, DeepSeekBalance balance) {
    if (profile.balanceThreshold == null) return false;
    if (!balance.isAvailable) return true;
    if (balance.balanceInfos.isEmpty) return false;

    // 计算总余额（CNY）
    double total = 0;
    for (final info in balance.balanceInfos) {
      total += info.totalAsDouble;
    }
    return total < profile.balanceThreshold!;
  }
}

class AiConfigException implements Exception {
  final String message;
  AiConfigException(this.message);

  @override
  String toString() => message;
}
