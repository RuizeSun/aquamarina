import 'dart:math';
import 'package:flutter/material.dart';
import '../../models/word_entry.dart';
import '../../services/learning_service.dart';
import 'shared/bottom_bar_widget.dart';
import 'shared/data_loader.dart';
import 'shared/quiz_widget.dart';
import 'shared/recall_widgets.dart';
import 'shared/word_utils.dart';

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

  // 全局干扰项池（词→释义）
  final Map<String, String> _distractorPool = {};

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
    _entryCache.addAll(await loadEntries(words: _words));

    // 加载全局干扰项池
    _distractorPool.addAll(await loadDistractorPool(excludeWords: _words));

    if (mounted) {
      setState(() => _isLoading = false);
      if (_currentPhase == 1) {
        _generateQuizOptions();
      }
    }
  }

  // ─── 学习阶段 ────────────────────────────────

  void _onLearnNext() {
    if (_isLastWordInBatch) {
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
      result = 'forgot';
    } else if (_firstChoice == true && correct == false) {
      result = 'hard';
    } else {
      result = 'easy';
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
      }
    } else {
      setState(() {
        _currentIndexInBatch++;
        _showingAnswer = false;
        _firstChoice = null;
      });
    }
  }

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
                  child: Column(
                    children: [
                      Expanded(child: _buildCurrentPhase(theme, colorScheme)),
                      WordLearningBottomBar(
                        currentPhase: _currentPhase,
                        globalIndex: _globalIndex,
                        totalWords: _words.length,
                        quizAnswered: _quizAnswered,
                        showingAnswer: _showingAnswer,
                        onLearnNext: _onLearnNext,
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
        return _buildLearnPhase(theme, colorScheme);
      case 1:
        return QuizPhaseView(
          word: _currentWord,
          options: _quizOptions,
          correctOptionIndex: _correctOptionIndex,
          selectedOption: _selectedQuizOption,
          isAnswered: _quizAnswered,
          hintText: '选择正确的中文意思：',
          onSelect: _onQuizSelect,
        );
      case 2:
        return _buildRecallPhase(theme, colorScheme);
      default:
        return const SizedBox.shrink();
    }
  }

  // ─── 学习阶段 UI（仅内容区域）────────────────

  Widget _buildLearnPhase(ThemeData theme, ColorScheme colorScheme) {
    final word = _currentWord;
    final entry = _entryCache[_globalIndex];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Spacer(flex: 2),

        Text(
          word,
          style: theme.textTheme.displayMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: colorScheme.primary,
          ),
          textAlign: TextAlign.center,
        ),

        const SizedBox(height: 12),

        if (entry?.phonetic != null && entry!.phonetic!.isNotEmpty)
          Text(
            '/${entry.phonetic}/',
            style: theme.textTheme.titleLarge?.copyWith(
              color: colorScheme.onSurfaceVariant,
              fontStyle: FontStyle.italic,
            ),
          ),

        const SizedBox(height: 24),

        if (entry?.translation != null && entry!.translation!.isNotEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              normalizeNewlines(entry.translation),
              style: theme.textTheme.bodyLarge,
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
      return RecallPhase1View(word: word, hintText: '请回忆这个词的含义：');
    } else {
      final hasDefinition =
          entry?.translation != null && entry!.translation!.isNotEmpty;
      return RecallPhase2View(
        word: word,
        entry: entry,
        hasDefinition: hasDefinition,
        confirmText: '确认你的记忆：',
      );
    }
  }
}
