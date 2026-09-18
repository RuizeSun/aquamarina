import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../models/sentence_difficulty.dart';
import 'database_service.dart';
import 'log_service.dart';

/// 一次「AI 生成句式集」请求的预估 / 实际用量样本（预估矫正的原始数据）。
///
/// 每条样本对应**一次真实请求**：记录生成前的预估 tokens 与服务端返回的实际
/// tokens，以及影响用量的上下文（模型 / 温度 / 思考模式 / 思考强度 / 难度 /
/// 每词句数 / 本次请求句子数）。后续预估时用这些维度做加权统计。
class AiEstimateSample {
  final DateTime createdAt;
  final String model;
  final double? temperature;
  final bool thinking;
  final String? reasoningEffort;
  final SentenceDifficulty difficulty;
  final int sentencesPerWord;

  /// 本次请求覆盖的句子数（相似长度维度）
  final int sentenceCount;

  /// 生成前的预估 tokens
  final int estimatedPromptTokens;
  final int estimatedCompletionTokens;

  /// 服务端返回的实际 tokens
  final int promptTokens;
  final int completionTokens;

  const AiEstimateSample({
    required this.createdAt,
    required this.model,
    this.temperature,
    this.thinking = false,
    this.reasoningEffort,
    required this.difficulty,
    required this.sentencesPerWord,
    required this.sentenceCount,
    required this.estimatedPromptTokens,
    required this.estimatedCompletionTokens,
    required this.promptTokens,
    required this.completionTokens,
  });

  /// 是否可用于矫正：预估与实际都必须为正数，否则比例没有意义
  bool get isUsable =>
      estimatedPromptTokens > 0 &&
      estimatedCompletionTokens > 0 &&
      promptTokens > 0 &&
      completionTokens > 0;

  Map<String, Object?> toRow() => {
    'created_at': createdAt.toIso8601String(),
    'model': model,
    'temperature': temperature,
    'enable_thinking': thinking ? 1 : 0,
    'reasoning_effort': reasoningEffort,
    'difficulty': difficulty.name,
    'sentences_per_word': sentencesPerWord,
    'sentence_count': sentenceCount,
    'estimated_prompt_tokens': estimatedPromptTokens,
    'estimated_completion_tokens': estimatedCompletionTokens,
    'prompt_tokens': promptTokens,
    'completion_tokens': completionTokens,
  };

  factory AiEstimateSample.fromRow(Map<String, Object?> row) {
    int asInt(String key) => (row[key] as num?)?.toInt() ?? 0;
    return AiEstimateSample(
      createdAt:
          DateTime.tryParse(row['created_at'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      model: row['model'] as String? ?? '',
      temperature: (row['temperature'] as num?)?.toDouble(),
      thinking: (row['enable_thinking'] as int?) == 1,
      reasoningEffort: row['reasoning_effort'] as String?,
      difficulty: SentenceDifficulty.fromName(row['difficulty'] as String?),
      sentencesPerWord: asInt('sentences_per_word'),
      sentenceCount: asInt('sentence_count'),
      estimatedPromptTokens: asInt('estimated_prompt_tokens'),
      estimatedCompletionTokens: asInt('estimated_completion_tokens'),
      promptTokens: asInt('prompt_tokens'),
      completionTokens: asInt('completion_tokens'),
    );
  }
}

/// 当前要预估的这次生成的上下文（与样本维度一一对应）
class AiEstimateContext {
  final String model;
  final double? temperature;
  final bool thinking;
  final String? reasoningEffort;
  final SentenceDifficulty difficulty;
  final int sentenceCount;

  const AiEstimateContext({
    required this.model,
    this.temperature,
    this.thinking = false,
    this.reasoningEffort,
    required this.difficulty,
    required this.sentenceCount,
  });
}

/// 预估矫正结果：把原始估算乘以历史观测出的偏差系数。
///
/// 同时容纳「多维度加权 + 样本收缩」的矫正算法（纯函数，便于单测）。
class AiEstimateCalibration {
  /// 输入 tokens 矫正系数（1.0 表示不矫正）
  final double promptFactor;

  /// 输出 tokens 矫正系数（1.0 表示不矫正）
  final double completionFactor;

  /// 参与统计的加权有效样本数（权重之和）
  final double effectiveSamples;

  /// 权重足够高的历史样本条数（用于界面提示「基于 N 次相近请求」）
  final int matchedSamples;

  /// 置信度（0~1）：样本越多越高，矫正幅度越接近真实观测偏差
  final double confidence;

  const AiEstimateCalibration({
    required this.promptFactor,
    required this.completionFactor,
    required this.effectiveSamples,
    required this.matchedSamples,
    required this.confidence,
  });

  /// 样本不足或无可比样本时的「不矫正」结果
  static const AiEstimateCalibration none = AiEstimateCalibration(
    promptFactor: 1,
    completionFactor: 1,
    effectiveSamples: 0,
    matchedSamples: 0,
    confidence: 0,
  );

  // ── 矫正参数 ────────────────────────────────────────

  /// 低于该有效样本量不做矫正，避免一两条异常样本带偏预估
  static const double minEffectiveSamples = 0.6;

  /// 样本收缩强度：置信度 = n / (n + k)。k 越大越保守。
  static const double shrinkK = 3.0;

  /// 权重达到该阈值才计入「相近样本」条数（用于界面提示）
  static const double matchedWeightThreshold = 0.3;

  /// 时间衰减半衰期（天）：越近期的样本权重越高
  static const double halfLifeDays = 14.0;

  /// 时间衰减权重下限，避免久远样本完全消失（仍保留一点参考价值）
  static const double minRecencyWeight = 0.1;

  /// 是否真的对预估做了调整
  bool get applied => promptFactor != 1 || completionFactor != 1;

  /// 是否有可用于参考的历史样本
  bool get hasSamples => matchedSamples > 0;

  int correctPrompt(int rawTokens) =>
      math.max(0, (rawTokens * promptFactor).round());

  int correctCompletion(int rawTokens) =>
      math.max(0, (rawTokens * completionFactor).round());

  // ── 算法 ────────────────────────────────────────────

  /// 根据历史样本与当前上下文计算矫正系数。
  ///
  /// 每个样本先按各维度相似度加权：
  /// - **同模型**是硬门槛（模型不同直接不计入）；
  /// - 温度 / 思考模式 / 思考强度越接近权重越高；
  /// - 难度越接近、句子数（相似长度）越接近权重越高；
  /// - 越近期的样本权重越高。
  ///
  /// 再用有效样本量做收缩：factor = 1 + (观测比例 - 1) × n/(n+k)，
  /// 因此样本少时矫正保守，样本积累后逐渐逼近真实偏差。
  static AiEstimateCalibration compute({
    required Iterable<AiEstimateSample> samples,
    required AiEstimateContext context,
    DateTime? now,
  }) {
    final reference = now ?? DateTime.now();
    var totalWeight = 0.0;
    var weightedPromptRatio = 0.0;
    var weightedCompletionRatio = 0.0;
    var matched = 0;

    for (final sample in samples) {
      if (!sample.isUsable) continue;
      final weight = sampleWeight(sample, context, reference);
      if (weight <= 0) continue;
      totalWeight += weight;
      weightedPromptRatio +=
          weight * (sample.promptTokens / sample.estimatedPromptTokens);
      weightedCompletionRatio +=
          weight * (sample.completionTokens / sample.estimatedCompletionTokens);
      if (weight >= matchedWeightThreshold) matched++;
    }

    if (totalWeight <= 0 || totalWeight < minEffectiveSamples) {
      return AiEstimateCalibration(
        promptFactor: 1,
        completionFactor: 1,
        effectiveSamples: totalWeight,
        matchedSamples: matched,
        confidence: 0,
      );
    }

    final observedPrompt = weightedPromptRatio / totalWeight;
    final observedCompletion = weightedCompletionRatio / totalWeight;
    final confidence = totalWeight / (totalWeight + shrinkK);

    return AiEstimateCalibration(
      promptFactor: clampFactor(
        1 + (observedPrompt - 1) * confidence,
        min: 0.5,
        max: 2.0,
      ),
      completionFactor: clampFactor(
        1 + (observedCompletion - 1) * confidence,
        min: 0.4,
        max: 3.0,
      ),
      effectiveSamples: totalWeight,
      matchedSamples: matched,
      confidence: confidence,
    );
  }

  /// 单个样本对当前上下文的综合权重（0 表示完全不相关）
  static double sampleWeight(
    AiEstimateSample sample,
    AiEstimateContext context,
    DateTime now,
  ) {
    if (sample.model != context.model) return 0;

    var weight = 1.0;
    weight *= temperatureSimilarity(sample.temperature, context.temperature);
    weight *= sample.thinking == context.thinking ? 1.0 : 0.15;
    weight *= effortSimilarity(
      sample.reasoningEffort,
      context.reasoningEffort,
      thinking: context.thinking,
    );
    weight *= difficultySimilarity(sample.difficulty, context.difficulty);
    weight *= lengthSimilarity(sample.sentenceCount, context.sentenceCount);
    weight *= recencyWeight(sample.createdAt, now);
    return weight;
  }

  /// 温度相似度：都未设置或完全相同为 1，差异越大越低。
  static double temperatureSimilarity(double? a, double? b) {
    if (a == null && b == null) return 1.0;
    if (a == null || b == null) return 0.5;
    final diff = (a - b).abs();
    return (1 - diff / 0.5).clamp(0.0, 1.0);
  }

  /// 思考强度相似度：未开启思考时不参与；相同为 1，未知为 0.5，不同为 0.25。
  static double effortSimilarity(
    String? a,
    String? b, {
    required bool thinking,
  }) {
    if (!thinking) return 1.0;
    if (a == b) return 1.0;
    if (a == null || b == null) return 0.5;
    return 0.25;
  }

  /// 难度相似度：同档为 1，CEFR 相差越远越低（最低 0.1）。
  static double difficultySimilarity(
    SentenceDifficulty a,
    SentenceDifficulty b,
  ) {
    final diff = (a.index - b.index).abs();
    if (diff == 0) return 1.0;
    return (1 - diff / SentenceDifficulty.values.length).clamp(0.1, 1.0);
  }

  /// 长度相似度：本次请求句子数的比值（min / max），差异越大越低。
  static double lengthSimilarity(int a, int b) {
    if (a <= 0 || b <= 0) return 0.5;
    final ratio = math.min(a, b) / math.max(a, b);
    return ratio.clamp(0.1, 1.0);
  }

  /// 时间衰减权重：半衰期 [halfLifeDays] 天
  static double recencyWeight(DateTime createdAt, DateTime now) {
    final minutes = now.difference(createdAt).inMinutes;
    final days = minutes <= 0 ? 0.0 : minutes / (60 * 24);
    final weight = math.pow(0.5, days / halfLifeDays).toDouble();
    return weight < minRecencyWeight ? minRecencyWeight : weight;
  }

  static double clampFactor(
    double value, {
    required double min,
    required double max,
  }) => value.clamp(min, max).toDouble();
}

/// 「AI 生成句式集」消耗预估的自矫正服务（全局单例）。
///
/// 思路：生成前用的是经验公式（难度单句 tokens、提示词逐字估算等），
/// 与实际用量可能有系统性偏差。每次真实请求结束后把「预估 / 实际」写入
/// [AiEstimateSample]，下次预估时按 **同模型、同温度、同思考模式、同思考
/// effort、相似长度、难度** 等维度加权统计历史比例，并用样本量做收缩，
/// 样本越少矫正越保守、样本越多越接近真实偏差（随着使用自动变准）。
class AiEstimateCalibrationService {
  AiEstimateCalibrationService._(this._openDatabase)
    : _samples = [],
      _loaded = false;

  /// 全局单例：使用应用业务数据库
  static final AiEstimateCalibrationService instance =
      AiEstimateCalibrationService._(() => DatabaseService.database);

  /// 测试专用：注入自定义数据库（例如 sqflite ffi 内存库）
  @visibleForTesting
  AiEstimateCalibrationService.withDatabase(
    Future<Database> Function() openDatabase,
  ) : _openDatabase = openDatabase,
      _samples = [],
      _loaded = false;

  /// 测试专用：直接用内存样本构造，不触碰数据库
  @visibleForTesting
  AiEstimateCalibrationService.withSamples(List<AiEstimateSample> samples)
    : _openDatabase = _unavailableDatabase,
      _samples = List.of(samples),
      _loaded = true;

  static Future<Database> _unavailableDatabase() =>
      Future.error(StateError('该实例为测试样本实例，未连接数据库'));

  /// 数据库访问入口（生产环境为业务数据库，测试可注入内存库）
  final Future<Database> Function() _openDatabase;

  static const String table = 'ai_estimate_samples';

  /// 内存中保留的最近样本数上限（超出后丢弃最旧的）
  static const int maxSamples = 800;

  /// 只使用最近多少天的样本（更久以前的定价 / 模型行为可能已变化）
  static const int retentionDays = 90;

  List<AiEstimateSample> _samples;
  bool _loaded;

  /// 当前内存中的样本（按时间倒序）
  List<AiEstimateSample> get samples => List.unmodifiable(_samples);

  bool get isLoaded => _loaded;

  // ── 读 ────────────────────────────────────────────

  /// 从数据库加载近期样本到内存（[force] 为 true 时强制重新加载）。
  ///
  /// 加载失败只记日志并保持空样本（预估退化为原始经验公式），不影响主流程。
  Future<void> load({bool force = false}) async {
    if (_loaded && !force) return;
    try {
      final db = await _openDatabase();
      final since = DateTime.now()
          .subtract(const Duration(days: retentionDays))
          .toIso8601String();
      final rows = await db.query(
        table,
        where: 'created_at >= ?',
        whereArgs: [since],
        orderBy: 'created_at DESC',
        limit: maxSamples,
      );
      _samples = rows.map(AiEstimateSample.fromRow).toList();
    } catch (e, stackTrace) {
      logError('AiEstimateCalibrationService', '加载预估矫正样本失败: $e', stackTrace);
      _samples = [];
    }
    _loaded = true;
  }

  /// 计算当前上下文对应的矫正系数（同步，使用内存样本）
  AiEstimateCalibration calibrationFor(
    AiEstimateContext context, {
    DateTime? now,
  }) => AiEstimateCalibration.compute(
    samples: _samples,
    context: context,
    now: now,
  );

  // ── 写 ────────────────────────────────────────────

  /// 记录一次真实请求的「预估 / 实际」样本，供后续预估矫正。
  ///
  /// 数据不合法或写库失败时静默跳过（仅记日志），不阻塞生成流程。
  Future<void> recordSample({
    required String model,
    double? temperature,
    bool thinking = false,
    String? reasoningEffort,
    required SentenceDifficulty difficulty,
    required int sentencesPerWord,
    required int sentenceCount,
    required int estimatedPromptTokens,
    required int estimatedCompletionTokens,
    required int promptTokens,
    required int completionTokens,
    DateTime? createdAt,
  }) async {
    final sample = AiEstimateSample(
      createdAt: createdAt ?? DateTime.now(),
      model: model,
      temperature: temperature,
      thinking: thinking,
      reasoningEffort: reasoningEffort,
      difficulty: difficulty,
      sentencesPerWord: sentencesPerWord,
      sentenceCount: sentenceCount,
      estimatedPromptTokens: estimatedPromptTokens,
      estimatedCompletionTokens: estimatedCompletionTokens,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
    );
    if (!sample.isUsable) return;

    _samples.insert(0, sample);
    if (_samples.length > maxSamples) {
      _samples.removeRange(maxSamples, _samples.length);
    }

    try {
      final db = await _openDatabase();
      await db.insert(table, sample.toRow());
    } catch (e, stackTrace) {
      logError('AiEstimateCalibrationService', '写入预估矫正样本失败: $e', stackTrace);
    }
  }

  /// 清空所有矫正样本
  Future<void> clear() async {
    _samples = [];
    _loaded = true;
    try {
      final db = await _openDatabase();
      await db.delete(table);
    } catch (e, stackTrace) {
      logError('AiEstimateCalibrationService', '清空预估矫正样本失败: $e', stackTrace);
    }
  }

  /// 样本总条数（供设置页展示）
  Future<int> count() async {
    try {
      final db = await _openDatabase();
      final result = await db.rawQuery('SELECT COUNT(*) AS c FROM $table');
      return (result.first['c'] as num?)?.toInt() ?? 0;
    } catch (e, stackTrace) {
      logError('AiEstimateCalibrationService', '统计预估矫正样本失败: $e', stackTrace);
      return 0;
    }
  }
}
