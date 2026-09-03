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

/// 计费方式：按 token（缓存命中/未命中/输出三档单价）或按请求（固定价）
enum AiPricingMode {
  /// 按 token 计费
  perToken,

  /// 按请求固定价计费
  perRequest,
}

/// 单价单位：每 token / 每 1K / 每 1M
enum AiPriceUnit {
  perToken('每 token', 1),
  perThousand('每 1K tokens', 1000),
  perMillion('每 1M tokens', 1000000);

  final String label;
  final int divisor;

  const AiPriceUnit(this.label, this.divisor);

  /// 从序列化名解析，未知时回退到「每 1M tokens」
  static AiPriceUnit fromName(String? name) => values.firstWhere(
    (e) => e.name == name,
    orElse: () => AiPriceUnit.perMillion,
  );
}

/// AI 调用的计费与货币设置（仅 OpenAI 兼容 / DeepSeek 类型可用）
///
/// 挂载到 [AiProfile.pricing]。请求发生时价格会被快照进用量记录，
/// 因此后续修改价格不影响历史统计金额。
class AiUsagePricing {
  final AiPricingMode mode;

  /// 单价单位（按 token 计费时使用）
  final AiPriceUnit unit;

  /// 缓存命中输入单价（按 [unit] 计价）
  final double? cacheHitPrice;

  /// 未命中缓存输入单价（按 [unit] 计价）
  final double? cacheMissPrice;

  /// 输出单价（按 [unit] 计价）
  final double? outputPrice;

  /// 每请求固定价（按请求计费时使用）
  final double? requestPrice;

  /// 币种符号，如 $ ¥ €
  final String currencySymbol;

  /// 金额小数位数（0-4）
  final int currencyDecimals;

  /// 是否启用千位分隔符
  final bool currencyGrouping;

  const AiUsagePricing({
    this.mode = AiPricingMode.perToken,
    this.unit = AiPriceUnit.perMillion,
    this.cacheHitPrice,
    this.cacheMissPrice,
    this.outputPrice,
    this.requestPrice,
    this.currencySymbol = '¥',
    this.currencyDecimals = 2,
    this.currencyGrouping = true,
  });

  bool get isPerRequest => mode == AiPricingMode.perRequest;

  AiUsagePricing copyWith({
    AiPricingMode? mode,
    AiPriceUnit? unit,
    double? cacheHitPrice,
    double? cacheMissPrice,
    double? outputPrice,
    double? requestPrice,
    String? currencySymbol,
    int? currencyDecimals,
    bool? currencyGrouping,
    bool clearCacheHitPrice = false,
    bool clearCacheMissPrice = false,
    bool clearOutputPrice = false,
    bool clearRequestPrice = false,
  }) {
    return AiUsagePricing(
      mode: mode ?? this.mode,
      unit: unit ?? this.unit,
      cacheHitPrice: clearCacheHitPrice
          ? null
          : (cacheHitPrice ?? this.cacheHitPrice),
      cacheMissPrice: clearCacheMissPrice
          ? null
          : (cacheMissPrice ?? this.cacheMissPrice),
      outputPrice: clearOutputPrice
          ? null
          : (outputPrice ?? this.outputPrice),
      requestPrice: clearRequestPrice
          ? null
          : (requestPrice ?? this.requestPrice),
      currencySymbol: currencySymbol ?? this.currencySymbol,
      currencyDecimals: currencyDecimals ?? this.currencyDecimals,
      currencyGrouping: currencyGrouping ?? this.currencyGrouping,
    );
  }

  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    'unit': unit.name,
    if (cacheHitPrice != null) 'cache_hit_price': cacheHitPrice,
    if (cacheMissPrice != null) 'cache_miss_price': cacheMissPrice,
    if (outputPrice != null) 'output_price': outputPrice,
    if (requestPrice != null) 'request_price': requestPrice,
    'currency_symbol': currencySymbol,
    'currency_decimals': currencyDecimals,
    'currency_grouping': currencyGrouping,
  };

  factory AiUsagePricing.fromJson(Map<String, dynamic> json) {
    return AiUsagePricing(
      mode: json['mode'] == AiPricingMode.perRequest.name
          ? AiPricingMode.perRequest
          : AiPricingMode.perToken,
      unit: AiPriceUnit.fromName(json['unit'] as String?),
      cacheHitPrice: (json['cache_hit_price'] as num?)?.toDouble(),
      cacheMissPrice: (json['cache_miss_price'] as num?)?.toDouble(),
      outputPrice: (json['output_price'] as num?)?.toDouble(),
      requestPrice: (json['request_price'] as num?)?.toDouble(),
      currencySymbol: json['currency_symbol'] as String? ?? '¥',
      currencyDecimals: json['currency_decimals'] as int? ?? 2,
      currencyGrouping: json['currency_grouping'] as bool? ?? true,
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

  /// AI 调用的计费与货币设置（仅 OpenAI 兼容 / DeepSeek 可用），为 null 时不启用计费
  final AiUsagePricing? pricing;

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
    this.pricing,
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
    AiUsagePricing? pricing,
    bool clearApiKey = false,
    bool clearBalanceThreshold = false,
    bool clearPricing = false,
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
      pricing: clearPricing ? null : (pricing ?? this.pricing),
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
    if (pricing != null) 'pricing': pricing!.toJson(),
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
      pricing: json['pricing'] is Map<String, dynamic>
          ? AiUsagePricing.fromJson(
              json['pricing'] as Map<String, dynamic>,
            )
          : null,
    );
  }
}
