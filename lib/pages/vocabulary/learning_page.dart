import 'dart:math';
import 'package:flutter/material.dart';
import '../../models/word_entry.dart';
import '../../services/dictionary_service.dart';
import '../../services/learning_service.dart';

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
  static const int _batchSize = 3;

  // Phase: 0=学习, 1=选择题, 2=回忆
  int _currentPhase = 0;
  int _currentBatchStart = 0;
  int _currentIndexInBatch = 0;
  bool _isLoading = true;

  // 所有词的释义缓存
  final Map<int, WordEntry?> _entryCache = {};

  // 回忆阶段状态
  bool _showingAnswer = false;
  bool? _firstChoice;

  // 选择题状态
  List<String> _quizOptions = [];
  int _correctOptionIndex = -1;
  int? _selectedQuizOption;
  bool _quizAnswered = false;

  // 学习结果收集（word → easy/hard/forgot/mastered）
  final Map<String, String> _results = {};

  List<String> get _words => widget.words;

  int get _globalIndex => _currentBatchStart + _currentIndexInBatch;

  String get _currentWord {
    if (_globalIndex >= _words.length) return '';
    return _words[_globalIndex];
  }

  bool get _isLastWordInBatch =>
      _currentIndexInBatch >= _batchSize - 1 ||
      _globalIndex >= _words.length - 1;

  @override
  void initState() {
    super.initState();
    _loadAllEntries();
  }

  Future<void> _loadAllEntries() async {
    setState(() => _isLoading = true);

    // 并行加载所有词的释义
    final futures = _words.asMap().entries.map((e) async {
      final entry = await DictionaryService.searchEnExact(e.value);
      return MapEntry(e.key, entry);
    });

    final results = await Future.wait(futures);
    for (final r in results) {
      _entryCache[r.key] = r.value;
    }

    if (mounted) {
      setState(() => _isLoading = false);
      // 如果不是第一批的第0个词，可能不需要重新生成选择题
      if (_currentPhase == 1) {
        _generateQuizOptions();
      }
    }
  }

  // ─── 学习阶段 ────────────────────────────────

  void _onLearnNext() {
    if (_isLastWordInBatch) {
      // 本批学习完成，进入选择题阶段
      setState(() {
        _currentPhase = 1;
        _currentIndexInBatch = 0;
      });
      _generateQuizOptions();
    } else {
      setState(() {
        _currentIndexInBatch++;
      });
    }
  }

  // ─── 选择题阶段 ──────────────────────────────

  void _generateQuizOptions() {
    final entry = _entryCache[_globalIndex];
    final correctMeaning = _extractFirstMeaning(entry?.translation);

    // 收集所有其他词的第一条释义作为干扰项池
    final allOtherMeanings = <String>[];
    for (int i = 0; i < _words.length; i++) {
      if (i == _globalIndex) continue;
      final e = _entryCache[i];
      final m = _extractFirstMeaning(e?.translation);
      if (m.isNotEmpty && m != correctMeaning) {
        allOtherMeanings.add(m);
      }
    }

    // 洗牌后取3个干扰项
    allOtherMeanings.shuffle(Random());
    final distractors = allOtherMeanings.take(3).toList();

    // 如果干扰项不足3个，用占位填充
    while (distractors.length < 3) {
      distractors.add('（无干扰项）');
    }

    // 构建4个选项 + 标记正确项
    final options = [correctMeaning, ...distractors];
    options.shuffle(Random());

    setState(() {
      _quizOptions = options;
      _correctOptionIndex = options.indexOf(correctMeaning);
      _selectedQuizOption = null;
      _quizAnswered = false;
    });
  }

  String _extractFirstMeaning(String? translation) {
    if (translation == null || translation.isEmpty) return '（无释义）';
    // 取第一条释义：按换行、中文分号/逗号/句号分割取第一段
    // 注意：不按英文句点分割，避免把 "a. 一个" 切出孤立的 "a"
    final parts = translation
        .replaceAll('\\n', '\n')
        .split(RegExp(r'[\n；;，,]'));
    for (final p in parts) {
      final trimmed = p.trim();
      if (trimmed.isEmpty) continue;
      // 去掉开头的词性标记，如 "a." "n." "v." "adj." "adv." "pron." "prep." 等
      final cleaned = trimmed
          .replaceFirst(RegExp(r'^[a-z]+\.\s*', caseSensitive: false), '')
          .trim();
      if (cleaned.isNotEmpty) return cleaned;
    }
    return translation;
  }

  void _onQuizSelect(int optionIndex) {
    if (_quizAnswered) return;
    setState(() {
      _selectedQuizOption = optionIndex;
      _quizAnswered = true;
    });
  }

  void _onQuizConfirm() {
    // 进入下一个词的选择题，或进入回忆阶段
    if (_isLastWordInBatch) {
      setState(() {
        _currentPhase = 2;
        _currentIndexInBatch = 0;
        _showingAnswer = false;
        _firstChoice = null;
      });
    } else {
      setState(() {
        _currentIndexInBatch++;
        _showingAnswer = false;
        _firstChoice = null;
      });
      _generateQuizOptions();
    }
  }

  // ─── 回忆阶段 ────────────────────────────────

  void _onRecallFirstChoice(bool remembered) {
    setState(() {
      _firstChoice = remembered;
      _showingAnswer = true;
    });
  }

  void _onRecallSecondChoice(bool correct) {
    final word = _currentWord.trim().toLowerCase();

    String result;
    if (_firstChoice == false) {
      // 忘记了
      result = 'forgot';
    } else if (_firstChoice == true && correct == false) {
      // 我记得 + 记错了
      result = 'hard';
    } else {
      // 我记得 + 继续
      result = 'easy';
    }
    _results[word] = result;

    if (_isLastWordInBatch) {
      // 检查是否还有下一批
      if (_currentBatchStart + _batchSize >= _words.length) {
        // 全部完成，保存结果
        _finishAndSave();
      } else {
        setState(() {
          _currentBatchStart += _batchSize;
          _currentPhase = 0;
          _currentIndexInBatch = 0;
          _showingAnswer = false;
          _firstChoice = null;
        });
      }
    } else {
      setState(() {
        _currentIndexInBatch++;
        _showingAnswer = false;
        _firstChoice = null;
      });
    }
  }

  /// 标记当前词为已掌握
  void _markAsMastered() {
    final word = _currentWord.trim().toLowerCase();
    _results[word] = 'mastered';
    _advanceAfterResult();
  }

  void _advanceAfterResult() {
    if (_isLastWordInBatch) {
      if (_currentBatchStart + _batchSize >= _words.length) {
        _finishAndSave();
      } else {
        setState(() {
          _currentBatchStart += _batchSize;
          _currentPhase = 0;
          _currentIndexInBatch = 0;
          _showingAnswer = false;
          _firstChoice = null;
        });
      }
    } else {
      setState(() {
        _currentIndexInBatch++;
        _showingAnswer = false;
        _firstChoice = null;
      });
    }
  }

  Future<void> _finishAndSave() async {
    if (_results.isEmpty) {
      if (mounted) Navigator.of(context).pop(false);
      return;
    }

    // 显示保存中
    setState(() => _isLoading = true);

    try {
      await LearningService.saveLearningBatchResults(_results);
    } catch (e) {
      // 保存失败也继续
    }

    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('学习完成！')));
      Navigator.of(context).pop(true);
    }
  }

  // ─── UI ──────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return PopScope(
      canPop: true,
      child: Scaffold(
        appBar: AppBar(
          title: Text('学习 ${_globalIndex + 1}/${_words.length}'),
          // 不显示阶段标题
          actions: [
            if (_currentPhase == 2)
              IconButton(
                icon: const Icon(Icons.check_circle_outline),
                tooltip: '标记为已掌握',
                onPressed: _showingAnswer ? null : _markAsMastered,
              ),
          ],
        ),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: _buildCurrentPhase(theme, colorScheme),
                ),
              ),
      ),
    );
  }

  Widget _buildCurrentPhase(ThemeData theme, ColorScheme colorScheme) {
    switch (_currentPhase) {
      case 0:
        return _buildLearnPhase(theme, colorScheme);
      case 1:
        return _buildQuizPhase(theme, colorScheme);
      case 2:
        return _buildRecallPhase(theme, colorScheme);
      default:
        return const SizedBox.shrink();
    }
  }

  // ─── 学习阶段 UI ─────────────────────────────

  Widget _buildLearnPhase(ThemeData theme, ColorScheme colorScheme) {
    final word = _currentWord;
    final entry = _entryCache[_globalIndex];

    return Column(
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

        // 释义
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

        const Spacer(flex: 3),

        // 下一步按钮
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _onLearnNext,
            icon: const Icon(Icons.arrow_forward),
            label: const Text('下一步'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
        ),

        const SizedBox(height: 16),

        // 进度条
        LinearProgressIndicator(value: (_globalIndex + 1) / _words.length),
        const SizedBox(height: 4),
        Text(
          '已完成 ${_globalIndex + 1}/${_words.length}',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),

        const Spacer(flex: 1),
      ],
    );
  }

  // ─── 选择题阶段 UI ───────────────────────────

  Widget _buildQuizPhase(ThemeData theme, ColorScheme colorScheme) {
    final word = _currentWord;
    final colors = [
      colorScheme.primary,
      Colors.orange,
      Colors.teal,
      Colors.deepPurple,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Spacer(flex: 1),

        // 单词
        Text(
          word,
          style: theme.textTheme.displayMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: colorScheme.primary,
          ),
          textAlign: TextAlign.center,
        ),

        const SizedBox(height: 16),

        Text(
          '选择正确的中文意思：',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),

        const SizedBox(height: 24),

        // 4个选项
        ...List.generate(_quizOptions.length, (i) {
          final isSelected = _selectedQuizOption == i;
          final isCorrectOption = i == _correctOptionIndex;
          Color? bgColor;
          Color? borderColor;
          Color textColor = colorScheme.onSurface;

          if (_quizAnswered) {
            if (isCorrectOption) {
              bgColor = Colors.green.withValues(alpha: 0.15);
              borderColor = Colors.green;
              textColor = Colors.green.shade700;
            } else if (isSelected && !isCorrectOption) {
              bgColor = Colors.red.withValues(alpha: 0.1);
              borderColor = Colors.red;
              textColor = Colors.red.shade700;
            }
          } else if (isSelected) {
            bgColor = colorScheme.primaryContainer;
            borderColor = colorScheme.primary;
          }

          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: _quizAnswered ? null : () => _onQuizSelect(i),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: bgColor,
                  side: BorderSide(
                    color: borderColor ?? colorScheme.outline,
                    width: isSelected ? 2 : 1,
                  ),
                  foregroundColor: textColor,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: colors[i % colors.length].withValues(
                          alpha: _quizAnswered ? 0.15 : 0.2,
                        ),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        ['A', 'B', 'C', 'D'][i],
                        style: TextStyle(
                          color: colors[i % colors.length],
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _quizOptions[i],
                        style: const TextStyle(fontSize: 16),
                      ),
                    ),
                    if (_quizAnswered && isCorrectOption)
                      const Icon(Icons.check_circle, color: Colors.green),
                    if (_quizAnswered && isSelected && !isCorrectOption)
                      const Icon(Icons.cancel, color: Colors.red),
                  ],
                ),
              ),
            ),
          );
        }),

        const Spacer(flex: 2),

        // 确认按钮（仅在选择后显示）
        if (_quizAnswered)
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _onQuizConfirm,
              icon: const Icon(Icons.arrow_forward),
              label: const Text('继续'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ),

        const SizedBox(height: 16),

        // 进度条
        LinearProgressIndicator(value: (_globalIndex + 1) / _words.length),

        const Spacer(flex: 1),
      ],
    );
  }

  // ─── 回忆阶段 UI ─────────────────────────────

  Widget _buildRecallPhase(ThemeData theme, ColorScheme colorScheme) {
    final word = _currentWord;
    final entry = _entryCache[_globalIndex];

    if (!_showingAnswer) {
      return _buildRecallPhase1(word, theme, colorScheme);
    } else {
      return _buildRecallPhase2(word, entry, theme, colorScheme);
    }
  }

  Widget _buildRecallPhase1(
    String word,
    ThemeData theme,
    ColorScheme colorScheme,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Spacer(flex: 2),

        Text(
          '请回忆这个词的含义：',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 32),

        Text(
          word,
          style: theme.textTheme.displayLarge?.copyWith(
            fontWeight: FontWeight.bold,
            color: colorScheme.primary,
          ),
          textAlign: TextAlign.center,
        ),

        const Spacer(flex: 3),

        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _onRecallFirstChoice(false),
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
                onPressed: () => _onRecallFirstChoice(true),
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

        LinearProgressIndicator(value: (_globalIndex + 1) / _words.length),

        const Spacer(flex: 1),
      ],
    );
  }

  Widget _buildRecallPhase2(
    String word,
    WordEntry? entry,
    ThemeData theme,
    ColorScheme colorScheme,
  ) {
    final hasDefinition =
        entry?.translation != null && entry!.translation!.isNotEmpty;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 16),

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
                _normalizeNewlines(entry.translation),
                style: theme.textTheme.bodyLarge,
                textAlign: TextAlign.center,
              ),
            ),

          const SizedBox(height: 24),

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
              onPressed: () => _onRecallSecondChoice(false),
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
              onPressed: () => _onRecallSecondChoice(true),
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
