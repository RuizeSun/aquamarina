import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:dio/dio.dart';

import '../models/ai_profile.dart';
import '../models/sentence_difficulty.dart';
import '../models/word_entry.dart';
import 'ai_estimate_calibration_service.dart';
import 'ai_profile_service.dart';
import 'ai_service.dart';
import 'ai_token_estimator.dart';
import 'ai_usage_service.dart';
import 'dictionary_service.dart';
import 'log_service.dart';

/// 单词 + 简短中文释义：写入提示词的原料。
class WordPromptEntry {
  final String word;

  /// 词典里的简短中文释义（可能为空 —— 本地词典没有收录该词）
  final String gloss;

  const WordPromptEntry({required this.word, this.gloss = ''});

  /// 写入提示词的一行，如 `abandon —— 放弃；抛弃`
  String get promptLine => gloss.isEmpty ? word : '$word —— $gloss';
}

/// AI 生成的一句内容（尚未落库为 [Sentence]）
class GeneratedSentence {
  /// 这句是为哪个给定单词生成的（便于用户核对覆盖情况）
  final String sourceWord;
  final String english;
  final String chinese;
  final List<String> extraWords;

  const GeneratedSentence({
    required this.sourceWord,
    required this.english,
    required this.chinese,
    this.extraWords = const [],
  });
}

/// 生成前的消耗预估（token / 费用）
class SentenceGenerationEstimate {
  /// 需要发起的 AI 请求次数
  final int requestCount;

  /// 每次请求覆盖的单词数
  final int wordsPerRequest;

  /// 每个单词生成的句子数
  final int sentencesPerWord;

  /// 预计生成的句子总数
  final int totalSentences;

  /// 预估输入 tokens（按提示词实际内容估算）
  final int promptTokens;

  /// 预估输入 tokens 中会命中服务端上下文缓存的部分
  /// （DeepSeek 前缀缓存；未配置缓存命中单价时为 0）
  final int cacheHitTokens;

  /// 预估输出 tokens（已计入思考模式下的思考内容开销）
  final int completionTokens;

  /// 是否启用了思考模式（影响输出 tokens 与耗时）
  final bool thinkingEnabled;

  /// 思考模式的输出放大系数（未启用时为 null）
  final double? thinkingMultiplier;

  /// 预估费用；未配置计费或价格不完整时为 null
  final double? cost;

  /// 是否配置了可用的计费信息
  final bool pricingConfigured;

  /// 计费方式（按 token / 按请求）
  final AiPricingMode? pricingMode;

  final String currencySymbol;
  final int currencyDecimals;
  final bool currencyGrouping;

  /// 未矫正的原始输入 / 输出 token 估算（展示与诊断用）
  final int rawPromptTokens;
  final int rawCompletionTokens;

  /// 是否应用了历史样本矫正（样本不足时保持原经验公式）
  final bool calibrationApplied;

  /// 参与矫正的相近历史请求条数（0 表示样本不足）
  final int calibrationSamples;

  /// 矫正置信度 0~1：样本越多越高，矫正越接近真实偏差
  final double calibrationConfidence;

  /// 实际采用的输入 / 输出矫正系数
  final double calibrationPromptFactor;
  final double calibrationCompletionFactor;

  const SentenceGenerationEstimate({
    required this.requestCount,
    required this.wordsPerRequest,
    required this.sentencesPerWord,
    required this.totalSentences,
    required this.promptTokens,
    this.cacheHitTokens = 0,
    required this.completionTokens,
    required this.thinkingEnabled,
    this.thinkingMultiplier,
    this.cost,
    required this.pricingConfigured,
    this.pricingMode,
    this.currencySymbol = '¥',
    this.currencyDecimals = 2,
    this.currencyGrouping = true,
    this.rawPromptTokens = 0,
    this.rawCompletionTokens = 0,
    this.calibrationApplied = false,
    this.calibrationSamples = 0,
    this.calibrationConfidence = 0,
    this.calibrationPromptFactor = 1,
    this.calibrationCompletionFactor = 1,
  });

  /// 是否已有相近历史样本（可能因权重不足而未真正矫正）
  bool get calibrationHasSamples => calibrationSamples > 0;

  int get totalTokens => promptTokens + completionTokens;

  /// 是否按服务端上下文缓存做了输入费用折减
  bool get cacheDiscountApplied => cacheHitTokens > 0;

  /// 未命中缓存的输入 tokens
  int get cacheMissTokens => promptTokens - cacheHitTokens;

  bool get isPerRequest => pricingMode == AiPricingMode.perRequest;

  /// 格式化后的预估费用（无可计价配置时为 null）
  String? formatCost() {
    final value = cost;
    if (value == null) return null;
    return AiUsageService.formatMoney(
      value,
      symbol: currencySymbol,
      decimals: currencyDecimals,
      grouping: currencyGrouping,
    );
  }
}

/// 生成结果（支持部分批次失败）
class SentenceGenerationResult {
  final List<GeneratedSentence> sentences;
  final int totalBatches;
  final int failedBatches;

  const SentenceGenerationResult({
    required this.sentences,
    required this.totalBatches,
    required this.failedBatches,
  });

  bool get isPartial => failedBatches > 0;
}

/// 根据词书中的单词调用 AI 生成句式集内容。
///
/// 与句型练习的批改功能不同，本功能**只支持标准 OpenAI 兼容 / DeepSeek 配置**：
/// Aquamarina 官方配置走专用端点、无 usage 返回，无法做 token 与费用预估，
/// 因此 [resolveProfile] 会直接拒绝该类型的配置。
class AiSentenceGenerator {
  AiSentenceGenerator({
    AiProfileService? profileService,
    AiService? aiService,
    AiEstimateCalibrationService? calibrationService,
  }) : _profileService = profileService ?? AiProfileService(),
       _aiService = aiService ?? AiService(),
       calibrationService =
           calibrationService ?? AiEstimateCalibrationService.instance;

  final AiProfileService _profileService;
  final AiService _aiService;

  /// 消耗预估矫正服务：生成结束时回写「预估 / 实际」样本，
  /// 预估时读取近期同维度样本修正经验公式的系统性偏差。
  final AiEstimateCalibrationService calibrationService;

  /// 单次请求最多要求 AI 返回的句子数（避免长回复被 max_tokens 截断）。
  static const int maxSentencesPerRequest = 12;

  /// 单个句式集一次最多纳入的单词数（避免一次生成几十个请求）。
  static const int maxWordsPerGeneration = 200;

  /// 每个单词可生成的句子数区间
  static const int minSentencesPerWord = 1;
  static const int maxSentencesPerWord = 3;

  // ── 配置解析 ────────────────────────────────────────

  /// 加载并校验可用于本功能的 AI 配置。
  ///
  /// 抛出 [AiSentenceGenerateException] 的场景：
  /// [AiSentenceGenerateError.notConfigured] 未配置任何 AI 配置、
  /// [AiSentenceGenerateError.aquamarina] 默认配置是 Aquamarina 官方（不支持）、
  /// [AiSentenceGenerateError.missingApiKey] 缺少 API Key。
  Future<AiProfile> resolveProfile() async {
    await _profileService.load();
    final profile = _profileService.defaultProfile;
    if (profile == null) {
      throw const AiSentenceGenerateException(
        '尚未配置 AI 服务，请先在「设置 → AI 配置」中添加一个 OpenAI 兼容或 DeepSeek 配置',
        code: AiSentenceGenerateError.notConfigured,
      );
    }
    if (profile.isAquamarina) {
      throw const AiSentenceGenerateException(
        '当前默认配置是「Aquamarina 官方」，该类型不支持 AI 生成句式集。\n'
        '请在「设置 → AI 配置」中新建一个 OpenAI 兼容或 DeepSeek 配置，并将其设为默认后再试。',
        code: AiSentenceGenerateError.aquamarina,
      );
    }
    if (profile.apiKey.isEmpty) {
      throw const AiSentenceGenerateException(
        '当前 AI 配置缺少 API Key，请先在设置中补全',
        code: AiSentenceGenerateError.missingApiKey,
      );
    }
    return profile;
  }

  // ── 词条准备 ────────────────────────────────────────

  /// 批量查询本地词典，为每个单词附上简短中文释义（写入提示词帮助 AI 消歧）。
  Future<List<WordPromptEntry>> loadWordEntries(List<String> words) async {
    if (words.isEmpty) return const [];
    final Map<String, WordEntry> found;
    try {
      found = await DictionaryService.searchEnExactBatch(words);
    } catch (e, stackTrace) {
      // 词典不可用不应阻塞生成，只是提示词里少了中文释义
      logError('AiSentenceGenerator', '查询单词释义失败: $e', stackTrace);
      return words.map((w) => WordPromptEntry(word: w)).toList();
    }
    return words.map((w) {
      final entry = found[w.trim().toLowerCase()];
      return WordPromptEntry(word: w, gloss: shortGloss(entry?.translation));
    }).toList();
  }

  /// 取释义的首行并截断，避免提示词被超长释义撑爆。
  static String shortGloss(String? translation, {int maxChars = 40}) {
    if (translation == null) return '';
    var text = translation.split('\n').first.trim();
    text = text.replaceAll(RegExp(r'\s+'), ' ');
    if (text.length > maxChars) {
      text = '${text.substring(0, maxChars)}…';
    }
    return text;
  }

  // ── 预估 ────────────────────────────────────────────

  /// 计算生成计划（按 `max_tokens` 与难度推导每批单词数）。
  ///
  /// 单批句子数取「请求上限」与「`max_tokens` 预算」的较小值，
  /// 保证 AI 有足够空间返回完整 JSON，而不是被截断成半截对象。
  static int sentencesPerRequestFor({
    required AiProfile profile,
    required SentenceDifficulty difficulty,
  }) {
    final budget = profile.maxTokens <= 0 ? 2048 : profile.maxTokens;
    final byBudget = budget ~/ difficulty.tokensPerSentence;
    return byBudget.clamp(1, maxSentencesPerRequest);
  }

  /// 每次请求覆盖的单词数。
  static int wordsPerRequestFor({
    required AiProfile profile,
    required SentenceDifficulty difficulty,
    required int sentencesPerWord,
  }) {
    final perWord = sentencesPerWord.clamp(
      minSentencesPerWord,
      maxSentencesPerWord,
    );
    final sentencesPerRequest = sentencesPerRequestFor(
      profile: profile,
      difficulty: difficulty,
    );
    return (sentencesPerRequest ~/ perWord).clamp(1, maxWordsPerGeneration);
  }

  /// 思考模式下的输出 token 放大系数：思考（reasoning）内容同样按输出计费。
  static double thinkingOutputMultiplier(String? reasoningEffort) {
    switch (reasoningEffort) {
      case 'max':
        return 3.0;
      case 'high':
        return 2.0;
      default:
        return 1.6;
    }
  }

  /// 生成前的消耗预估。
  ///
  /// - 输入 tokens：按真实提示词内容逐批估算（含中文释义）；
  /// - 输出 tokens：按难度单句经验值 × 句数，开启思考时再乘放大系数；
  /// - 缓存命中：DeepSeek 的上下文缓存按 **前缀** 命中，且以 64 tokens 为最小
  ///   缓存单元。同一批生成中各次请求的系统提示词完全一致，因此第 2 批起
  ///   这段前缀预计会命中缓存，按 [AiUsagePricing.cacheHitPrice] 计费；
  /// - 费用：完全复用 [AiUsageService.computeCost]，与事后记账同一套公式。
  SentenceGenerationEstimate estimate({
    required AiProfile profile,
    required List<WordPromptEntry> entries,
    required SentenceDifficulty difficulty,
    required int sentencesPerWord,
  }) {
    final perWord = sentencesPerWord.clamp(
      minSentencesPerWord,
      maxSentencesPerWord,
    );
    final wordsPerRequest = wordsPerRequestFor(
      profile: profile,
      difficulty: difficulty,
      sentencesPerWord: perWord,
    );
    final batches = _chunk(entries, wordsPerRequest);

    var promptTokens = 0;
    var completionTokens = 0;
    for (final batch in batches) {
      promptTokens += AiTokenEstimator.estimateMessages(
        buildMessages(
          entries: batch,
          difficulty: difficulty,
          sentencesPerWord: perWord,
        ),
      );
      completionTokens += completionTokensFor(
        sentenceCount: batch.length * perWord,
        difficulty: difficulty,
        profile: profile,
      );
    }

    // 矫正前的经验公式估算值
    final rawPromptTokens = promptTokens;
    final rawCompletionTokens = completionTokens;

    final pricing = profile.pricing;
    var cacheHitTokens = estimateCacheHitTokens(
      profile: profile,
      batches: batches.length,
      difficulty: difficulty,
      sentencesPerWord: perWord,
    );
    final rawCacheHitTokens = cacheHitTokens;

    // 多维度历史矫正：同模型是硬门槛，温度 / 思考模式 / effort / 难度 /
    // 句子长度越接近权重越高，越近期权重越高；样本越多矫正越接近真实偏差。
    final thinkingEnabled = profile.isDeepSeek && profile.enableThinking;
    final calibration = calibrationService.calibrationFor(
      AiEstimateContext(
        model: profile.model,
        temperature: profile.temperature,
        thinking: thinkingEnabled,
        reasoningEffort: profile.reasoningEffort,
        difficulty: difficulty,
        // 以典型满批的句子数作为「相似长度」维度
        sentenceCount: entries.isEmpty
            ? 0
            : math.min(entries.length, wordsPerRequest) * perWord,
      ),
    );
    if (calibration.applied) {
      promptTokens = calibration.correctPrompt(rawPromptTokens);
      completionTokens = calibration.correctCompletion(rawCompletionTokens);
      cacheHitTokens = calibration.correctPrompt(rawCacheHitTokens);
    }

    double? cost;
    if (pricing != null) {
      if (pricing.isPerRequest) {
        cost = pricing.requestPrice == null
            ? null
            : pricing.requestPrice! * batches.length;
      } else {
        cost = AiUsageService.computeCost(
          pricing,
          cacheHitTokens: cacheHitTokens,
          // 命中缓存的那部分输入已按缓存单价计费，剩余部分才算未命中
          cacheMissTokens: promptTokens - cacheHitTokens,
          completionTokens: completionTokens,
        );
      }
    }

    return SentenceGenerationEstimate(
      requestCount: batches.length,
      wordsPerRequest: wordsPerRequest,
      sentencesPerWord: perWord,
      totalSentences: entries.length * perWord,
      promptTokens: promptTokens,
      cacheHitTokens: cacheHitTokens,
      completionTokens: completionTokens,
      thinkingEnabled: thinkingEnabled,
      thinkingMultiplier: thinkingEnabled
          ? thinkingOutputMultiplier(profile.reasoningEffort)
          : null,
      cost: cost,
      pricingConfigured: pricing != null && cost != null,
      pricingMode: pricing?.mode,
      currencySymbol: pricing?.currencySymbol ?? '¥',
      currencyDecimals: pricing?.currencyDecimals ?? 2,
      currencyGrouping: pricing?.currencyGrouping ?? true,
      rawPromptTokens: rawPromptTokens,
      rawCompletionTokens: rawCompletionTokens,
      calibrationApplied: calibration.applied,
      calibrationSamples: calibration.matchedSamples,
      calibrationConfidence: calibration.confidence,
      calibrationPromptFactor: calibration.promptFactor,
      calibrationCompletionFactor: calibration.completionFactor,
    );
  }

  /// DeepSeek 上下文缓存的最小缓存单元（tokens）。
  ///
  /// 官方说明：缓存按前缀匹配，最小缓存单元为 64 tokens，
  /// 因此不足一个单元的前缀不会被缓存，估算时向下取整到 64 的整数倍。
  static const int deepSeekCacheBlockSize = 64;

  /// 预估会命中 DeepSeek 上下文缓存的输入 tokens。
  ///
  /// 规则：
  /// - 仅 DeepSeek 类型、且配置了「缓存命中单价」时才有意义（否则命中与否都不影响费用）；
  /// - 第 1 次请求没有可复用的前缀，命中为 0；
  /// - 第 2 次起，各请求共享的系统提示词前缀预计命中，按 64 tokens 向下取整后
  ///   乘以剩余请求数。
  static int estimateCacheHitTokens({
    required AiProfile profile,
    required int batches,
    required SentenceDifficulty difficulty,
    required int sentencesPerWord,
  }) {
    if (!profile.isDeepSeek) return 0;
    if (profile.pricing?.cacheHitPrice == null) return 0;
    if (batches <= 1) return 0;

    final systemTokens = AiTokenEstimator.estimateMessages([
      {
        'role': 'system',
        'content': buildSystemPrompt(difficulty, sentencesPerWord),
      },
    ]);
    final cachedPrefix =
        (systemTokens ~/ deepSeekCacheBlockSize) * deepSeekCacheBlockSize;
    if (cachedPrefix <= 0) return 0;
    return cachedPrefix * (batches - 1);
  }

  /// 估算一批 [sentenceCount] 句的输出 tokens。
  static int completionTokensFor({
    required int sentenceCount,
    required SentenceDifficulty difficulty,
    required AiProfile profile,
  }) {
    if (sentenceCount <= 0) return 0;
    var tokens =
        sentenceCount * difficulty.tokensPerSentence +
        AiTokenEstimator.replyEnvelopeOverhead;
    if (profile.isDeepSeek && profile.enableThinking) {
      tokens = (tokens * thinkingOutputMultiplier(profile.reasoningEffort))
          .round();
    }
    return tokens;
  }

  // ── 生成 ────────────────────────────────────────────

  /// 逐批调用 AI 生成句子。
  ///
  /// - [stream] 为 true（默认）时走流式接口：文本边到达边解析，
  ///   每解析出一句完整的句子就通过 [onSentence] 回调，界面可实时展示
  ///   AI 正在写的句子；
  /// - 单批失败不会中断整体流程（避免已消耗的 token 白费），该批已经流式
  ///   收到的完整句子仍会保留；返回结果里带上
  ///   [SentenceGenerationResult.failedBatches]；若一句都没生成则抛异常。
  Future<SentenceGenerationResult> generate({
    required AiProfile profile,
    required List<WordPromptEntry> entries,
    required SentenceDifficulty difficulty,
    required int sentencesPerWord,
    bool stream = true,
    CancelToken? cancelToken,
    void Function(int completed, int total)? onProgress,
    void Function(GeneratedSentence sentence)? onSentence,
  }) async {
    final perWord = sentencesPerWord.clamp(
      minSentencesPerWord,
      maxSentencesPerWord,
    );
    final batches = _chunk(
      entries,
      wordsPerRequestFor(
        profile: profile,
        difficulty: difficulty,
        sentencesPerWord: perWord,
      ),
    );
    if (batches.isEmpty) {
      throw const AiSentenceGenerateException('没有需要生成的单词');
    }

    logInfo(
      'AiSentenceGenerator',
      '开始生成句式集：${entries.length} 词 / 难度=${difficulty.label}(${difficulty.cefr}) / '
          '$perWord 句每词 / ${batches.length} 批 model=${profile.model}',
    );

    final generated = <GeneratedSentence>[];
    var failed = 0;
    var lastError = '';

    final thinkingEnabled = profile.isDeepSeek && profile.enableThinking;

    onProgress?.call(0, batches.length);
    for (var i = 0; i < batches.length; i++) {
      if (cancelToken?.isCancelled ?? false) break;
      final batch = batches[i];
      final messages = buildMessages(
        entries: batch,
        difficulty: difficulty,
        sentencesPerWord: perWord,
      );

      // 记录本批「生成前的预估」，请求结束后与服务端返回的实际用量配对，
      // 作为后续预估矫正的样本。
      final estimatedPromptTokens = AiTokenEstimator.estimateMessages(messages);
      final estimatedCompletionTokens = completionTokensFor(
        sentenceCount: batch.length * perWord,
        difficulty: difficulty,
        profile: profile,
      );
      AiUsageSnapshot? usage;

      // 流式场景下边收边解析，已完整的句子立即回调给界面；
      // 同时保留这些句子，即使本批后续中断也不浪费已消耗的 token。
      final batchSentences = <GeneratedSentence>[];
      String? batchError;

      try {
        if (stream) {
          final parser = StreamingSentenceParser();
          final raw = StringBuffer();
          await for (final chunk in _aiService.chatStream(
            messages: messages,
            profile: profile,
            includeReasoningContent: false,
            cancelToken: cancelToken,
            onUsage: (value) => usage = value,
          )) {
            raw.write(chunk);
            parser.addChunk(chunk);
            for (final sentence in parser.takeNewSentences()) {
              batchSentences.add(sentence);
              onSentence?.call(sentence);
            }
          }
          // 兜底：分块边界导致增量解析没切出任何句子时，用完整文本再解析一次
          if (batchSentences.isEmpty) {
            final parsed = parseGeneratedSentences(raw.toString());
            for (final sentence in parsed) {
              batchSentences.add(sentence);
              onSentence?.call(sentence);
            }
          }
        } else {
          final response = await _aiService.chat(
            messages: messages,
            profile: profile,
            cancelToken: cancelToken,
            onUsage: (value) => usage = value,
          );
          final parsed = parseGeneratedSentences(response);
          for (final sentence in parsed) {
            batchSentences.add(sentence);
            onSentence?.call(sentence);
          }
        }
      } catch (e, stackTrace) {
        batchError = e is AiServiceException ? e.message : '$e';
        logError('AiSentenceGenerator', '第 ${i + 1} 批生成失败: $e', stackTrace);
      }

      if (batchError != null) {
        failed++;
        lastError = batchError;
      } else if (batchSentences.isEmpty) {
        failed++;
        lastError = 'AI 返回内容中没有可用句子';
        logError('AiSentenceGenerator', '第 ${i + 1} 批未解析出句子');
      } else {
        // 成功批次且拿到真实 usage 时回写矫正样本（异步，不阻塞生成）
        final actualUsage = usage;
        if (actualUsage != null) {
          unawaited(
            calibrationService.recordSample(
              model: profile.model,
              temperature: profile.temperature,
              thinking: thinkingEnabled,
              reasoningEffort: profile.reasoningEffort,
              difficulty: difficulty,
              sentencesPerWord: perWord,
              sentenceCount: batch.length * perWord,
              estimatedPromptTokens: estimatedPromptTokens,
              estimatedCompletionTokens: estimatedCompletionTokens,
              promptTokens: actualUsage.promptTokens,
              completionTokens: actualUsage.completionTokens,
            ),
          );
        }
      }
      generated.addAll(batchSentences);
      onProgress?.call(i + 1, batches.length);
    }

    if (generated.isEmpty) {
      throw AiSentenceGenerateException(
        'AI 未能返回可用的句子：$lastError',
        code: AiSentenceGenerateError.emptyResult,
      );
    }

    logInfo(
      'AiSentenceGenerator',
      '生成完成：${generated.length} 句，失败 $failed/${batches.length} 批',
    );
    return SentenceGenerationResult(
      sentences: generated,
      totalBatches: batches.length,
      failedBatches: failed,
    );
  }

  // ── 提示词 ──────────────────────────────────────────

  /// 构建一次生成的 chat messages（公开以便单测校验提示词）。
  static List<Map<String, String>> buildMessages({
    required List<WordPromptEntry> entries,
    required SentenceDifficulty difficulty,
    required int sentencesPerWord,
  }) {
    return [
      {
        'role': 'system',
        'content': buildSystemPrompt(difficulty, sentencesPerWord),
      },
      {'role': 'user', 'content': buildUserPrompt(entries, sentencesPerWord)},
    ];
  }

  /// 系统提示词：约束难度、句式集字段格式与干扰词规则。
  static String buildSystemPrompt(
    SentenceDifficulty difficulty,
    int sentencesPerWord,
  ) {
    final perWord = sentencesPerWord.clamp(
      minSentencesPerWord,
      maxSentencesPerWord,
    );
    return '''你是英语学习 App 的句式集生成助手，负责按指定 CEFR 难度为给定单词编写练习句。

【本次难度】${difficulty.cefr}（${difficulty.label}）
${difficulty.promptHint}

【硬性要求】
1. 为每个给定单词各生成 $perWord 个英文句子，每句都必须自然地用到该单词（可改变词形、时态或派生形式）。
2. 英文句子的词汇范围、长度与句式结构必须严格符合上述 CEFR 难度，不得超纲。
3. 中文翻译要符合中文表达习惯，简洁通顺，不要附加解释、音标或词性说明。
4. extra_words 是该句的干扰词池：给出 2~4 个**不出现在该英文句子中**的英语单词，词性与长度应与句内词汇相近，用于入门版组句练习。
5. extra_words 中的单词必须拼写正确、互不重复，且不得是句中任何单词的变形。
6. 同一批次内，不同句子的英文表达不得重复或仅做微小改动。
7. 只输出 JSON，不要输出任何解释、Markdown 代码块标记或额外文字。

【输出格式】
{"sentences":[{"word":"给定的单词","english":"English sentence.","chinese":"中文翻译。","extra_words":["distractor1","distractor2"]}]}''';
  }

  /// 用户提示词：待生成单词清单（带中文释义便于消歧）。
  static String buildUserPrompt(
    List<WordPromptEntry> entries,
    int sentencesPerWord,
  ) {
    final perWord = sentencesPerWord.clamp(
      minSentencesPerWord,
      maxSentencesPerWord,
    );
    final buffer = StringBuffer()
      ..writeln('请为以下 ${entries.length} 个单词各生成 $perWord 个句子：');
    for (var i = 0; i < entries.length; i++) {
      buffer.writeln('${i + 1}. ${entries[i].promptLine}');
    }
    return buffer.toString();
  }

  // ── 解析 ────────────────────────────────────────────

  /// 解析 AI 返回文本中的句子列表。
  ///
  /// 依次尝试：剥离 Markdown 代码块 → 取最外层 `{...}` / `[...]` → 逐对象兜底，
  /// 因此即使回复被 `max_tokens` 截断，也能救回其中完整的句子对象。
  static List<GeneratedSentence> parseGeneratedSentences(String response) {
    final trimmed = response.trim();
    if (trimmed.isEmpty) return const [];

    final candidates = <String>[];
    final fenced = _stripCodeFence(trimmed);
    if (fenced != null) candidates.add(fenced);
    candidates.add(trimmed);

    for (final candidate in candidates) {
      final jsonText = _outermostJson(candidate);
      if (jsonText == null) continue;
      try {
        final parsed = _extractSentences(jsonDecode(jsonText));
        if (parsed.isNotEmpty) return parsed;
      } catch (_) {
        // 继续尝试下一个候选 / 兜底扫描
      }
    }

    // 兜底：扫描所有形如 {...} 的片段，逐个解析出完整的句子对象
    return _salvageObjects(trimmed);
  }

  /// 去掉 ```json ... ``` 代码块包裹
  static String? _stripCodeFence(String text) {
    final match = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(text);
    final inner = match?.group(1)?.trim();
    return (inner == null || inner.isEmpty) ? null : inner;
  }

  /// 截取最外层的 JSON 对象或数组文本
  static String? _outermostJson(String text) {
    final objectStart = text.indexOf('{');
    final arrayStart = text.indexOf('[');
    if (objectStart == -1 && arrayStart == -1) return null;

    // 取更靠前且成对的那个定界符
    final useObject =
        objectStart != -1 && (arrayStart == -1 || objectStart < arrayStart);
    final start = useObject ? objectStart : arrayStart;
    final end = useObject ? text.lastIndexOf('}') : text.lastIndexOf(']');
    if (end <= start) return null;
    return text.substring(start, end + 1);
  }

  /// 从已解码的 JSON 中取出句子数组（兼容数组直接返回 / 常见包装字段）
  static List<GeneratedSentence> _extractSentences(dynamic decoded) {
    dynamic raw;
    if (decoded is List) {
      raw = decoded;
    } else if (decoded is Map) {
      for (final key in const [
        'sentences',
        'data',
        'items',
        'list',
        'result',
        'results',
      ]) {
        final value = decoded[key];
        if (value is List) {
          raw = value;
          break;
        }
      }
    }
    if (raw is! List) return const [];

    final result = <GeneratedSentence>[];
    for (final item in raw) {
      final sentence = parseSentenceItem(item);
      if (sentence != null) result.add(sentence);
    }
    return result;
  }

  /// 单个句子对象 → [GeneratedSentence]；缺少英文或中文时返回 null
  static GeneratedSentence? parseSentenceItem(dynamic item) {
    if (item is! Map) return null;

    final english = (item['english'] ?? item['sentence'] ?? item['en'])
        ?.toString()
        .trim();
    final chinese = (item['chinese'] ?? item['translation'] ?? item['zh'])
        ?.toString()
        .trim();
    if (english == null || english.isEmpty) return null;
    if (chinese == null || chinese.isEmpty) return null;

    final word = (item['word'] ?? item['source_word'] ?? '').toString().trim();

    final extraRaw = item['extra_words'] ?? item['extraWords'];
    final extras = <String>[];
    if (extraRaw is List) {
      final lowerEnglish = english.toLowerCase();
      for (final value in extraRaw) {
        final text = value?.toString().trim() ?? '';
        if (text.isEmpty) continue;
        final lower = text.toLowerCase();
        // 干扰词不得出现在句子里，否则入门版组句会出现重复词块
        if (lowerEnglish.contains(lower)) continue;
        if (extras.any((e) => e.toLowerCase() == lower)) continue;
        extras.add(text);
        if (extras.length >= 5) break;
      }
    }

    return GeneratedSentence(
      sourceWord: word,
      english: english,
      chinese: chinese,
      extraWords: extras,
    );
  }

  /// 被截断的回复兜底：逐个花括号片段尝试解析
  static List<GeneratedSentence> _salvageObjects(String text) {
    final result = <GeneratedSentence>[];
    final matches = RegExp(r'\{[^{}]*\}', dotAll: true).allMatches(text);
    for (final match in matches) {
      final fragment = match.group(0);
      if (fragment == null || !fragment.contains('english')) continue;
      try {
        final sentence = parseSentenceItem(jsonDecode(fragment));
        if (sentence != null) result.add(sentence);
      } catch (_) {
        // 片段不完整，跳过
      }
    }
    return result;
  }

  /// 按固定大小切分（最后一批可能更短）
  static List<List<T>> _chunk<T>(List<T> items, int size) {
    if (items.isEmpty) return const [];
    final step = size <= 0 ? items.length : size;
    final chunks = <List<T>>[];
    for (var start = 0; start < items.length; start += step) {
      final end = start + step < items.length ? start + step : items.length;
      chunks.add(items.sublist(start, end));
    }
    return chunks;
  }
}

/// 流式增量解析器：从边到达边拼接的 JSON 文本里即时切出完整的句子对象。
///
/// 流式响应是**逐步拼接**的（一次只到几个字），等全部收完再解析就没有实时反馈了；
/// 这里用一个「花括号配对 + 字符串状态机」在文本到达的过程中即时识别出
/// 已经闭合的句子对象，因此：
///
/// - 无需等待整批完成即可把句子交给界面展示；
/// - 即使回复被 `max_tokens` 截断，已经完整的句子也不会丢；
/// - 嵌套对象（如额外的元信息字段）与字符串里的花括号都能正确处理。
class StreamingSentenceParser {
  /// 已收到的全部文本
  final StringBuffer _buffer = StringBuffer();

  /// 尚未闭合的对象起始下标栈
  final List<int> _stack = [];

  /// 已扫描到的位置（避免重复扫描）
  int _scanned = 0;

  /// 当前是否位于字符串字面量内
  bool _inString = false;

  /// 字符串内是否处于转义状态
  bool _escaped = false;

  /// 自上次 [takeNewSentences] 以来新解析出的完整句子
  final List<GeneratedSentence> _pending = [];

  /// 追加一段流式文本
  void addChunk(String chunk) {
    if (chunk.isEmpty) return;
    _buffer.write(chunk);
    _scan();
  }

  /// 当前累计的原始文本
  String get rawText => _buffer.toString();

  /// 取出并清空新解析出的完整句子
  List<GeneratedSentence> takeNewSentences() {
    if (_pending.isEmpty) return const [];
    final result = List<GeneratedSentence>.unmodifiable(_pending);
    _pending.clear();
    return result;
  }

  void _scan() {
    final text = _buffer.toString();
    for (var i = _scanned; i < text.length; i++) {
      final ch = text[i];

      if (_inString) {
        if (_escaped) {
          _escaped = false;
        } else if (ch == r'\') {
          _escaped = true;
        } else if (ch == '"') {
          _inString = false;
        }
        continue;
      }

      if (ch == '"') {
        _inString = true;
      } else if (ch == '{') {
        _stack.add(i);
      } else if (ch == '}') {
        if (_stack.isEmpty) continue;
        final start = _stack.removeLast();
        // 栈深 ≤ 1 说明该对象要么是顶层对象本身，要么是顶层对象里的直接子对象；
        // 句子对象两种写法都能覆盖，顶层包装对象会因为没有 english 字段被忽略
        if (_stack.length <= 1) {
          _tryEmit(text.substring(start, i + 1));
        }
      }
    }
    _scanned = text.length;
  }

  void _tryEmit(String fragment) {
    if (!fragment.contains('english')) return;
    try {
      final sentence = AiSentenceGenerator.parseSentenceItem(
        jsonDecode(fragment),
      );
      if (sentence != null) _pending.add(sentence);
    } catch (_) {
      // 片段本身不是合法 JSON（例如是包装对象），忽略
    }
  }
}

/// 本功能不可用 / 生成失败的原因
enum AiSentenceGenerateError {
  /// 未配置任何 AI 配置
  notConfigured,

  /// 默认配置为 Aquamarina 官方类型（本功能不支持）
  aquamarina,

  /// 配置缺少 API Key
  missingApiKey,

  /// AI 未返回可用句子
  emptyResult,

  /// 其他（网络、服务端错误等）
  other,
}

/// AI 生成句式集异常
class AiSentenceGenerateException implements Exception {
  final String message;
  final AiSentenceGenerateError code;

  const AiSentenceGenerateException(
    this.message, {
    this.code = AiSentenceGenerateError.other,
  });

  @override
  String toString() => message;
}
