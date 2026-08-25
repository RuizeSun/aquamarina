import 'dart:math';

import 'package:flutter/material.dart';
import '../../services/learning_service.dart';
import '../../services/study_timer_service.dart';

/// 将拼写成绩映射为复习计划中的结果标记。
///
/// - 首拼即对 → easy
/// - 最终拼对但有失误 → hard
/// - 3 次均未拼对 → forgot
String mapSpellingResult({
  required bool firstTryCorrect,
  required bool everCorrect,
}) {
  if (firstTryCorrect) return 'easy';
  if (everCorrect) return 'hard';
  return 'forgot';
}

/// 弹出询问是否进入拼写练习的对话框。
///
/// 返回 `true` 表示用户选择进入拼写，`false` 表示跳过。
Future<bool> showSpellingPrompt(
  BuildContext context, {
  required int wordCount,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('拼写练习'),
      content: Text('是否对本组 $wordCount 个单词进行拼写练习？'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('跳过'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('进入拼写'),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// 拼写练习页
///
/// 显示中文释义，要求用户写出英文原词。
/// 拼错的词追加到队列末尾重新拼写，每个词最多拼写 3 次（含第一次）。
/// 拼写完成后自动返回上一页（显示总结画面）。
class SpellingPage extends StatefulWidget {
  /// 词 → 中文释义
  final Map<String, String> entries;

  /// 是否在拼写完成后将结果写入记忆复习计划。
  ///
  /// 为 `true` 时（如「快速拼写复习」入口），拼写结束后会根据
  /// 每个词的成绩调用 [LearningService.saveLearningBatchResults]：
  /// 首拼即对 → easy，最终拼对但有失误 → hard，3 次均失败 → forgot，
  /// 从而推进复习调度、更新复习次数并计入每日统计。
  /// 为 `false`（默认，学习/复习完成后的附加拼写）时不写入，避免重复计次。
  final bool recordResults;

  const SpellingPage({super.key, required this.entries, this.recordResults = false});

  @override
  State<SpellingPage> createState() => _SpellingPageState();
}

class _SpellingPageState extends State<SpellingPage>
    with SingleTickerProviderStateMixin {
  // 待拼写队列（词 → 已拼写次数）
  final List<String> _queue = [];
  final Map<String, int> _attemptCount = {};

  // 每个词是否首拼即对 / 是否最终拼对（用于 recordResults 时生成复习结果）
  final Map<String, bool> _firstTryCorrect = {};
  final Map<String, bool> _everCorrect = {};

  final TextEditingController _inputController = TextEditingController();
  final FocusNode _inputFocus = FocusNode();

  // 已完成的拼写次数（用于进度条）
  int _completedSteps = 0;

  String? _currentWord;
  bool _showingResult = false;
  bool _lastCorrect = false;

  late AnimationController _animController;
  late Animation<double> _fadeAnimation;

  /// 所有词最多出现的总次数
  int get _totalAttempts => widget.entries.length * 3;

  @override
  void initState() {
    super.initState();
    // 启动学习时长计时（计入「单词拼写」类型）
    StudyTimerService.instance.startSession(SessionType.wordSpelling);
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _animController,
      curve: Curves.easeInOut,
    );
    _animController.forward();

    // 随机打乱词序
    final words = widget.entries.keys.toList()..shuffle(Random());
    _queue.addAll(words);
    for (final w in words) {
      _attemptCount[w] = 0;
    }
    _nextWord();
  }

  @override
  void dispose() {
    // 结束学习时长计时
    StudyTimerService.instance.endSession();
    _inputController.dispose();
    _inputFocus.dispose();
    _animController.dispose();
    super.dispose();
  }

  /// 进入下一个待拼写词；队列为空时（可选）保存结果并自动返回
  Future<void> _nextWord() async {
    if (_queue.isEmpty) {
      if (widget.recordResults) {
        await _saveResults();
      }
      if (mounted) Navigator.of(context).pop();
      return;
    }
    setState(() {
      _currentWord = _queue.removeAt(0);
      _showingResult = false;
      _lastCorrect = false;
      _inputController.clear();
    });
    _animController.forward(from: 0);
    // 等待动画后聚焦输入框
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _inputFocus.requestFocus();
    });
  }

  /// 确认拼写
  void _onSubmit() {
    if (_showingResult) return;
    final input = _inputController.text.trim().toLowerCase();
    if (input.isEmpty) return;

    final word = _currentWord!;
    final correct = input == word.trim().toLowerCase();
    final attempts = (_attemptCount[word] ?? 0) + 1;
    setState(() {
      _attemptCount[word] = attempts;
      _completedSteps++;
      // 记录首拼与最终成绩（供 recordResults 生成复习结果）
      if (attempts == 1) {
        _firstTryCorrect[word] = correct;
      }
      _everCorrect[word] = correct || (_everCorrect[word] ?? false);
      // 最后一题（拼对或已达 3 次上限、且队列中无其他词）提交后进度条满格
      if (_queue.isEmpty && (correct || attempts >= 3)) {
        _completedSteps = _totalAttempts;
      }
      _showingResult = true;
      _lastCorrect = correct;
    });
    _animController.forward(from: 0);
  }

  /// 进入下一个词；拼错且未达上限的词追加到队列末尾
  void _onNext() {
    final word = _currentWord!;
    final attempts = _attemptCount[word] ?? 0;
    if (!_lastCorrect && attempts < 3) {
      _queue.add(word);
    }
    _nextWord();
  }

  /// 将拼写成绩写入记忆复习计划（仅 recordResults 时调用）。
  ///
  /// 首拼即对 → easy；最终拼对但有失误 → hard；3 次均失败 → forgot。
  Future<void> _saveResults() async {
    final results = <String, String>{};
    for (final word in widget.entries.keys) {
      results[word] = mapSpellingResult(
        firstTryCorrect: _firstTryCorrect[word] ?? false,
        everCorrect: _everCorrect[word] ?? false,
      );
    }
    if (results.isEmpty) return;
    try {
      await LearningService.saveLearningBatchResults(results, isReview: true);
    } catch (e) {
      // 保存失败不影响拼写流程
      debugPrint('SpellingPage._saveResults failed: $e');
    }
  }

  // ─── UI ──────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return PopScope(
      canPop: true,
      child: Column(
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: _completedSteps / _totalAttempts),
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            builder: (context, value, _) =>
                LinearProgressIndicator(value: value),
          ),
          Expanded(
            child: Scaffold(
              appBar: AppBar(title: const Text('拼写练习')),
              body: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      Expanded(
                        child: FadeTransition(
                          opacity: _fadeAnimation,
                          child: _buildSpellingBody(theme, colorScheme),
                        ),
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _showingResult ? _onNext : _onSubmit,
                          icon: Icon(
                            _showingResult ? Icons.arrow_forward : Icons.check,
                          ),
                          label: Text(
                            _showingResult ? '下一个' : '确认',
                            style: const TextStyle(fontSize: 16),
                          ),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSpellingBody(ThemeData theme, ColorScheme colorScheme) {
    final word = _currentWord ?? '';
    final meaning = widget.entries[word] ?? '';

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 32),
          Text(
            '请根据中文释义拼写单词',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          // 中文释义卡片
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              meaning,
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 32),
          // 输入框
          TextField(
            controller: _inputController,
            focusNode: _inputFocus,
            enabled: !_showingResult,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.none,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
            decoration: InputDecoration(
              hintText: '输入英文单词',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              filled: true,
              fillColor: colorScheme.surface,
            ),
            onSubmitted: (_) => _onSubmit(),
          ),
          const SizedBox(height: 24),
          // 结果区域
          if (_showingResult) _buildResult(theme, colorScheme),
        ],
      ),
    );
  }

  Widget _buildResult(ThemeData theme, ColorScheme colorScheme) {
    final word = _currentWord ?? '';

    if (_lastCorrect) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.green.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            const Icon(Icons.check_circle, color: Colors.green, size: 40),
            const SizedBox(height: 8),
            const Text(
              '拼写正确！',
              style: TextStyle(
                color: Colors.green,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              word,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Icon(Icons.cancel, color: colorScheme.error, size: 40),
          const SizedBox(height: 8),
          Text(
            '拼写不正确',
            style: TextStyle(
              color: colorScheme.error,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '正确拼写：$word',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}
