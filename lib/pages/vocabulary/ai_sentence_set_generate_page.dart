import 'package:flutter/material.dart';

import '../../models/ai_profile.dart';
import '../../models/ai_sentence.dart';
import '../../models/ai_sentence_set.dart';
import '../../models/sentence_difficulty.dart';
import '../../services/ai_profile_service.dart';
import '../../services/ai_sentence_generate_service.dart';
import '../../services/ai_sentence_set_service.dart';
import '../../services/ai_usage_service.dart';
import '../settings/settings_page.dart';

/// 生成结束后的回传结果（供调用方提示用户）
class SentenceSetGenerationOutcome {
  final String setName;
  final int sentenceCount;
  final int failedBatches;
  final int totalBatches;

  const SentenceSetGenerationOutcome({
    required this.setName,
    required this.sentenceCount,
    required this.failedBatches,
    required this.totalBatches,
  });

  bool get isPartial => failedBatches > 0;
}

/// 「AI 生成句式集」页面：选定难度与规模 → 展示 token / 费用预估 → 二次确认 → 生成入库。
///
/// 仅支持标准 OpenAI 兼容 / DeepSeek 配置；Aquamarina 官方配置会被拦截并给出指引。
class AiSentenceSetGeneratePage extends StatefulWidget {
  /// 来源词书标题（用于默认句式集名称）
  final String bookTitle;

  /// 用户选中的单词
  final List<String> words;

  /// 可注入的 AI 配置服务（默认新建实例；测试用）
  final AiProfileService? profileService;

  /// 可注入的生成器（默认基于 [profileService] 新建；测试用）
  final AiSentenceGenerator? generator;

  const AiSentenceSetGeneratePage({
    super.key,
    required this.bookTitle,
    required this.words,
    this.profileService,
    this.generator,
  });

  @override
  State<AiSentenceSetGeneratePage> createState() =>
      _AiSentenceSetGeneratePageState();
}

class _AiSentenceSetGeneratePageState extends State<AiSentenceSetGeneratePage> {
  late final AiProfileService _profileService;
  late final AiSentenceGenerator _generator;
  final SentenceSetService _setService = SentenceSetService.instance;
  final TextEditingController _nameController = TextEditingController();

  AiProfile? _profile;

  /// 本功能不可用的原因（未配置 / Aquamarina / 缺 API Key）
  String? _blockedReason;

  List<WordPromptEntry> _entries = [];
  SentenceGenerationEstimate? _estimate;

  SentenceDifficulty _difficulty = SentenceDifficulty.starter;
  int _sentencesPerWord = 1;

  bool _loading = true;
  bool _generating = false;
  bool _nameEditedByUser = false;
  int _progressDone = 0;
  int _progressTotal = 0;

  /// 已流式收到的句子数
  int _generatedCount = 0;

  /// 流式生成过程中最近收到的几句英文，用于实时反馈 AI 正在写什么
  final List<String> _liveSentences = [];

  /// 实时区保留的句子条数
  static const int _liveSentenceLimit = 3;

  /// DeepSeek 余额（非 DeepSeek 配置保持为 null）
  double? _balance;
  String? _balanceError;

  bool get _tooManyWords =>
      widget.words.length > AiSentenceGenerator.maxWordsPerGeneration;

  @override
  void initState() {
    super.initState();
    _profileService = widget.profileService ?? AiProfileService();
    _generator =
        widget.generator ??
        AiSentenceGenerator(profileService: _profileService);
    _nameController.text = _defaultSetName();
    _nameController.addListener(() => _nameEditedByUser = true);
    _init();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    if (widget.words.isEmpty) {
      setState(() {
        _blockedReason = '没有选中任何单词';
        _loading = false;
      });
      return;
    }

    try {
      final profile = await _generator.resolveProfile();
      final entries = await _generator.loadWordEntries(widget.words);
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _entries = entries;
        _loading = false;
      });
      _recompute();
      await _loadBalance(profile);
    } on AiSentenceGenerateException catch (e) {
      if (!mounted) return;
      setState(() {
        _blockedReason = e.message;
        _loading = false;
      });
    }
  }

  Future<void> _loadBalance(AiProfile profile) async {
    if (!profile.isDeepSeek) return;
    try {
      final balance = await _profileService.checkBalance(profile);
      if (!mounted) return;
      if (!balance.isAvailable) {
        setState(() => _balanceError = '该账号暂时无法查询余额');
        return;
      }
      var total = 0.0;
      for (final info in balance.balanceInfos) {
        total += info.totalAsDouble;
      }
      setState(() {
        _balance = total;
        _balanceError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _balanceError = '余额查询失败：$e');
    }
  }

  String _defaultSetName() =>
      '${widget.bookTitle} · ${_difficulty.label}句式';

  String _defaultDescription() {
    final count = _entries.isEmpty ? widget.words.length : _entries.length;
    return '由词书「${widget.bookTitle}」中的 $count 个单词，'
        '按 CEFR ${_difficulty.cefr}（${_difficulty.label}）难度 AI 生成';
  }

  void _recompute() {
    final profile = _profile;
    if (profile == null) return;
    setState(() {
      _estimate = _generator.estimate(
        profile: profile,
        entries: _entries,
        difficulty: _difficulty,
        sentencesPerWord: _sentencesPerWord,
      );
    });
  }

  void _onDifficultyChanged(SentenceDifficulty difficulty) {
    setState(() {
      _difficulty = difficulty;
      if (!_nameEditedByUser) {
        _nameController.text = _defaultSetName();
      }
    });
    _recompute();
  }

  void _onSentencesPerWordChanged(int value) {
    setState(() => _sentencesPerWord = value);
    _recompute();
  }

  // ── 生成流程 ────────────────────────────────────────

  Future<void> _startGeneration() async {
    final profile = _profile;
    final estimate = _estimate;
    if (profile == null || estimate == null || _generating) return;

    if (_tooManyWords) {
      _showSnack('单次最多生成 ${AiSentenceGenerator.maxWordsPerGeneration} 个单词的句式集，请减少选择');
      return;
    }

    // 二次确认：把 token / 费用 / 余额预测再摆一次，用户确认后才真正发起请求
    final confirmed = await _showConfirmDialog(profile, estimate);
    if (confirmed != true || !mounted) return;

    setState(() {
      _generating = true;
      _progressDone = 0;
      _progressTotal = estimate.requestCount;
      _generatedCount = 0;
      _liveSentences.clear();
    });

    try {
      final result = await _generator.generate(
        profile: profile,
        entries: _entries,
        difficulty: _difficulty,
        sentencesPerWord: _sentencesPerWord,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _progressDone = done;
            _progressTotal = total;
          });
        },
        // 流式回调：每解析出一句就立刻上屏，形成"AI 正在写句子"的实时反馈
        onSentence: (sentence) {
          if (!mounted) return;
          setState(() {
            _generatedCount++;
            _liveSentences.add(sentence.english);
            if (_liveSentences.length > _liveSentenceLimit) {
              _liveSentences.removeAt(0);
            }
          });
        },
      );
      if (!mounted) return;
      await _persistResult(result);
    } on AiSentenceGenerateException catch (e) {
      if (!mounted) return;
      setState(() => _generating = false);
      await _showErrorDialog('生成失败', e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _generating = false);
      await _showErrorDialog('生成失败', '$e');
    }
  }

  /// 生成完成后写入句式集，并回传结果给调用方
  Future<void> _persistResult(SentenceGenerationResult result) async {
    await _setService.load();
    final desiredName = _nameController.text.trim().isEmpty
        ? _defaultSetName()
        : _nameController.text.trim();
    final uniqueName = _setService.generateUniqueSetName(desiredName);

    final set = await _setService.addSet(
      SentenceSet(name: uniqueName, description: _defaultDescription()),
    );
    await _setService.addSentences(
      set.id!,
      result.sentences
          .map(
            (g) => Sentence(
              setId: set.id!,
              english: g.english,
              chinese: g.chinese,
              extraWords: g.extraWords,
            ),
          )
          .toList(),
    );

    if (!mounted) return;
    final outcome = SentenceSetGenerationOutcome(
      setName: uniqueName,
      sentenceCount: result.sentences.length,
      failedBatches: result.failedBatches,
      totalBatches: result.totalBatches,
    );

    if (outcome.isPartial) {
      await _showErrorDialog(
        '部分内容生成失败',
        '已创建句式集「${outcome.setName}」，共 ${outcome.sentenceCount} 句。\n'
            '其中 ${outcome.failedBatches}/${outcome.totalBatches} 批请求失败，'
            '可稍后重新生成缺失的部分。',
      );
    }
    if (!mounted) return;
    Navigator.of(context).pop(outcome);
  }

  Future<bool?> _showConfirmDialog(
    AiProfile profile,
    SentenceGenerationEstimate estimate,
  ) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认开始生成'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '将调用「${profile.name}」发起 ${estimate.requestCount} 次请求，'
                '预计生成 ${estimate.totalSentences} 句。',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              _estimateRows(estimate, compact: true),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  estimate.pricingConfigured
                      ? '预估费用仅供参考，实际用量与扣费以服务商账单为准。'
                      : '当前配置未填写计费价格，无法预估费用；实际扣费以服务商账单为准。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认生成'),
          ),
        ],
      ),
    );
  }

  Future<void> _showErrorDialog(String title, String message) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(message)),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsPage()),
    );
    if (!mounted) return;
    // 从设置页返回后重新解析配置（用户可能刚新建/切换了默认配置）
    setState(() {
      _loading = true;
      _blockedReason = null;
      _profile = null;
      _entries = [];
      _estimate = null;
      _balance = null;
      _balanceError = null;
    });
    await _init();
  }

  // ── UI ──────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI 生成句式集')),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_blockedReason != null) {
      return _buildBlockedState(theme, colorScheme);
    }

    final estimate = _estimate;
    final profile = _profile;
    if (estimate == null || profile == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        _buildWordSummaryCard(theme, colorScheme),
        const SizedBox(height: 16),
        _buildProfileCard(profile, theme, colorScheme),
        const SizedBox(height: 16),
        Text('句式难度', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          '难度会作为 CEFR 等级写入提示词，AI 将按对应水平控制词汇与句式复杂度',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: SentenceDifficulty.values.map((d) {
            final selected = d == _difficulty;
            return ChoiceChip(
              label: Text(d.displayName),
              selected: selected,
              onSelected: _generating
                  ? null
                  : (_) => _onDifficultyChanged(d),
            );
          }).toList(),
        ),
        const SizedBox(height: 16),
        Text('每个单词生成句数', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 1, label: Text('1 句')),
            ButtonSegment(value: 2, label: Text('2 句')),
            ButtonSegment(value: 3, label: Text('3 句')),
          ],
          selected: {_sentencesPerWord},
          onSelectionChanged: _generating
              ? null
              : (selected) => _onSentencesPerWordChanged(selected.first),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _nameController,
          enabled: !_generating,
          decoration: const InputDecoration(
            labelText: '句式集名称',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 20),
        _buildEstimateCard(estimate, profile, theme, colorScheme),
        const SizedBox(height: 20),
        if (_tooManyWords)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _warningBox(
              theme,
              colorScheme,
              Icons.error_outline,
              '单次最多生成 ${AiSentenceGenerator.maxWordsPerGeneration} 个单词的句式集，'
                  '当前已选 ${widget.words.length} 个，请返回减少选择。',
              color: colorScheme.error,
            ),
          ),
        if (_generating) ...[
          _buildProgressCard(theme, colorScheme),
          const SizedBox(height: 12),
        ],
        SizedBox(
          height: 52,
          child: FilledButton.icon(
            onPressed: (_generating || _tooManyWords) ? null : _startGeneration,
            icon: _generating
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_awesome),
            label: Text(_generating ? '生成中…' : '开始生成'),
          ),
        ),
      ],
    );
  }

  /// 生成中的实时反馈：批次进度 + 最近几句 AI 正在写的英文
  Widget _buildProgressCard(ThemeData theme, ColorScheme colorScheme) {
    final hasLive = _liveSentences.isNotEmpty;
    return Card(
      color: colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  'AI 正在生成…',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  '已生成 $_generatedCount 句',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: _progressTotal > 0 ? _progressDone / _progressTotal : null,
              borderRadius: BorderRadius.circular(4),
              minHeight: 6,
            ),
            const SizedBox(height: 6),
            Text(
              '已完成 $_progressDone / $_progressTotal 批',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            if (!hasLive)
              Text(
                '等待 AI 返回第一句…',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              )
            else ...[
              Text(
                '实时输出（最新 ${_liveSentences.length} 句）',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 6),
              for (var i = 0; i < _liveSentences.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    _liveSentences[i],
                    style: theme.textTheme.bodyMedium?.copyWith(
                      // 最新一句高亮，其余逐级淡出，形成"正在往下写"的观感
                      color: i == _liveSentences.length - 1
                          ? colorScheme.onSurface
                          : colorScheme.onSurfaceVariant.withValues(
                              alpha: 0.4 + 0.2 * i,
                            ),
                      fontWeight: i == _liveSentences.length - 1
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildBlockedState(ThemeData theme, ColorScheme colorScheme) {    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.smart_toy_outlined, size: 72, color: colorScheme.error),
            const SizedBox(height: 16),
            Text(
              '当前无法使用本功能',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _blockedReason ?? '',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _openSettings,
              icon: const Icon(Icons.settings_outlined),
              label: const Text('前往 AI 配置'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWordSummaryCard(ThemeData theme, ColorScheme colorScheme) {
    const previewLimit = 24;
    final words = widget.words;
    final preview = words.take(previewLimit).toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.menu_book_outlined, size: 18, color: colorScheme.primary),
                const SizedBox(width: 6),
                Text(
                  '已选 ${words.length} 个单词',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Flexible(
                  child: Text(
                    widget.bookTitle,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                ...preview.map(
                  (w) => Chip(
                    label: Text(w),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
                if (words.length > previewLimit)
                  Chip(
                    label: Text('…还有 ${words.length - previewLimit} 个'),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProfileCard(
    AiProfile profile,
    ThemeData theme,
    ColorScheme colorScheme,
  ) {
    final thinkingText = profile.isDeepSeek && profile.enableThinking
        ? '思考已开启（effort: ${profile.reasoningEffort ?? '默认'}）'
        : '思考未开启';
    final pricingText = profile.pricing == null
        ? '未配置价格'
        : profile.pricing!.isPerRequest
        ? '按请求计费'
        : '按 token 计费';
    return Card(
      child: ListTile(
        leading: Icon(Icons.memory, color: colorScheme.primary),
        title: Text('${profile.name} · ${profile.model}'),
        subtitle: Text('$thinkingText · $pricingText · max_tokens ${profile.maxTokens}'),
      ),
    );
  }

  Widget _buildEstimateCard(
    SentenceGenerationEstimate estimate,
    AiProfile profile,
    ThemeData theme,
    ColorScheme colorScheme,
  ) {
    final warnings = <Widget>[];

    if (estimate.thinkingEnabled) {
      warnings.add(
        _warningBox(
          theme,
          colorScheme,
          Icons.psychology_alt_outlined,
          '已开启思考模式，思考内容按输出 token 计费，实际消耗与耗时都会明显增加'
          '（按 ×${estimate.thinkingMultiplier} 估算）。',
        ),
      );
    }
    if (!estimate.pricingConfigured) {
      warnings.add(
        _warningBox(
          theme,
          colorScheme,
          Icons.receipt_long_outlined,
          '当前配置未填写完整的计费价格，无法预估费用。'
          '可在「设置 → AI 配置 → 计费与货币」中补充。',
        ),
      );
    } else if (estimate.isPerRequest) {
      warnings.add(
        _warningBox(
          theme,
          colorScheme,
          Icons.receipt_long_outlined,
          '当前配置按请求固定价计费，与 token 用量无关。',
        ),
      );
    }
    if (estimate.cacheDiscountApplied) {
      warnings.add(
        _warningBox(
          theme,
          colorScheme,
          Icons.bolt_outlined,
          '已按 DeepSeek 上下文缓存估算输入费用：第 2 批起各请求共享的系统提示词前缀'
          '预计命中缓存（约 ${_group(estimate.cacheHitTokens)} tokens 按缓存命中单价计费）。'
          '实际命中情况由服务端缓存状态决定，最终以服务商账单为准。',
        ),
      );
    }
    final balance = _balance;
    final cost = estimate.cost;
    if (profile.isDeepSeek) {
      if (_balanceError != null) {
        warnings.add(
          _warningBox(theme, colorScheme, Icons.account_balance_wallet_outlined, _balanceError!),
        );
      } else if (balance != null && cost != null && balance < cost) {
        warnings.add(
          _warningBox(
            theme,
            colorScheme,
            Icons.warning_amber_rounded,
            '账户余额预估不足，请先充值后再生成。',
            color: colorScheme.error,
          ),
        );
      } else if (balance != null &&
          profile.balanceThreshold != null &&
          balance < profile.balanceThreshold!) {
        warnings.add(
          _warningBox(
            theme,
            colorScheme,
            Icons.warning_amber_rounded,
            '余额已低于配置中设置的停止阈值（${profile.balanceThreshold}）。',
            color: colorScheme.error,
          ),
        );
      }
    }

    return Card(
      color: colorScheme.primaryContainer.withValues(alpha: 0.25),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.calculate_outlined, size: 18, color: colorScheme.primary),
                const SizedBox(width: 6),
                Text(
                  '消耗预估',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '生成前估算，实际用量以服务端返回为准',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            _estimateRows(estimate, compact: false),
            for (final warning in warnings) ...[
              const SizedBox(height: 10),
              warning,
            ],
          ],
        ),
      ),
    );
  }

  /// 预估明细：token 与费用（确认弹窗与页面共用同一份数据）
  Widget _estimateRows(
    SentenceGenerationEstimate estimate, {
    required bool compact,
  }) {
    final rows = <Widget>[
      _infoRow('难度', '${_difficulty.label}（CEFR ${_difficulty.cefr}）'),
      _infoRow('规模', '${widget.words.length} 词 × ${estimate.sentencesPerWord} 句 = ${estimate.totalSentences} 句'),
      _infoRow('请求次数', '${estimate.requestCount} 次（每次最多 ${estimate.wordsPerRequest} 词）'),
      _infoRow(
        '输入 tokens',
        estimate.cacheDiscountApplied
            ? '约 ${_group(estimate.promptTokens)}'
                  '（其中缓存命中约 ${_group(estimate.cacheHitTokens)}）'
            : '约 ${_group(estimate.promptTokens)}',
      ),
      _infoRow(
        '输出 tokens',
        '约 ${_group(estimate.completionTokens)}'
        '${estimate.thinkingEnabled ? '（含思考开销）' : ''}',
      ),
      _infoRow('合计 tokens', '约 ${_group(estimate.totalTokens)}'),
      _infoRow(
        '预估费用',
        estimate.formatCost() ?? '无法预估（未配置价格）',
        emphasize: estimate.pricingConfigured,
      ),
    ];
    if (estimate.isPerRequest && estimate.pricingConfigured) {
      rows.add(_infoRow('计费方式', '按请求固定价 × ${estimate.requestCount} 次'));
    }
    if (estimate.cacheDiscountApplied) {
      rows.add(
        _infoRow(
          '输入计费',
          '缓存命中 ${_group(estimate.cacheHitTokens)} + '
              '未命中 ${_group(estimate.cacheMissTokens)} tokens',
        ),
      );
    }
    if (_profile?.isDeepSeek ?? false) {
      rows.add(_infoRow('当前余额', _balance != null ? '¥${_balance!.toStringAsFixed(2)}' : '—'));
      if (_balance != null) {
        final cost = estimate.cost;
        final remaining = cost == null ? _balance! : _balance! - cost;
        rows.add(
          _infoRow(
            '消耗后余额',
            '约 ¥${remaining.toStringAsFixed(2)}',
            emphasize: true,
            danger: remaining < 0,
          ),
        );
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) SizedBox(height: compact ? 4 : 6),
          rows[i],
        ],
      ],
    );
  }

  Widget _infoRow(
    String label,
    String value, {
    bool emphasize = false,
    bool danger = false,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final valueColor = danger
        ? colorScheme.error
        : emphasize
        ? colorScheme.primary
        : colorScheme.onSurface;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 92,
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: valueColor,
              fontWeight: emphasize ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),
      ],
    );
  }

  Widget _warningBox(
    ThemeData theme,
    ColorScheme colorScheme,
    IconData icon,
    String message, {
    Color? color,
  }) {
    final effective = color ?? colorScheme.onSurfaceVariant;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: color != null ? Border.all(color: effective.withValues(alpha: 0.5)) : null,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: effective),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(color: effective),
            ),
          ),
        ],
      ),
    );
  }

  /// 千位分隔（预估值为量级展示，无需按币种格式设置）
  static String _group(int value) =>
      AiUsageService.formatMoney(
        value.toDouble(),
        symbol: '',
        decimals: 0,
        grouping: true,
      );
}
