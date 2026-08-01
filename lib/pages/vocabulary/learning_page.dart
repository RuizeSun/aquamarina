import 'dart:math';
import 'package:flutter/material.dart';
import '../../models/user_word_record.dart';
import '../../models/word_entry.dart';
import '../../services/dictionary_service.dart';
import '../../services/learning_service.dart';
import '../../services/tts_service.dart';
import 'shared/bottom_bar_widget.dart';
import 'shared/data_loader.dart';
import 'shared/quiz_widget.dart';
import 'shared/recall_widgets.dart';
import 'shared/summary_widget.dart';
import 'shared/word_utils.dart';
import 'spelling_page.dart';

class LearningPage extends StatefulWidget {
  final List<String> words;
  final int bookId;

  const LearningPage({super.key, required this.words, required this.bookId});

  @override
  State<LearningPage> createState() => _LearningPageState();
}

class _LearningPageState extends State<LearningPage>
    with SingleTickerProviderStateMixin {
  static const int _batchSize = 3;

  // Phase: 0=学习, 1=选择题, 2=回忆, 3=总结
  int _currentPhase = 0;
  int _currentBatchStart = 0;
  int _currentIndexInBatch = 0;
  bool _isLoading = true;

  // 所有词的释义缓存（懒加载，按 batch 逐步填充）
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

  // 累计完成的"词×阶段"步数，用于进度条（只增不减）
  int _completedSteps = 0;

  // 学习结果收集（word → easy/hard/forgot/mastered）
  final Map<String, String> _results = {};

  // 总结阶段：每个词的复习安排信息
  final Map<String, WordSummaryItem> _summaryItems = {};

  late AnimationController _animController;
  late Animation<double> _fadeAnimation;

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
    _loadInitialData();
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  /// 初始只加载第一批词的释义 + 全局干扰项池
  Future<void> _loadInitialData() async {
    setState(() => _isLoading = true);

    // 只加载当前 batch 的释义
    final batchWords = _getBatchWords(0);
    _entryCache.addAll(await loadEntries(words: batchWords));

    // 加载全局干扰项池（只加载一次，全量只有 10 个词）
    _distractorPool.addAll(await loadDistractorPool(excludeWords: _words));

    if (mounted) {
      setState(() => _isLoading = false);
      if (_currentPhase == 1) {
        _generateQuizOptions();
      }
      // 首次加载后自动朗读
      _autoReadCurrentWord();
    }
  }

  /// 加载后续 batch 的释义（在切换 batch 时调用）
  Future<void> _loadBatchEntries(int batchStart) async {
    final batchWords = _getBatchWords(batchStart);
    final newEntries = await loadEntries(words: batchWords);
    // loadEntries 返回的 key 相对于子列表（0,1,2...），需要加上 batchStart 偏移
    final offsetEntries = newEntries.map(
      (key, value) => MapEntry(key + batchStart, value),
    );
    if (mounted) {
      setState(() {
        _entryCache.addAll(offsetEntries);
      });
    }
  }

  /// 获取某个 batch 包含的单词列表
  List<String> _getBatchWords(int batchStart) {
    final end = batchStart + _batchSize;
    if (end >= _words.length) {
      return _words.sublist(batchStart);
    }
    return _words.sublist(batchStart, end);
  }

  /// 自动朗读当前单词（学习/浏览阶段）
  void _autoReadCurrentWord() {
    final settings = TtsService.instance.settings;
    if (settings.autoReadBrowse && _currentWord.isNotEmpty) {
      TtsService.instance.speak(_currentWord);
    }
  }

  // ─── 学习阶段 ────────────────────────────────

  void _onLearnNext() {
    _completedSteps++;
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
      _autoReadCurrentWord();
    }
  }

  // ─── 选择题阶段 ──────────────────────────────

  Future<void> _generateQuizOptions() async {
    final entry = _entryCache[_globalIndex];
    final correctMeaning = extractFirstMeaning(entry?.translation);

    // 当前词无释义时跳过选择题，直接进入下一环节
    if (correctMeaning.isEmpty) {
      _onQuizConfirm();
      return;
    }

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

    // 仍不足 3 个时，直接从数据库随机抽取真实词补充（最多尝试 5 次）
    var attempts = 0;
    while (distractors.length < 3 && attempts < 5) {
      attempts++;
      final randomWord = await LearningService.getRandomDistractorWord(_words);
      if (randomWord == null) break;
      final e = await DictionaryService.searchEnExact(randomWord);
      final m = extractFirstMeaning(e?.translation);
      if (m.isNotEmpty && m != correctMeaning && !distractors.contains(m)) {
        distractors.add(m);
      }
    }

    final options = [correctMeaning, ...distractors];
    options.shuffle(Random());

    if (!mounted) return;
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
    _completedSteps++;
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

  Future<void> _onRecallSecondChoice(bool correct) async {
    _completedSteps++;
    _animController.forward(from: 0);
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
        final nextBatchStart = _currentBatchStart + _batchSize;
        // 先加载下一批的释义再切换
        await _loadBatchEntries(nextBatchStart);
        setState(() {
          _currentBatchStart = nextBatchStart;
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

  Future<void> _markAsMastered() async {
    _completedSteps++;
    final word = _currentWord.trim().toLowerCase();
    _results[word] = 'mastered';
    await _advanceAfterResult();
  }

  Future<void> _advanceAfterResult() async {
    if (_isLastWordInBatch) {
      if (_currentBatchStart + _batchSize >= _words.length) {
        _finishAndSave();
      } else {
        final nextBatchStart = _currentBatchStart + _batchSize;
        await _loadBatchEntries(nextBatchStart);
        setState(() {
          _currentBatchStart = nextBatchStart;
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

    setState(() => _isLoading = true);

    try {
      await LearningService.saveLearningBatchResults(_results);
    } catch (e) {
      // 保存失败也继续
    }

    // 逐个查询每个词的最新学习记录，构建总结数据
    final items = <String, WordSummaryItem>{};
    for (final word in _results.keys) {
      UserWordRecord? record;
      try {
        record = await LearningService.getRecord(word);
      } catch (e) {
        record = null;
      }

      // 找一个包含该词的缓存索引用于显示释义
      final index = _words.indexWhere(
        (w) => w.trim().toLowerCase() == word.toLowerCase(),
      );
      final entry = index >= 0 ? _entryCache[index] : null;
      final meaning = extractFirstMeaning(entry?.translation);

      items[word] = WordSummaryItem(
        word: word,
        meaning: meaning.isEmpty ? '（无释义）' : meaning,
        statusLabel: formatNextReviewLabel(record),
      );
    }

    if (!mounted) return;
    setState(() {
      _summaryItems
        ..clear()
        ..addAll(items);
      _isLoading = false;
    });

    // 询问是否进入拼写练习
    final enterSpelling = await showSpellingPrompt(
      context,
      wordCount: _results.length,
    );

    if (!mounted) return;

    if (enterSpelling) {
      // 构建词 → 中文释义映射（跳过无释义的词）
      final spellingEntries = <String, String>{};
      for (final item in items.values) {
        if (item.meaning != '（无释义）') {
          spellingEntries[item.word] = item.meaning;
        }
      }
      if (spellingEntries.isNotEmpty) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => SpellingPage(entries: spellingEntries),
          ),
        );
        if (!mounted) return;
      }
    }

    setState(() {
      _currentPhase = 3;
    });
    _animController.forward(from: 0);
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
            tween: Tween(begin: 0, end: _completedSteps / (_words.length * 3)),
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            builder: (context, value, _) =>
                LinearProgressIndicator(value: value),
          ),
          Expanded(
            child: Scaffold(
              appBar: AppBar(
                title: Text('${_globalIndex + 1}/${_words.length}'),
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
                            Expanded(
                              child: FadeTransition(
                                opacity: _fadeAnimation,
                                child: _buildCurrentPhase(theme, colorScheme),
                              ),
                            ),
                            if (_currentPhase == 3)
                              SizedBox(
                                width: double.infinity,
                                child: FilledButton.icon(
                                  onPressed: () =>
                                      Navigator.of(context).pop(true),
                                  icon: const Icon(Icons.check),
                                  label: const Text(
                                    '完成',
                                    style: TextStyle(fontSize: 16),
                                  ),
                                  style: FilledButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 16,
                                    ),
                                  ),
                                ),
                              )
                            else
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
          ),
        ],
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
      case 3:
        return _buildSummaryPhase(theme, colorScheme);
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

  // ─── 总结阶段 UI ────────────────────────────

  Widget _buildSummaryPhase(ThemeData theme, ColorScheme colorScheme) {
    final items = _summaryItems.values.toList();

    // 统计各类结果数量
    var easyCount = 0;
    var hardCount = 0;
    var forgotCount = 0;
    var masteredCount = 0;
    for (final w in _results.keys) {
      switch (_results[w]) {
        case 'easy':
          easyCount++;
          break;
        case 'hard':
          hardCount++;
          break;
        case 'forgot':
          forgotCount++;
          break;
        case 'mastered':
          masteredCount++;
          break;
      }
    }

    return WordLearningSummaryView(
      title: '学习完成！',
      icon: Icons.emoji_events,
      items: items,
      learnedCount: items.length,
      easyCount: easyCount,
      hardCount: hardCount,
      forgotCount: forgotCount,
      masteredCount: masteredCount,
    );
  }

  // ─── 回忆阶段 UI ─────────────────────────────

  Widget _buildRecallPhase(ThemeData theme, ColorScheme colorScheme) {
    final word = _currentWord;
    final entry = _entryCache[_globalIndex];

    if (!_showingAnswer) {
      return RecallPhase1View(
        word: word,
        hintText: '请回忆这个词的含义：',
        autoRead: TtsService.instance.settings.autoReadRecall,
      );
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
