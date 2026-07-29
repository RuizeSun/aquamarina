import 'package:uuid/uuid.dart';

/// AI 配置类型
enum AiProfileType {
  /// 标准 OpenAI 兼容协议
  openai,

  /// DeepSeek（基于 OpenAI 兼容协议 + 自定义接口）
  deepseek,

  /// Aquamarina 官方（非标准 API，专用端点 /api/v1/chat）
  aquamarina,
}

/// 预设配置模板
enum AiProfileTemplate {
  openaiOfficial,
  deepseekOfficial,
  aquamarinaOfficial,
  custom,
}

/// 根据模板创建预设配置
AiProfile createProfileFromTemplate(AiProfileTemplate template) {
  switch (template) {
    case AiProfileTemplate.openaiOfficial:
      return AiProfile(
        id: const Uuid().v4(),
        name: 'OpenAI 官方',
        type: AiProfileType.openai,
        baseUrl: 'https://api.openai.com/v1',
        model: 'gpt-4o-mini',
        maxTokens: 2048,
        temperature: 0.7,
      );
    case AiProfileTemplate.deepseekOfficial:
      return AiProfile(
        id: const Uuid().v4(),
        name: 'DeepSeek 官方',
        type: AiProfileType.deepseek,
        baseUrl: 'https://api.deepseek.com',
        model: 'deepseek-chat',
        maxTokens: 8192,
        temperature: null,
        enableThinking: true,
        reasoningEffort: 'high',
      );
    case AiProfileTemplate.aquamarinaOfficial:
      return AiProfile(
        id: const Uuid().v4(),
        name: 'Aquamarina 官方',
        type: AiProfileType.aquamarina,
        baseUrl: 'https://aquamarina.78go.work/api/v1',
        apiKey: 'aquamarinapublicapi',
        model: 'default',
        maxTokens: 4096,
        temperature: null,
      );
    case AiProfileTemplate.custom:
      return AiProfile(
        id: const Uuid().v4(),
        name: '自定义',
        type: AiProfileType.openai,
        baseUrl: 'https://api.openai.com/v1',
        model: 'gpt-4o-mini',
        maxTokens: 2048,
        temperature: 0.7,
      );
  }
}

/// AI 配置文件
class AiProfile {
  final String id;
  final String name;
  final AiProfileType type;
  final String baseUrl;
  final String apiKey;
  final String model;
  final int maxTokens;

  /// temperature: DeepSeek 思考模式下无效（为 null 时不发送）
  final double? temperature;

  /// DeepSeek 思考模式开关
  final bool enableThinking;

  /// DeepSeek 思考强度: "high" / "max"
  final String? reasoningEffort;

  /// 是否设为默认配置
  final bool isDefault;

  /// DeepSeek 余额停止使用阈值（元），为 null 时不限制
  final double? balanceThreshold;

  const AiProfile({
    required this.id,
    required this.name,
    required this.type,
    this.baseUrl = 'https://api.openai.com/v1',
    this.apiKey = '',
    this.model = 'gpt-4o-mini',
    this.maxTokens = 2048,
    this.temperature,
    this.enableThinking = false,
    this.reasoningEffort,
    this.isDefault = false,
    this.balanceThreshold,
  });

  AiProfile copyWith({
    String? id,
    String? name,
    AiProfileType? type,
    String? baseUrl,
    String? apiKey,
    String? model,
    int? maxTokens,
    double? temperature,
    bool? enableThinking,
    String? reasoningEffort,
    bool? isDefault,
    double? balanceThreshold,
    bool clearApiKey = false,
    bool clearBalanceThreshold = false,
  }) {
    return AiProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      type: type ?? this.type,
      baseUrl: baseUrl ?? this.baseUrl,
      apiKey: clearApiKey ? '' : (apiKey ?? this.apiKey),
      model: model ?? this.model,
      maxTokens: maxTokens ?? this.maxTokens,
      temperature: temperature ?? this.temperature,
      enableThinking: enableThinking ?? this.enableThinking,
      reasoningEffort: reasoningEffort ?? this.reasoningEffort,
      isDefault: isDefault ?? this.isDefault,
      balanceThreshold: clearBalanceThreshold
          ? null
          : (balanceThreshold ?? this.balanceThreshold),
    );
  }

  /// 是否为 DeepSeek 类型
  bool get isDeepSeek => type == AiProfileType.deepseek;

  /// 是否为标准 OpenAI 类型
  bool get isOpenAI => type == AiProfileType.openai;

  /// 是否为 Aquamarina 官方类型
  bool get isAquamarina => type == AiProfileType.aquamarina;

  /// 非敏感配置序列化（API Key 单独存储）
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'type': type.name,
    'base_url': baseUrl,
    'model': model,
    'max_tokens': maxTokens,
    if (temperature != null) 'temperature': temperature,
    'enable_thinking': enableThinking,
    if (reasoningEffort != null) 'reasoning_effort': reasoningEffort,
    'is_default': isDefault,
    if (balanceThreshold != null) 'balance_threshold': balanceThreshold,
  };

  /// 从 JSON 反序列化
  factory AiProfile.fromJson(Map<String, dynamic> json) {
    return AiProfile(
      id: json['id'] as String,
      name: json['name'] as String,
      type: AiProfileType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => AiProfileType.openai,
      ),
      baseUrl: json['base_url'] as String? ?? 'https://api.openai.com/v1',
      apiKey: '', // API Key 不从 JSON 读取
      model: json['model'] as String? ?? 'gpt-4o-mini',
      maxTokens: json['max_tokens'] as int? ?? 2048,
      temperature: (json['temperature'] as num?)?.toDouble(),
      enableThinking: json['enable_thinking'] as bool? ?? false,
      reasoningEffort: json['reasoning_effort'] as String?,
      isDefault: json['is_default'] as bool? ?? false,
      balanceThreshold: (json['balance_threshold'] as num?)?.toDouble(),
    );
  }
}
