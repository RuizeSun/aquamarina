import 'package:flutter/material.dart';
import '../../models/word_entry.dart';
import '../../services/dictionary_service.dart';
import '../../services/learning_service.dart';
import 'review_page.dart';

/// 将数据库中的字面 \n 替换为真正的换行符
String _normalizeNewlines(String? text) {
  if (text == null) return '';
  return text.replaceAll('\\n', '\n');
}

class LearningPage extends StatefulWidget {
  final List<String> words;
  final int bookId;

  const LearningPage({super.key, required this.words, required this.bookId});

  @override
  State<LearningPage> createState() => _LearningPageState();
}

class _LearningPageState extends State<LearningPage> {
  int _currentIndex = 0;
  final List<WordEntry?> _entryCache = [];
  bool _isLoading = true;
  bool _isProcessing = false;

  List<String> get _words => widget.words;

  @override
  void initState() {
    super.initState();
    _entryCache.length = _words.length;
    _loadCurrentEntry();
  }

  Future<void> _loadCurrentEntry() async {
    if (_currentIndex >= _words.length) return;

    setState(() => _isLoading = true);

    final word = _words[_currentIndex];
    final entry = await DictionaryService.searchEnExact(word);

    if (mounted) {
      setState(() {
        _entryCache[_currentIndex] = entry;
        _isLoading = false;
      });
    }
  }

  Future<void> _onNext() async {
    // 第一遍完成：记录学习
    await LearningService.processFirstPass(_words[_currentIndex]);

    if (_currentIndex < _words.length - 1) {
      setState(() {
        _currentIndex++;
      });
      await _loadCurrentEntry();
    } else {
      // 所有词学完，进入第二遍（回忆阶段）
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => ReviewPage(words: _words, bookId: widget.bookId),
          ),
        );
      }
    }
  }

  /// 用户提前结束第一遍，直接进入第二遍
  Future<void> _skipToReview() async {
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ReviewPage(words: _words, bookId: widget.bookId),
        ),
      );
    }
  }

  /// 标记当前单词为已掌握
  Future<void> _markAsMastered() async {
    if (_isProcessing) return;
    setState(() => _isProcessing = true);

    await LearningService.markAsMastered(_words[_currentIndex]);

    if (!mounted) return;

    // 跳到下一个词，或结束
    if (_currentIndex < _words.length - 1) {
      setState(() {
        _currentIndex++;
        _isProcessing = false;
      });
      await _loadCurrentEntry();
    } else {
      // 全部已掌握，返回
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('所有单词已标记为已掌握！')));
        Navigator.of(context).pop(true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return PopScope(
      canPop: true,
      child: Scaffold(
        appBar: AppBar(
          title: Text('学习新词 ${_currentIndex + 1}/${_words.length}'),
          actions: [
            IconButton(
              icon: const Icon(Icons.check_circle_outline),
              tooltip: '标记为已掌握',
              onPressed: _isProcessing ? null : _markAsMastered,
            ),
            TextButton(onPressed: _skipToReview, child: const Text('进入回忆')),
          ],
        ),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _buildContent(theme, colorScheme),
      ),
    );
  }

  Widget _buildContent(ThemeData theme, ColorScheme colorScheme) {
    final word = _words[_currentIndex];
    final entry = _entryCache[_currentIndex];

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Spacer(flex: 2),

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

          const SizedBox(height: 24),

          // 词性/释义
          if (entry?.translation != null && entry!.translation!.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _normalizeNewlines(entry.translation),
                style: theme.textTheme.bodyLarge,
                textAlign: TextAlign.center,
              ),
            ),

          const SizedBox(height: 24),

          // 例句（预留）
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border.all(
                color: colorScheme.outlineVariant,
                style: BorderStyle.solid,
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.construction_rounded,
                  size: 18,
                  color: colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Text(
                  '例句开发中',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ),
          ),

          const Spacer(flex: 3),

          // 下一步按钮
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _onNext,
              icon: const Icon(Icons.arrow_forward),
              label: Text(_currentIndex < _words.length - 1 ? '下一步' : '进入回忆阶段'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ),

          const SizedBox(height: 16),

          // 进度条
          LinearProgressIndicator(value: (_currentIndex + 1) / _words.length),
          const SizedBox(height: 4),
          Text(
            '已完成 ${_currentIndex + 1}/${_words.length}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),

          const Spacer(flex: 1),
        ],
      ),
    );
  }
}
