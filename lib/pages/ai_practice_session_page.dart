import 'dart:convert';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import '../models/ai_sentence_set.dart';
import '../models/ai_sentence.dart';
import '../services/ai_sentence_set_service.dart';
import '../services/ai_sentence_service.dart';
import '../services/ai_service.dart';
import '../services/study_timer_service.dart';

/// 练习阶段
enum _PracticePhase {
  /// 作答中
  answering,

  /// AI 批改中
  evaluating,

  /// 结果显示
  result,

  /// 全部完成
  completed,
}

/// AI 句子练习会话页面
class AiPracticeSessionPage extends StatefulWidget {
  final SentenceSet selectedSet;
  final PracticeMode practiceMode;
  final int extraWordCount;
  final int sentenceLimit;

  /// 错题本练习：直接使用这些句子
  final List<Sentence>? wrongBookSentences;

  /// 是否为错题本练习模式
  final bool isWrongBookPractice;

  /// 句式集练习：使用这些已过滤的句子（跳过重复）
  final List<Sentence>? preFilteredSentences;

  const AiPracticeSessionPage({
    super.key,
    required this.selectedSet,
    required this.practiceMode,
    required this.extraWordCount,
    required this.sentenceLimit,
    this.wrongBookSentences,
    this.isWrongBookPractice = false,
    this.preFilteredSentences,
  });

  @override
  State<AiPracticeSessionPage> createState() => _AiPracticeSessionPageState();
}

class _AiPracticeSessionPageState extends State<AiPracticeSessionPage>
    with SingleTickerProviderStateMixin {
  final SentenceSetService _setService = SentenceSetService.instance;
  final AiSentenceService _sentenceService = AiSentenceService();
  final CancelToken _cancelToken = CancelToken();

  // 练习流程状态
  _PracticePhase _phase = _PracticePhase.answering;
  List<Sentence> _sessionSentences = [];
  int _currentSentenceIndex = 0;
  List<String> _shuffledWords = [];

  // 入门版 - 用户已选的词块
  final List<String> _selectedWords = [];

  // 高阶版 - 文本输入
  final TextEditingController _inputController = TextEditingController();

  // 评测结果
  AiSentenceResult? _lastResult;
  List<PracticeRecord> _completedRecords = [];
  bool _isEvaluating = false;

  // 流式评测状态
  final StringBuffer _streamBuffer = StringBuffer();
  String _streamingText = '';

  // 动画
  late AnimationController _animController;
  late Animation<double> _fadeAnimation;

  Sentence? get _currentSentence =>
      _currentSentenceIndex < _sessionSentences.length
      ? _sessionSentences[_currentSentenceIndex]
      : null;

  int get _totalSentences => _sessionSentences.length;
  int get _remainingSentences => _totalSentences - _currentSentenceIndex - 1;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _animController,
      curve: Curves.easeInOut,
    );
    _animController.forward();
    // 启动句型练习时长计时（区分句式集练习和错题本练习）
    final sessionType = widget.isWrongBookPractice
        ? SessionType.wrongSentencePractice
        : SessionType.sentencePractice;
    StudyTimerService.instance.startSession(sessionType);
    _startPractice();
  }

  @override
  void dispose() {
    // 结束学习时长计时
    StudyTimerService.instance.endSession();
    // 取消未完成的 AI 请求
    _cancelToken.cancel();
    _animController.dispose();
    _inputController.dispose();
    super.dispose();
  }

  // ===== 开始练习 =====
  Future<void> _startPractice() async {
    List<Sentence> sentences;

    if (widget.isWrongBookPractice && widget.wrongBookSentences != null) {
      // 错题本练习：直接使用传入的错题句子
      sentences = List<Sentence>.from(widget.wrongBookSentences!);
    } else if (widget.preFilteredSentences != null) {
      // 句式集练习：使用已过滤的句子
      sentences = List<Sentence>.from(widget.preFilteredSentences!);
    } else {
      // 传统方式：从句式集加载
      sentences = await _setService.getSentences(widget.selectedSet.id!);
      if (sentences.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('该句式集没有句子，请先添加')));
          Navigator.of(context).pop();
        }
        return;
      }
    }

    // 随机打乱并截取
    final shuffled = List<Sentence>.from(sentences)..shuffle(Random());
    final sessionSentences = shuffled.take(widget.sentenceLimit).toList();

    setState(() {
      _sessionSentences = sessionSentences;
      _currentSentenceIndex = 0;
      _completedRecords = [];
      _lastResult = null;
      _selectedWords.clear();
      _inputController.clear();
      _phase = _PracticePhase.answering;
    });

    _prepareBeginnerWords();
    _animController.forward(from: 0);
  }

  /// 准备入门版的乱序词块
  void _prepareBeginnerWords() {
    final sentence = _currentSentence;
    if (sentence == null) return;

    // 将英文原句拆分为单词 + 标点
    final correctWords = sentence.english.split(RegExp(r'\s+')).toList();

    // 从多余词池中随机抽取指定数量
    final pool = List<String>.from(sentence.extraWords);
    pool.shuffle(Random());
    final selectedDistractors = pool.take(widget.extraWordCount).toList();

    // 合并并打乱
    final allWords = [...correctWords, ...selectedDistractors];
    allWords.shuffle(Random());

    setState(() {
      _shuffledWords = allWords;
      _selectedWords.clear();
    });
  }

  // ===== 入门版 - 词块交互 =====
  void _onWordSelected(String word) {
    if (isAllWordsSelected) return;
    setState(() {
      _selectedWords.add(word);
    });
  }

  void _onWordDeselected(int index) {
    setState(() {
      _selectedWords.removeAt(index);
    });
  }

  void _clearSelectedWords() {
    setState(() {
      _selectedWords.clear();
    });
  }

  bool get isAllWordsSelected => _selectedWords.length == _shuffledWords.length;

  /// 获取未被选的词块
  List<String> get _unselectedWords {
    final selectedCount = <String, int>{};
    for (final w in _selectedWords) {
      selectedCount[w] = (selectedCount[w] ?? 0) + 1;
    }

    return _shuffledWords.where((w) {
      final count = selectedCount[w] ?? 0;
      if (count > 0) {
        selectedCount[w] = count - 1;
        return false;
      }
      return true;
    }).toList();
  }

  // ===== 提交评测 =====
  Future<void> _submitAnswer() async {
    final String userAnswer;
    if (widget.practiceMode == PracticeMode.beginner) {
      userAnswer = _selectedWords.join(' ');
      if (userAnswer.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('请先选择单词组成句子')));
        return;
      }
    } else {
      userAnswer = _inputController.text.trim();
      if (userAnswer.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('请输入你的回答')));
        return;
      }
    }

    setState(() {
      _phase = _PracticePhase.evaluating;
      _isEvaluating = true;
      _streamBuffer.clear();
      _streamingText = '';
    });

    try {
      // 流式接收 AI 批改内容，边接收边显示
      await for (final chunk in _sentenceService.evaluateStream(
        sentence: _currentSentence!,
        userAnswer: userAnswer,
        mode: widget.practiceMode,
        shuffledWords: widget.practiceMode == PracticeMode.beginner
            ? _shuffledWords
            : null,
      )) {
        if (!mounted) return;
        _streamBuffer.write(chunk);
        setState(() {
          _streamingText = _streamBuffer.toString();
        });
      }

      if (!mounted) return;

      // 流式内容收齐后解析 JSON
      final jsonStr = AiSentenceService.extractJson(_streamBuffer.toString());
      if (jsonStr == null) {
        throw AiServiceException('AI 返回格式异常，无法解析批改结果');
      }

      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      final result = AiSentenceResult.fromJson(data);

      setState(() {
        _lastResult = result;
        _completedRecords.add(
          PracticeRecord(
            sentence: _currentSentence!,
            userAnswer: userAnswer,
            result: result,
            mode: widget.practiceMode,
          ),
        );
        _isEvaluating = false;
        _phase = _PracticePhase.result;
      });
      _animController.forward(from: 0);
    } on AiServiceException catch (e) {
      if (!mounted) return;
      setState(() {
        _isEvaluating = false;
        _phase = _PracticePhase.answering;
      });
      // 频率限制错误：直接显示 API 端的提示，避免"批改失败"前缀误导用户
      final message = e.isRateLimit ? e.message : '批改失败：$e';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.red),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isEvaluating = false;
        _phase = _PracticePhase.answering;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('批改失败：$e'), backgroundColor: Colors.red),
      );
    }
  }

  // ===== 处理完成的一个句子（加入错题本 / 标记已练习） =====
  Future<void> _handleCompletedSentence(PracticeRecord record) async {
    final threshold = await _sentenceService.getWrongScoreThreshold();

    if (record.result.score <= threshold) {
      // 得分 ≤ 阈值：加入错题本
      await _sentenceService.addWrongSentence(
        WrongSentenceRecord(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          sentenceId: record.sentence.id ?? '',
          setId: record.sentence.setId,
          english: record.sentence.english,
          chinese: record.sentence.chinese,
          score: record.result.score,
          userAnswer: record.userAnswer,
          mode: record.mode,
          createdAt: DateTime.now(),
        ),
      );
    } else {
      // 得分 > 阈值：如果是在错题本练习中，从错题本移除（已掌握）
      if (widget.isWrongBookPractice) {
        await _sentenceService.removeWrongSentence(record.sentence.id ?? '');
      }
      // 如果是句式集练习且得分高，标记为已练习（用于"不重复练习"）
      if (!widget.isWrongBookPractice) {
        await _sentenceService.markSentencePracticed(
          record.sentence.setId,
          record.sentence.id ?? '',
        );
      }
    }
  }

  // ===== 下一题 / 完成 =====
  void _nextSentence() {
    final nextIndex = _currentSentenceIndex + 1;
    if (nextIndex >= _totalSentences) {
      setState(() {
        _phase = _PracticePhase.completed;
      });
      _animController.forward(from: 0);
    } else {
      setState(() {
        _currentSentenceIndex = nextIndex;
        _lastResult = null;
        _selectedWords.clear();
        _inputController.clear();
        _phase = _PracticePhase.answering;
      });
      _prepareBeginnerWords();
      _animController.forward(from: 0);
    }
  }

  void _exitPractice() async {
    // 处理每条练习记录（加入错题本/移除错题本/标记已练习）
    for (final record in _completedRecords) {
      await _handleCompletedSentence(record);
    }
    // 取消未完成的 AI 请求
    _cancelToken.cancel();
    if (mounted) {
      Navigator.of(context).pop(_completedRecords);
    }
  }

  // ===== UI 构建 =====
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _exitPractice();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_getTitle()),
          centerTitle: false,
          actions: [
            if (_phase != _PracticePhase.completed)
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: '退出练习',
                onPressed: _exitPractice,
              ),
          ],
        ),
        body: _buildBody(theme, colorScheme),
      ),
    );
  }

  String _getTitle() {
    switch (_phase) {
      case _PracticePhase.answering:
      case _PracticePhase.evaluating:
      case _PracticePhase.result:
        return '第 ${_currentSentenceIndex + 1}/$_totalSentences 句';
      case _PracticePhase.completed:
        return '练习完成';
    }
  }

  Widget _buildBody(ThemeData theme, ColorScheme colorScheme) {
    switch (_phase) {
      case _PracticePhase.answering:
        return _buildAnswering(theme, colorScheme);
      case _PracticePhase.evaluating:
        return _buildEvaluating(theme, colorScheme);
      case _PracticePhase.result:
        return _buildResult(theme, colorScheme);
      case _PracticePhase.completed:
        return _buildCompleted(theme, colorScheme);
    }
  }

  // ===== 作答页面 =====
  Widget _buildAnswering(ThemeData theme, ColorScheme colorScheme) {
    final sentence = _currentSentence;
    if (sentence == null) return const SizedBox.shrink();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // 题目进度
            LinearProgressIndicator(
              value: (_currentSentenceIndex + 1) / _totalSentences,
            ),
            const SizedBox(height: 16),

            // 中文翻译提示
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    FadeTransition(
                      opacity: _fadeAnimation,
                      child: Column(
                        children: [
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(20),
                            decoration: BoxDecoration(
                              color: colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Column(
                              children: [
                                Icon(
                                  Icons.translate,
                                  color: colorScheme.primary,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  sentence.chinese,
                                  style: theme.textTheme.titleLarge?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 20),

                          // 入门版 - 词块选择
                          if (widget.practiceMode == PracticeMode.beginner)
                            _buildBeginnerInput(theme, colorScheme)
                          else
                            // 高阶版 - 文本输入
                            _buildAdvancedInput(theme, colorScheme),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // 提交按钮
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton.icon(
                onPressed: _isEvaluating ? null : _submitAnswer,
                icon: const Icon(Icons.check_circle_outline),
                label: const Text('提交批改', style: TextStyle(fontSize: 16)),
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ===== 入门版输入交互 =====
  Widget _buildBeginnerInput(ThemeData theme, ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 已选词块展示区
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 60),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colorScheme.surface,
              border: Border.all(color: colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: List.generate(_selectedWords.length, (i) {
                return Chip(
                  label: Text(_selectedWords[i]),
                  deleteIcon: const Icon(Icons.close, size: 16),
                  onDeleted: () => _onWordDeselected(i),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                );
              }),
            ),
          ),
        ),
        if (_selectedWords.isNotEmpty) ...[
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              icon: const Icon(Icons.undo, size: 16),
              label: const Text('清空'),
              onPressed: _clearSelectedWords,
            ),
          ),
        ],
        const SizedBox(height: 16),

        // 可选词块
        Text(
          '选择单词组成句子：',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _unselectedWords.map((word) {
            return ActionChip(
              label: Text(word),
              onPressed: isAllWordsSelected
                  ? null
                  : () => _onWordSelected(word),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            );
          }).toList(),
        ),
      ],
    );
  }

  // ===== 高阶版输入 =====
  Widget _buildAdvancedInput(ThemeData theme, ColorScheme colorScheme) {
    return TextField(
      controller: _inputController,
      decoration: InputDecoration(
        hintText: '输入英文句子...',
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        contentPadding: const EdgeInsets.all(16),
        filled: true,
        fillColor: colorScheme.surface,
      ),
      maxLines: 4,
      minLines: 3,
      textInputAction: TextInputAction.newline,
      style: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
    );
  }

  // ===== 加载/评测中 =====
  Widget _buildEvaluating(ThemeData theme, ColorScheme colorScheme) {
    // 流式内容已到达时，实时显示 AI 输出
    if (_streamingText.isNotEmpty) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Row(
                children: [
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'AI 正在批改...',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: SingleChildScrollView(
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      _streamingText,
                      style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 64,
            height: 64,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          const SizedBox(height: 24),
          Text(
            'AI 正在批改...',
            style: theme.textTheme.titleMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '请稍候，正在分析你的回答',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  // ===== 结果显示 =====
  Widget _buildResult(ThemeData theme, ColorScheme colorScheme) {
    final result = _lastResult;
    if (result == null) return const SizedBox.shrink();
    final sentence = _currentSentence!;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // 进度
            LinearProgressIndicator(
              value: (_currentSentenceIndex + 1) / _totalSentences,
            ),
            const SizedBox(height: 16),

            Expanded(
              child: SingleChildScrollView(
                child: FadeTransition(
                  opacity: _fadeAnimation,
                  child: Column(
                    children: [
                      // 评分
                      _buildScoreBadge(theme, colorScheme, result.score),
                      const SizedBox(height: 16),

                      // 正确答案
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: colorScheme.primaryContainer.withValues(
                            alpha: 0.3,
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '参考答案：',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              sentence.english,
                              style: theme.textTheme.bodyLarge?.copyWith(
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),

                      // 批改原文（带高亮标记）
                      if (result.markup.isNotEmpty)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '你的回答：',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 4),
                              _buildMarkupText(
                                theme: theme,
                                markup: result.markup,
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 12),

                      // 批注
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: colorScheme.secondaryContainer.withValues(
                            alpha: 0.3,
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.rate_review,
                                  size: 16,
                                  color: colorScheme.secondary,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '批注',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              result.comment,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                height: 1.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // 下一题 / 完成
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton.icon(
                onPressed: _nextSentence,
                icon: Icon(
                  _remainingSentences > 0
                      ? Icons.arrow_forward
                      : Icons.done_all,
                ),
                label: Text(
                  _remainingSentences > 0
                      ? '下一题（还剩 $_remainingSentences 句）'
                      : '查看总结',
                  style: const TextStyle(fontSize: 16),
                ),
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 构建评分徽章
  Widget _buildScoreBadge(ThemeData theme, ColorScheme colorScheme, int score) {
    Color scoreColor;
    if (score >= 9) {
      scoreColor = Colors.green;
    } else if (score >= 7) {
      scoreColor = Colors.orange;
    } else if (score >= 5) {
      scoreColor = Colors.deepOrange;
    } else {
      scoreColor = Colors.red;
    }

    return Container(
      width: 120,
      height: 120,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: scoreColor.withValues(alpha: 0.1),
        border: Border.all(color: scoreColor, width: 3),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$score',
              style: theme.textTheme.displaySmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: scoreColor,
              ),
            ),
            Text(
              '/10',
              style: theme.textTheme.bodySmall?.copyWith(color: scoreColor),
            ),
          ],
        ),
      ),
    );
  }

  /// 解析 HTML markup 标签为 RichText
  Widget _buildMarkupText({required ThemeData theme, required String markup}) {
    // 解析 <red>...</red> 和 <yellow>...</yellow> 标签
    final spans = <InlineSpan>[];
    final regex = RegExp(r'<(\w+)>(.*?)</\1>');
    int lastEnd = 0;

    for (final match in regex.allMatches(markup)) {
      // 添加标签前的普通文本
      if (match.start > lastEnd) {
        spans.add(
          TextSpan(
            text: markup.substring(lastEnd, match.start),
            style: TextStyle(color: Colors.green.shade700),
          ),
        );
      }

      final tag = match.group(1)!;
      final content = match.group(2)!;
      Color textColor;
      if (tag == 'red') {
        textColor = Colors.red;
      } else {
        textColor = Colors.orange.shade700;
      }

      spans.add(
        TextSpan(
          text: content,
          style: TextStyle(
            color: textColor,
            fontWeight: FontWeight.w600,
            decoration: TextDecoration.underline,
            decorationColor: textColor,
          ),
        ),
      );

      lastEnd = match.end;
    }

    // 剩余文本
    if (lastEnd < markup.length) {
      spans.add(
        TextSpan(
          text: markup.substring(lastEnd),
          style: TextStyle(color: Colors.green.shade700),
        ),
      );
    }

    // 如果没有任何标签，整句为绿色（正确）
    if (spans.isEmpty && markup.isNotEmpty) {
      spans.add(
        TextSpan(
          text: markup,
          style: TextStyle(color: Colors.green.shade700),
        ),
      );
    }

    return RichText(
      text: TextSpan(
        style: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
        children: spans,
      ),
    );
  }

  // ===== 完成页面 =====
  Widget _buildCompleted(ThemeData theme, ColorScheme colorScheme) {
    final total = _completedRecords.length;
    final avgScore = total > 0
        ? _completedRecords.fold(0, (sum, r) => sum + r.result.score) / total
        : 0.0;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Expanded(
              child: FadeTransition(
                opacity: _fadeAnimation,
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        avgScore >= 8
                            ? Icons.emoji_events
                            : avgScore >= 5
                            ? Icons.thumb_up
                            : Icons.trending_up,
                        size: 80,
                        color: avgScore >= 8
                            ? Colors.amber
                            : colorScheme.primary,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '练习完成！',
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 24),

                      // 统计数据
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          children: [
                            _buildStatRow('练习句数', '$total 句', colorScheme),
                            const SizedBox(height: 12),
                            _buildStatRow(
                              '平均分',
                              '${avgScore.toStringAsFixed(1)} / 10',
                              colorScheme,
                            ),
                            const SizedBox(height: 12),
                            _buildStatRow(
                              '模式',
                              widget.practiceMode == PracticeMode.beginner
                                  ? '入门版'
                                  : '高阶版',
                              colorScheme,
                            ),
                            const SizedBox(height: 12),
                            _buildStatRow(
                              '练习类型',
                              widget.isWrongBookPractice ? '错题本练习' : '句式集练习',
                              colorScheme,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton.icon(
                onPressed: _exitPractice,
                icon: const Icon(Icons.replay),
                label: const Text('返回', style: TextStyle(fontSize: 16)),
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatRow(String label, String value, ColorScheme colorScheme) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(fontSize: 15)),
        Text(
          value,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }
}
