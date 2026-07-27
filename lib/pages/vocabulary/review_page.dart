import 'dart:math';
import 'package:flutter/material.dart';
import '../../models/word_entry.dart';
import '../../services/learning_service.dart';
import 'shared/bottom_bar_widget.dart';
import 'shared/data_loader.dart';
import 'shared/quiz_widget.dart';
import 'shared/recall_widgets.dart';
import 'shared/word_utils.dart';

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
  static const int _batchSize = 3;

  // Phase: 0=浏览, 1=选择题, 2=回忆
  int _currentPhase = 0;
  int _currentBatchStart = 0;
  int _currentIndexInBatch = 0;
  bool _showingAnswer = false;

  // 回忆阶段状态
  bool? _firstChoice;

  // 选择题状态
  List<String> _quizOptions = [];
  int _correctOptionIndex = -1;
  int? _selectedQuizOption;
  bool _quizAnswered = false;

  // 收集结果（word → easy/hard/forgot/mastered）
  final Map<String, String> _results = {};

  late AnimationController _animController;
  late Animation<double> _fadeAnimation;

  final Map<int, WordEntry?> _entryCache = {};

  // 全局干扰项池（词→释义）
  final Map<String, String> _distractorPool = {};

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
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _animController,
      curve: Curves.easeInOut,
    );
    _animController.forward();

    _loadAllEntries();
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  Future<void> _loadAllEntries() async {
    // 并行加载所有词的释义
    _entryCache.addAll(await loadEntries(words: _words));

    // 加载全局干扰项池
    _distractorPool.addAll(await loadDistractorPool(excludeWords: _words));

    if (mounted) {
      setState(() {});
      if (_currentPhase == 1) {
        _generateQuizOptions();
      }
    }
  }

  // ─── 浏览阶段 ────────────────────────────────

  void _onBrowseNext() {
    if (_isLastWordInBatch) {
      setState(() {
        _currentPhase = 1;
        _currentIndexInBatch = 0;
      });
      _animController.forward(from: 0);
      _generateQuizOptions();
    } else {
      setState(() {
        _currentIndexInBatch++;
      });
      _animController.forward(from: 0);
    }
  }

  // ─── 选择题阶段 ──────────────────────────────

  void _generateQuizOptions() {
    final entry = _entryCache[_globalIndex];
    final correctMeaning = extractFirstMeaning(entry?.translation);

    final allOtherMeanings = <String>[];
    for (int i = 0; i < _words.length; i++) {
      if (i == _globalIndex) continue;
      final e = _entryCache[i];
      final m = extractFirstMeaning(e?.translation);
      if (m.isNotEmpty && m != correctMeaning) {
        allOtherMeanings.add(m);
      }
    }

    allOtherMeanings.shuffle(Random());
    final distractors = allOtherMeanings.take(3).toList();

    if (distractors.length < 3) {
      final poolEntries = _distractorPool.values.toList()..shuffle(Random());
      for (final m in poolEntries) {
        if (distractors.length >= 3) break;
        final extracted = extractFirstMeaning(m);
        if (extracted.isNotEmpty &&
            extracted != correctMeaning &&
            !distractors.contains(extracted)) {
          distractors.add(extracted);
        }
      }
    }

    while (distractors.length < 3) {
      distractors.add('（无干扰项）');
    }

    final options = [correctMeaning, ...distractors];
    options.shuffle(Random());

    setState(() {
      _quizOptions = options;
      _correctOptionIndex = options.indexOf(correctMeaning);
      _selectedQuizOption = null;
      _quizAnswered = false;
    });
    _animController.forward(from: 0);
  }

  void _onQuizSelect(int optionIndex) {
    if (_quizAnswered) return;
    setState(() {
      _selectedQuizOption = optionIndex;
      _quizAnswered = true;
    });
  }

  void _onQuizConfirm() {
    if (_isLastWordInBatch) {
      setState(() {
        _currentPhase = 2;
        _currentIndexInBatch = 0;
        _showingAnswer = false;
        _firstChoice = null;
      });
      _animController.forward(from: 0);
    } else {
      setState(() {
        _currentIndexInBatch++;
        _showingAnswer = false;
        _firstChoice = null;
      });
      _animController.forward(from: 0);
      _generateQuizOptions();
    }
  }

  // ─── 回忆阶段 ────────────────────────────────

  void _onRecallFirstChoice(bool remembered) {
    setState(() {
      _firstChoice = remembered;
      _showingAnswer = true;
    });
    _animController.forward(from: 0);
  }

  void _onRecallSecondChoice(bool correct) {
    final word = _currentWord.trim().toLowerCase();
    final quizCorrect = _selectedQuizOption == _correctOptionIndex;

    String result;
    if (_firstChoice == false) {
      // 一开始就没想起来
      // 选择题选对 → 可能是蒙对的，hard；选错 → 彻底忘记，forgot
      result = quizCorrect ? 'hard' : 'forgot';
    } else if (!correct) {
      // 自以为记得但实际错了 → 掌握不牢
      result = 'hard';
    } else {
      // 确实想对了，再参考选择题确认是否真正掌握
      result = quizCorrect ? 'easy' : 'hard';
    }
    _results[word] = result;

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
        _animController.forward(from: 0);
      }
    } else {
      setState(() {
        _currentIndexInBatch++;
        _showingAnswer = false;
        _firstChoice = null;
      });
      _animController.forward(from: 0);
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
        _animController.forward(from: 0);
      }
    } else {
      setState(() {
        _currentIndexInBatch++;
        _showingAnswer = false;
        _firstChoice = null;
      });
      _animController.forward(from: 0);
    }
  }

  Future<void> _finishAndSave() async {
    if (_results.isEmpty) {
      if (mounted) Navigator.of(context).pop(false);
      return;
    }

    try {
      await LearningService.saveLearningBatchResults(_results);
    } catch (e) {
      // 保存失败也继续
    }

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
          title: Text('${_globalIndex + 1}/${_words.length}'),
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
          actions: [
            if (_currentPhase == 2)
              IconButton(
                icon: const Icon(Icons.check_circle_outline),
                tooltip: '标记为已掌握',
                onPressed: _showingAnswer ? null : _markAsMastered,
              ),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Expanded(
                  child: FadeTransition(
                    opacity: _fadeAnimation,
                    child: _buildCurrentPhase(theme, colorScheme),
                  ),
                ),
                WordLearningBottomBar(
                  currentPhase: _currentPhase,
                  globalIndex: _globalIndex,
                  totalWords: _words.length,
                  quizAnswered: _quizAnswered,
                  showingAnswer: _showingAnswer,
                  onLearnNext: _onBrowseNext,
                  onQuizConfirm: _onQuizConfirm,
                  onRecallFirstChoice: _onRecallFirstChoice,
                  onRecallSecondChoice: _onRecallSecondChoice,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCurrentPhase(ThemeData theme, ColorScheme colorScheme) {
    switch (_currentPhase) {
      case 0:
        return _buildBrowsePhase(theme, colorScheme);
      case 1:
        return QuizPhaseView(
          word: _currentWord,
          options: _quizOptions,
          correctOptionIndex: _correctOptionIndex,
          selectedOption: _selectedQuizOption,
          isAnswered: _quizAnswered,
          hintText: '选择正确的释义：',
          onSelect: _onQuizSelect,
        );
      case 2:
        return _buildRecallPhase(theme, colorScheme);
      default:
        return const SizedBox.shrink();
    }
  }

  // ─── 浏览阶段 UI（仅内容区域）──────────────────

  Widget _buildBrowsePhase(ThemeData theme, ColorScheme colorScheme) {
    final word = _currentWord;
    final entry = _entryCache[_globalIndex];
    final phonetic = entry?.phonetic;
    final translation = entry?.translation;
    final definition = entry?.definition;
    final hasDefinition = translation != null && translation.isNotEmpty;

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
        if (phonetic != null && phonetic.isNotEmpty)
          Text(
            '/$phonetic/',
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
              normalizeNewlines(translation),
              style: theme.textTheme.bodyLarge,
              textAlign: TextAlign.center,
            ),
          ),

        const SizedBox(height: 16),

        // 英文释义
        if (definition != null && definition.isNotEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(color: colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              normalizeNewlines(definition),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ),

        const Spacer(flex: 3),
      ],
    );
  }

  // ─── 回忆阶段 UI ─────────────────────────────

  Widget _buildRecallPhase(ThemeData theme, ColorScheme colorScheme) {
    final word = _currentWord;
    final entry = _entryCache[_globalIndex];

    if (!_showingAnswer) {
      return RecallPhase1View(word: word, hintText: '回想这个词的含义：');
    } else {
      final hasDefinition =
          entry?.translation != null && entry!.translation!.isNotEmpty;
      return RecallPhase2View(
        word: word,
        entry: entry,
        hasDefinition: hasDefinition,
        confirmText: '核对你的记忆：',
      );
    }
  }
}
