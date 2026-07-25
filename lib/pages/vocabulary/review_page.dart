import 'package:flutter/material.dart';
import '../../models/word_entry.dart';
import '../../services/dictionary_service.dart';
import '../../services/learning_service.dart';

/// 将数据库中的字面 \n 替换为真正的换行符
String _normalizeNewlines(String? text) {
  if (text == null) return '';
  return text.replaceAll('\\n', '\n');
}

/// 学习类型：新词学习（第二遍）或复习
enum ReviewType { learning, review }

class ReviewPage extends StatefulWidget {
  final List<String> words;
  final int bookId;
  final ReviewType reviewType;

  const ReviewPage({
    super.key,
    required this.words,
    required this.bookId,
    this.reviewType = ReviewType.learning,
  });

  @override
  State<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends State<ReviewPage>
    with SingleTickerProviderStateMixin {
  int _currentIndex = 0;
  bool _showingAnswer = false;
  bool _isProcessing = false;
  late AnimationController _animController;
  late Animation<double> _fadeAnimation;

  // 浏览阶段模式
  bool _isBrowsePhase = false;

  // 第一轮选择：null=未选, false=忘记了, true=我记得
  bool? _firstChoice;
  // 第二轮选择：null=未选, false=记错了, true=继续
  bool? _secondChoice;

  final Map<int, WordEntry?> _entryCache = {};

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

    // 仅复习模式需要先浏览；学习第二遍直接进入自测
    if (widget.reviewType == ReviewType.review) {
      _isBrowsePhase = true;
    }

    _loadCurrentEntry();
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  Future<void> _loadCurrentEntry() async {
    if (_currentIndex >= widget.words.length) return;
    final word = widget.words[_currentIndex];
    if (!_entryCache.containsKey(_currentIndex)) {
      final entry = await DictionaryService.searchEnExact(word);
      _entryCache[_currentIndex] = entry;
      if (mounted) {
        setState(() {}); // 触发 UI 重建以显示释义
      }
    }
  }

  String get _currentWord => widget.words[_currentIndex];
  bool get _isLastWord => _currentIndex >= widget.words.length - 1;

  /// 进入自测阶段（浏览完成后或学习第二遍开始）
  void _enterTestPhase() {
    setState(() {
      _isBrowsePhase = false;
      _currentIndex = 0;
      _showingAnswer = false;
      _firstChoice = null;
      _secondChoice = null;
    });
    _animController.forward(from: 0);
    _loadCurrentEntry();
  }

  /// 浏览阶段：下一步
  Future<void> _onBrowseNext() async {
    if (_isLastWord) {
      // 浏览完毕，进入自测阶段
      _enterTestPhase();
    } else {
      setState(() {
        _currentIndex++;
      });
      _animController.forward(from: 0);
      await _loadCurrentEntry();
    }
  }

  Future<void> _onFirstChoice(bool remembered) async {
    setState(() {
      _firstChoice = remembered;
      _showingAnswer = true;
    });
    _animController.forward(from: 0);
  }

  Future<void> _onSecondChoice(bool correct) async {
    if (_isProcessing) return;
    setState(() => _isProcessing = true);

    _secondChoice = correct;
    final word = _currentWord;

    if (widget.reviewType == ReviewType.learning) {
      // 第二遍学习流程
      if (_firstChoice == false) {
        // 忘记了 → 退回第一遍
        await LearningService.processSecondPassForgot(word);
      } else if (_firstChoice == true && _secondChoice == false) {
        // 我记得 + 记错了 → stage=0, weak=1
        await LearningService.processSecondPassHard(word);
      } else {
        // 我记得 + 继续 → stage=0, weak=0
        await LearningService.processSecondPassEasy(word);
      }
    } else {
      // 复习流程
      if (_secondChoice == true) {
        // 轻松记住
        await LearningService.processReviewEasy(word);
      } else if (_firstChoice == true && _secondChoice == false) {
        // 我记得 + 记错了 → 回忆吃力
        await LearningService.processReviewHard(word);
      } else {
        // 忘记了
        await LearningService.processReviewForgot(word);
      }
    }

    if (!mounted) return;

    // 进入下一个词或结束
    await _nextWord();
  }

  /// 标记当前单词为已掌握
  Future<void> _markAsMastered() async {
    if (_isProcessing) return;
    setState(() => _isProcessing = true);

    await LearningService.markAsMastered(_currentWord);

    if (!mounted) return;

    if (_isLastWord) {
      // 全部完成
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.reviewType == ReviewType.learning ? '学习完成！' : '复习完成！',
            ),
          ),
        );
        Navigator.of(context).pop(true);
      }
      return;
    }

    setState(() {
      _currentIndex++;
      _showingAnswer = false;
      _firstChoice = null;
      _secondChoice = null;
      _isProcessing = false;
    });
    _animController.forward(from: 0);
    await _loadCurrentEntry();
  }

  Future<void> _nextWord() async {
    if (_isLastWord) {
      // 全部完成
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.reviewType == ReviewType.learning ? '学习完成！' : '复习完成！',
            ),
          ),
        );
        Navigator.of(context).pop(true);
      }
      return;
    }

    setState(() {
      _currentIndex++;
      _showingAnswer = false;
      _firstChoice = null;
      _secondChoice = null;
      _isProcessing = false;
    });
    _animController.forward(from: 0);
    await _loadCurrentEntry();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    String title;
    if (_isBrowsePhase) {
      title = '浏览复习 ${_currentIndex + 1}/${widget.words.length}';
    } else {
      title =
          '${widget.reviewType == ReviewType.learning ? '回忆阶段' : '复习'} ${_currentIndex + 1}/${widget.words.length}';
    }

    return PopScope(
      canPop: true,
      child: Scaffold(
        appBar: AppBar(
          title: Text(title),
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
          actions: [
            if (!_isBrowsePhase)
              IconButton(
                icon: const Icon(Icons.check_circle_outline),
                tooltip: '标记为已掌握',
                onPressed: _isProcessing ? null : _markAsMastered,
              ),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: FadeTransition(
              opacity: _fadeAnimation,
              child: _buildContent(theme, colorScheme),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(ThemeData theme, ColorScheme colorScheme) {
    final word = _currentWord;
    final entry = _entryCache[_currentIndex];
    final hasDefinition =
        entry?.translation != null && entry!.translation!.isNotEmpty;

    if (_isBrowsePhase) {
      // 浏览阶段：显示单词+释义，可逐词浏览
      return _buildBrowsePhase(word, entry, hasDefinition, theme, colorScheme);
    }

    if (!_showingAnswer) {
      // 自测第一阶段：仅显示单词
      return _buildPhase1(word, theme, colorScheme);
    } else {
      // 自测第二阶段：展开完整卡片 + 二次确认
      return _buildPhase2(word, entry, hasDefinition, theme, colorScheme);
    }
  }

  /// 单词信息展示组件（与学习页面一致）
  Widget _buildWordInfo(
    String word,
    WordEntry? entry,
    bool hasDefinition,
    ThemeData theme,
    ColorScheme colorScheme,
  ) {
    return Column(
      children: [
        // 单词
        Text(
          word,
          style: theme.textTheme.displayMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: colorScheme.primary,
          ),
          textAlign: TextAlign.center,
        ),

        const SizedBox(height: 12),

        // 音标
        if (entry?.phonetic != null && entry!.phonetic!.isNotEmpty)
          Text(
            '/${entry.phonetic}/',
            style: theme.textTheme.titleLarge?.copyWith(
              color: colorScheme.onSurfaceVariant,
              fontStyle: FontStyle.italic,
            ),
          ),

        const SizedBox(height: 20),

        // 中文释义
        if (hasDefinition)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              _normalizeNewlines(entry!.translation),
              style: theme.textTheme.bodyLarge,
              textAlign: TextAlign.center,
            ),
          ),

        const SizedBox(height: 16),

        // 英文释义
        if (entry?.definition != null && entry!.definition!.isNotEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(color: colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              _normalizeNewlines(entry.definition),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ),
      ],
    );
  }

  Widget _buildBrowsePhase(
    String word,
    WordEntry? entry,
    bool hasDefinition,
    ThemeData theme,
    ColorScheme colorScheme,
  ) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 16),

          // 提示文字
          Text(
            '请浏览单词的释义：',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),

          // 复用单词信息展示
          _buildWordInfo(word, entry, hasDefinition, theme, colorScheme),

          const SizedBox(height: 32),

          // 下一步按钮
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _onBrowseNext,
              icon: Icon(_isLastWord ? Icons.check : Icons.arrow_forward),
              label: Text(_isLastWord ? '进入自测' : '下一个'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ),

          const SizedBox(height: 16),

          // 进度条
          LinearProgressIndicator(
            value: (_currentIndex + 1) / widget.words.length,
          ),
          const SizedBox(height: 4),
          Text(
            '已浏览 ${_currentIndex + 1}/${widget.words.length}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPhase1(String word, ThemeData theme, ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Spacer(flex: 2),

        // 提示文字
        Text(
          '请回忆这个词的含义：',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 32),

        // 单词（大号显示）
        Text(
          word,
          style: theme.textTheme.displayLarge?.copyWith(
            fontWeight: FontWeight.bold,
            color: colorScheme.primary,
          ),
          textAlign: TextAlign.center,
        ),

        const Spacer(flex: 3),

        // 两个按钮
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _onFirstChoice(false),
                icon: const Icon(Icons.sentiment_dissatisfied, size: 28),
                label: const Text('忘记了', style: TextStyle(fontSize: 16)),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  foregroundColor: colorScheme.error,
                  side: BorderSide(color: colorScheme.error),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: FilledButton.icon(
                onPressed: () => _onFirstChoice(true),
                icon: const Icon(Icons.sentiment_satisfied, size: 28),
                label: const Text('我记得', style: TextStyle(fontSize: 16)),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                ),
              ),
            ),
          ],
        ),

        const SizedBox(height: 16),

        // 进度
        LinearProgressIndicator(
          value: (_currentIndex + 1) / widget.words.length,
        ),

        const Spacer(flex: 1),
      ],
    );
  }

  Widget _buildPhase2(
    String word,
    WordEntry? entry,
    bool hasDefinition,
    ThemeData theme,
    ColorScheme colorScheme,
  ) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 16),

          // 复用单词信息展示
          _buildWordInfo(word, entry, hasDefinition, theme, colorScheme),

          const SizedBox(height: 24),

          // 二次确认按钮
          Text(
            '确认你的记忆：',
            style: theme.textTheme.titleSmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),

          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _isProcessing ? null : () => _onSecondChoice(false),
              icon: const Icon(Icons.error_outline, size: 24),
              label: const Text('记错了', style: TextStyle(fontSize: 16)),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                foregroundColor: Colors.orange,
                side: const BorderSide(color: Colors.orange),
              ),
            ),
          ),
          const SizedBox(height: 12),

          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _isProcessing ? null : () => _onSecondChoice(true),
              icon: const Icon(Icons.check_circle_outline, size: 24),
              label: const Text('继续', style: TextStyle(fontSize: 16)),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                backgroundColor: colorScheme.primary,
              ),
            ),
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }
}
