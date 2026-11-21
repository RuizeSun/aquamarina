/// 上下文处理策略：消息条数限制 + 阈值触发的摘要压缩。
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
  /// 消息条数下限 / 上限 / 默认值（默认 20 条）。
  static const int minMessageCount = 2;
  static const int maxMessageCount = 100;
  static const int defaultMessageCount = 20;

  /// 绝对阈值范围（tokens）。
  static const int minAbsoluteThreshold = 256;
  static const int maxAbsoluteThreshold = 2000000;
  static const int defaultAbsoluteThreshold = 16384;

  /// 比例阈值范围（0.05 = 5%，1.0 = 100%）。
  static const double minRatio = 0.05;
  static const double maxRatio = 1.0;
  static const double defaultRatio = 0.5;

  final int maxMessages;
  final bool compressionEnabled;
  final AiContextThresholdMode thresholdMode;
  final int absoluteThreshold;
  final double ratioThreshold;

  const AiContextPolicy({
    this.maxMessages = defaultMessageCount,
    this.compressionEnabled = false,
    this.thresholdMode = AiContextThresholdMode.absolute,
    this.absoluteThreshold = defaultAbsoluteThreshold,
    this.ratioThreshold = defaultRatio,
  });

  /// 默认策略：保留最近 20 条消息，摘要压缩默认关闭（避免升级后自动产生额外请求）。
  static const AiContextPolicy defaults = AiContextPolicy();

  /// 把用户输入收敛到安全范围。
  AiContextPolicy normalized() {
    return AiContextPolicy(
      maxMessages: maxMessages.clamp(minMessageCount, maxMessageCount),
      compressionEnabled: compressionEnabled,
      thresholdMode: thresholdMode,
      absoluteThreshold: absoluteThreshold.clamp(
        minAbsoluteThreshold,
        maxAbsoluteThreshold,
      ),
      ratioThreshold: ratioThreshold.clamp(minRatio, maxRatio),
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

  AiContextPolicy copyWith({
    int? maxMessages,
    bool? compressionEnabled,
    AiContextThresholdMode? thresholdMode,
    int? absoluteThreshold,
    double? ratioThreshold,
  }) {
    return AiContextPolicy(
      maxMessages: maxMessages ?? this.maxMessages,
      compressionEnabled: compressionEnabled ?? this.compressionEnabled,
      thresholdMode: thresholdMode ?? this.thresholdMode,
      absoluteThreshold: absoluteThreshold ?? this.absoluteThreshold,
      ratioThreshold: ratioThreshold ?? this.ratioThreshold,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AiContextPolicy &&
      other.maxMessages == maxMessages &&
      other.compressionEnabled == compressionEnabled &&
      other.thresholdMode == thresholdMode &&
      other.absoluteThreshold == absoluteThreshold &&
      other.ratioThreshold == ratioThreshold;

  @override
  int get hashCode => Object.hash(
    maxMessages,
    compressionEnabled,
    thresholdMode,
    absoluteThreshold,
    ratioThreshold,
  );
}
