import 'dart:math';

import 'package:flutter/material.dart';

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

  const SpellingPage({super.key, required this.entries});

  @override
  State<SpellingPage> createState() => _SpellingPageState();
}

class _SpellingPageState extends State<SpellingPage>
    with SingleTickerProviderStateMixin {
  // 待拼写队列（词 → 已拼写次数）
  final List<String> _queue = [];
  final Map<String, int> _attemptCount = {};

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
    _inputController.dispose();
    _inputFocus.dispose();
    _animController.dispose();
    super.dispose();
  }

  /// 进入下一个待拼写词；队列为空时自动返回
  void _nextWord() {
    if (_queue.isEmpty) {
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
                            textScaler: TextScaler.noScaling,
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
