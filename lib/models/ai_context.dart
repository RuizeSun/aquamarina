/// 上下文处理策略：阈值触发的摘要压缩 + 会话用量提示。
///
/// 这里的阈值是「触发压缩」的软阈值；真正的硬上限是 AI 配置里的上下文窗口
/// （未填写时，绝对阈值同时充当上限）。两者都由 [AiContextPolicy] 与
/// [AiProfile.contextWindow] 共同决定。
enum AiContextThresholdMode {
  /// 绝对 token 数，例如达到 16K tokens 时压缩。
  absolute,

  /// 上下文窗口的比例，例如达到窗口的 50% 时压缩。
  ratio;

  static AiContextThresholdMode fromName(String? name) => values.firstWhere(
    (e) => e.name == name,
    orElse: () => AiContextThresholdMode.absolute,
  );
}

/// 用户在「上下文处理」里配置的策略。
class AiContextPolicy {
  /// 绝对阈值范围（tokens）。
  static const int minAbsoluteThreshold = 256;
  static const int maxAbsoluteThreshold = 2000000;
  static const int defaultAbsoluteThreshold = 16384;

  /// 比例阈值范围（0.05 = 5%，1.0 = 100%）。
  static const double minRatio = 0.05;
  static const double maxRatio = 1.0;
  static const double defaultRatio = 0.5;

  /// 用量提示阈值范围（0.10 = 10%，0.95 = 95%）。
  static const double minUsageWarningRatio = 0.10;
  static const double maxUsageWarningRatio = 0.95;
  static const double defaultUsageWarningRatio = 0.70;

  final bool compressionEnabled;
  final AiContextThresholdMode thresholdMode;
  final int absoluteThreshold;
  final double ratioThreshold;
  final bool usageWarningEnabled;
  final double usageWarningRatio;

  const AiContextPolicy({
    this.compressionEnabled = true,
    this.thresholdMode = AiContextThresholdMode.absolute,
    this.absoluteThreshold = defaultAbsoluteThreshold,
    this.ratioThreshold = defaultRatio,
    this.usageWarningEnabled = true,
    this.usageWarningRatio = defaultUsageWarningRatio,
  });

  /// 默认策略：摘要压缩默认开启，会话用量提示默认开启。
  static const AiContextPolicy defaults = AiContextPolicy();

  /// 把用户输入收敛到安全范围。
  AiContextPolicy normalized() {
    return AiContextPolicy(
      compressionEnabled: compressionEnabled,
      thresholdMode: thresholdMode,
      absoluteThreshold: absoluteThreshold.clamp(
        minAbsoluteThreshold,
        maxAbsoluteThreshold,
      ),
      ratioThreshold: ratioThreshold.clamp(minRatio, maxRatio),
      usageWarningEnabled: usageWarningEnabled,
      usageWarningRatio: usageWarningRatio.clamp(
        minUsageWarningRatio,
        maxUsageWarningRatio,
      ),
    );
  }

  /// 解析实际触发压缩的 token 阈值；返回 0 表示不触发。
  ///
  /// - 未启用压缩时返回 0；
  /// - 比例模式但上下文窗口未配置（<= 0）时返回 0，由调用方给出配置提示；
  /// - 其余情况返回换算后的 token 数（向下取整，至少 1）。
  int resolveThresholdTokens(int contextWindow) {
    if (!compressionEnabled) return 0;
    if (thresholdMode == AiContextThresholdMode.absolute) {
      return absoluteThreshold.clamp(
        minAbsoluteThreshold,
        maxAbsoluteThreshold,
      );
    }
    if (contextWindow <= 0) return 0;
    final value = (contextWindow * ratioThreshold.clamp(minRatio, maxRatio))
        .floor();
    return value < 1 ? 1 : value;
  }

  /// 解析会话用量提示的 token 阈值；返回 0 表示不提示。
  int resolveUsageWarningTokens(int contextWindow) {
    if (!usageWarningEnabled || contextWindow <= 0) return 0;
    final value =
        (contextWindow *
                usageWarningRatio.clamp(
                  minUsageWarningRatio,
                  maxUsageWarningRatio,
                ))
            .floor();
    return value < 1 ? 1 : value;
  }

  AiContextPolicy copyWith({
    bool? compressionEnabled,
    AiContextThresholdMode? thresholdMode,
    int? absoluteThreshold,
    double? ratioThreshold,
    bool? usageWarningEnabled,
    double? usageWarningRatio,
  }) {
    return AiContextPolicy(
      compressionEnabled: compressionEnabled ?? this.compressionEnabled,
      thresholdMode: thresholdMode ?? this.thresholdMode,
      absoluteThreshold: absoluteThreshold ?? this.absoluteThreshold,
      ratioThreshold: ratioThreshold ?? this.ratioThreshold,
      usageWarningEnabled: usageWarningEnabled ?? this.usageWarningEnabled,
      usageWarningRatio: usageWarningRatio ?? this.usageWarningRatio,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AiContextPolicy &&
      other.compressionEnabled == compressionEnabled &&
      other.thresholdMode == thresholdMode &&
      other.absoluteThreshold == absoluteThreshold &&
      other.ratioThreshold == ratioThreshold &&
      other.usageWarningEnabled == usageWarningEnabled &&
      other.usageWarningRatio == usageWarningRatio;

  @override
  int get hashCode => Object.hash(
    compressionEnabled,
    thresholdMode,
    absoluteThreshold,
    ratioThreshold,
    usageWarningEnabled,
    usageWarningRatio,
  );
}

/// 当前会话历史相对上下文窗口的用量快照。
class AiContextUsage {
  /// 会话历史的估算 tokens（system + 全量消息 + 工具定义）。
  final int usedTokens;

  /// AI 配置的上下文窗口；0 表示未配置。
  final int windowTokens;

  /// 达到该值即提示用户；0 表示不提示。
  final int warningTokens;

  const AiContextUsage({
    required this.usedTokens,
    required this.windowTokens,
    required this.warningTokens,
  });

  double get ratio => windowTokens <= 0 ? 0 : usedTokens / windowTokens;

  bool get isWarning => warningTokens > 0 && usedTokens >= warningTokens;
}
