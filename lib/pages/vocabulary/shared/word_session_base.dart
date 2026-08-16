import 'dart:math';
import 'package:flutter/material.dart';
import '../../../models/user_word_record.dart';
import '../../../models/word_entry.dart';
import '../../../services/dictionary_service.dart';
import '../../../services/learning_service.dart';
import '../../../services/tts_service.dart';
import '../../../services/study_timer_service.dart';
import '../spelling_page.dart';
import 'bottom_bar_widget.dart';
import 'data_loader.dart';
import 'quiz_widget.dart';
import 'recall_widgets.dart';
import 'summary_widget.dart';
import 'word_utils.dart';

/// 单词学习/复习会话页面的公共 Widget 基类。
///
/// 提供 `words` 与 `bookId` 的最小接口，供状态基类直接访问。
abstract class WordSessionPage extends StatefulWidget {
  const WordSessionPage({super.key});

  /// 本次会话的单词列表
  List<String> get words;

  /// 当前词书 ID
  int get bookId;
}

/// 单词学习/复习会话的公共状态基类。
///
/// 将 [LearningPage] 与 [ReviewPage] 中几乎完全相同的
/// 批处理、释义懒加载、选择题生成、干扰项池、回忆推进、
/// 总结阶段、拼写练习提示、退出确认等逻辑统一上移，
/// 子类仅需提供差异配置与差异方法。
abstract class WordSessionBaseState<T extends WordSessionPage> extends State<T>
    with SingleTickerProviderStateMixin {
  // ─── 子类必须提供的差异配置 ──────────────────────
  /// 学习时长会话类型
  @protected
  SessionType get sessionType;

  /// 保存结果时是否计为复习
  @protected
  bool get isReview;

  /// 退出确认对话框标题
  @protected
  String get exitTitle;

  /// 退出确认对话框内容
  @protected
  String get exitMessage;

  /// 总结阶段标题（如「学习完成！」）
  @protected
  String get summaryTitle;

  /// 总结阶段图标
  @protected
  IconData get summaryIcon;

  /// 回忆阶段 1 的提示文案
  @protected
  String get recallHint;

  /// 回忆阶段 2 的确认文案
  @protected
  String get recallConfirmText;

  /// 选择题提示文案
  @protected
  String get quizHint;

  /// 是否显示加载指示器（LearningPage 为 true，ReviewPage 为 false）
  @protected
  bool get showLoadingIndicator => false;

  /// 是否在 AppBar 显示关闭按钮（ReviewPage 为 true）
  @protected
  bool get showCloseButton => false;

  // ─── 子类必须实现的差异方法 ──────────────────────
  /// 阶段 0（学习/浏览）的 UI 内容
  @protected
  Widget buildPhase0(ThemeData theme, ColorScheme colorScheme);

  /// 阶段 0 的「下一步」行为（学习下一页 / 浏览下一页）
  @protected
  void onPhase0Next();

  /// 回忆阶段 2 的判定与推进（两个页面算法不同）
  @protected
  Future<void> onRecallSecondChoice(bool correct);

  // ─── 共用状态 ─────────────────────────────────
  static const int batchSize = 3;

  /// 阶段：0=学习/浏览, 1=选择题, 2=回忆, 3=总结
  @protected
  int phase = 0;

  @protected
  int currentBatchStart = 0;

  @protected
  int currentIndexInBatch = 0;

  @protected
  bool showingAnswer = false;

  @protected
  bool? firstChoice;

  @protected
  List<String> quizOptions = [];

  @protected
  int correctOptionIndex = -1;

  @protected
  int? selectedQuizOption;

  @protected
  bool quizAnswered = false;

  /// 累计完成的「词 × 阶段」步数，用于进度条（只增不减）
  @protected
  int completedSteps = 0;

  /// 是否已确认退出（防止重复弹出确认框）
  @protected
  bool isExiting = false;

  /// 学习/复习结果收集（word → easy/hard/forgot/mastered）
  @protected
  final Map<String, String> results = {};

  /// 所有词的释义缓存（懒加载，按 batch 逐步填充）
  @protected
  final Map<int, WordEntry?> entryCache = {};

  /// 全局干扰项池（词→释义）
  @protected
  final Map<String, String> distractorPool = {};

  /// 总结阶段：每个词的复习安排信息
  @protected
  final Map<String, WordSummaryItem> summaryItems = {};

  @protected
  bool isLoading = false;

  late AnimationController animController;
  late Animation<double> fadeAnimation;

  // ─── 派生状态 ─────────────────────────────────

  List<String> get words => widget.words;

  @protected
  int get globalIndex => currentBatchStart + currentIndexInBatch;

  @protected
  String get currentWord {
    if (globalIndex >= words.length) return '';
    return words[globalIndex];
  }

  @protected
  bool get isLastWordInBatch =>
      currentIndexInBatch >= batchSize - 1 || globalIndex >= words.length - 1;

  // ─── 生命周期 ─────────────────────────────────

  @override
  void initState() {
    super.initState();
    // 启动学习时长计时
    StudyTimerService.instance.startSession(sessionType);
    animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    fadeAnimation = CurvedAnimation(
      parent: animController,
      curve: Curves.easeInOut,
    );
    animController.forward();
    loadInitialData();
  }

  @override
  void dispose() {
    // 结束学习时长计时
    StudyTimerService.instance.endSession();
    animController.dispose();
    super.dispose();
  }

  // ─── 数据加载 ─────────────────────────────────

  /// 初始只加载第一批词的释义 + 全局干扰项池
  @protected
  Future<void> loadInitialData() async {
    if (showLoadingIndicator) {
      setState(() => isLoading = true);
    }

    // 只加载当前 batch 的释义
    final batchWords = getBatchWords(0);
    entryCache.addAll(await loadEntries(words: batchWords));

    // 加载全局干扰项池（只加载一次，全量只有 10 个词）
    distractorPool.addAll(await loadDistractorPool(excludeWords: words));

    if (mounted) {
      setState(() {
        isLoading = false;
      });
      if (phase == 1) {
        generateQuizOptions();
      }
      // 首次加载后自动朗读
      autoReadCurrentWord();
    }
  }

  /// 加载后续 batch 的释义（在切换 batch 时调用）
  @protected
  Future<void> loadBatchEntries(int batchStart) async {
    final batchWords = getBatchWords(batchStart);
    final newEntries = await loadEntries(words: batchWords);
    // loadEntries 返回的 key 相对于子列表（0,1,2...），需要加上 batchStart 偏移
    final offsetEntries = newEntries.map(
      (key, value) => MapEntry(key + batchStart, value),
    );
    if (mounted) {
      setState(() {
        entryCache.addAll(offsetEntries);
      });
    }
  }

  /// 获取某个 batch 包含的单词列表
  @protected
  List<String> getBatchWords(int batchStart) {
    final end = batchStart + batchSize;
    if (end >= words.length) {
      return words.sublist(batchStart);
    }
    return words.sublist(batchStart, end);
  }

  /// 自动朗读当前单词（学习/浏览阶段）
  @protected
  void autoReadCurrentWord() {
    final settings = TtsService.instance.settings;
    if (settings.autoReadBrowse && currentWord.isNotEmpty) {
      TtsService.instance.speak(currentWord);
    }
  }

  // ─── 选择题阶段 ──────────────────────────────

  @protected
  Future<void> generateQuizOptions() async {
    final entry = entryCache[globalIndex];
    final correctMeaning = extractFirstMeaning(entry?.translation);

    // 当前词无释义时跳过选择题，直接进入下一环节
    if (correctMeaning.isEmpty) {
      onQuizConfirm();
      return;
    }

    final allOtherMeanings = <String>[];
    for (int i = 0; i < words.length; i++) {
      if (i == globalIndex) continue;
      final e = entryCache[i];
      final m = extractFirstMeaning(e?.translation);
      if (m.isNotEmpty && m != correctMeaning) {
        allOtherMeanings.add(m);
      }
    }

    allOtherMeanings.shuffle(Random());
    final distractors = allOtherMeanings.take(3).toList();

    if (distractors.length < 3) {
      final poolEntries = distractorPool.values.toList()..shuffle(Random());
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
      final randomWord = await LearningService.getRandomDistractorWord(words);
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
      quizOptions = options;
      correctOptionIndex = options.indexOf(correctMeaning);
      selectedQuizOption = null;
      quizAnswered = false;
    });
    animController.forward(from: 0);
  }

  @protected
  void onQuizSelect(int optionIndex) {
    if (quizAnswered) return;
    setState(() {
      selectedQuizOption = optionIndex;
      quizAnswered = true;
    });
  }

  @protected
  void onQuizConfirm() {
    completedSteps++;
    if (isLastWordInBatch) {
      setState(() {
        phase = 2;
        currentIndexInBatch = 0;
        showingAnswer = false;
        firstChoice = null;
      });
      animController.forward(from: 0);
    } else {
      setState(() {
        currentIndexInBatch++;
        showingAnswer = false;
        firstChoice = null;
      });
      animController.forward(from: 0);
      generateQuizOptions();
    }
  }

  // ─── 回忆阶段 ────────────────────────────────

  @protected
  void onRecallFirstChoice(bool remembered) {
    setState(() {
      firstChoice = remembered;
      showingAnswer = true;
    });
    animController.forward(from: 0);
  }

  /// 标记当前词为已掌握
  @protected
  Future<void> markAsMastered() async {
    completedSteps++;
    final word = currentWord.trim().toLowerCase();
    results[word] = 'mastered';
    await advanceAfterResult();
  }

  @protected
  Future<void> advanceAfterResult() async {
    if (isLastWordInBatch) {
      if (currentBatchStart + batchSize >= words.length) {
        finishAndSave();
      } else {
        final nextBatchStart = currentBatchStart + batchSize;
        await loadBatchEntries(nextBatchStart);
        setState(() {
          currentBatchStart = nextBatchStart;
          phase = 0;
          currentIndexInBatch = 0;
          showingAnswer = false;
          firstChoice = null;
        });
        animController.forward(from: 0);
      }
    } else {
      setState(() {
        currentIndexInBatch++;
        showingAnswer = false;
        firstChoice = null;
      });
      animController.forward(from: 0);
    }
  }

  // ─── 总结阶段 ────────────────────────────────

  @protected
  Future<void> finishAndSave() async {
    if (results.isEmpty) {
      if (mounted) Navigator.of(context).pop(false);
      return;
    }

    setState(() => isLoading = true);

    try {
      await LearningService.saveLearningBatchResults(
        results,
        isReview: isReview,
      );
    } catch (e) {
      // 保存失败也继续
    }

    // 逐个查询每个词的最新学习记录，构建总结数据
    final items = <String, WordSummaryItem>{};
    for (final word in results.keys) {
      UserWordRecord? record;
      try {
        record = await LearningService.getRecord(word);
      } catch (e) {
        record = null;
      }

      // 找一个包含该词的缓存索引用于显示释义
      final index = words.indexWhere(
        (w) => w.trim().toLowerCase() == word.toLowerCase(),
      );
      final entry = index >= 0 ? entryCache[index] : null;
      final meaning = extractFirstMeaning(entry?.translation);

      items[word] = WordSummaryItem(
        word: word,
        meaning: meaning.isEmpty ? '（无释义）' : meaning,
        statusLabel: formatNextReviewLabel(record),
      );
    }

    if (!mounted) return;
    setState(() {
      summaryItems
        ..clear()
        ..addAll(items);
      isLoading = false;
    });

    // 询问是否进入拼写练习
    final enterSpelling = await showSpellingPrompt(
      context,
      wordCount: results.length,
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
      phase = 3;
    });
    animController.forward(from: 0);
  }

  // ─── 退出确认 ─────────────────────────────────

  /// 退出确认：提示用户退出将不保存本次进度。
  @protected
  Future<bool> confirmExit() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(exitTitle),
        content: Text(exitMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('继续'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    return result == true;
  }

  /// 处理退出：先确认，确认后弹出页面。
  @protected
  Future<void> handleExit() async {
    if (isExiting) return;
    final shouldExit = await confirmExit();
    if (shouldExit && mounted) {
      isExiting = true;
      Navigator.of(context).pop();
    }
  }

  // ─── UI 构建 ─────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return PopScope(
      // 总结阶段进度已保存，允许直接退出；其他阶段退出前需确认。
      canPop: phase == 3,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop || isExiting) return;
        await handleExit();
      },
      child: Column(
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: completedSteps / (words.length * 3)),
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            builder: (context, value, _) =>
                LinearProgressIndicator(value: value),
          ),
          Expanded(
            child: Scaffold(
              appBar: AppBar(
                title: Text('${globalIndex + 1}/${words.length}'),
                leading: showCloseButton
                    ? IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.of(context).maybePop(),
                      )
                    : null,
                actions: [
                  if (phase == 2)
                    IconButton(
                      icon: const Icon(Icons.check_circle_outline),
                      tooltip: '标记为已掌握',
                      onPressed: showingAnswer ? null : markAsMastered,
                    ),
                ],
              ),
              body: isLoading && showLoadingIndicator
                  ? const Center(child: CircularProgressIndicator())
                  : SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          children: [
                            Expanded(
                              child: FadeTransition(
                                opacity: fadeAnimation,
                                child: buildCurrentPhase(theme, colorScheme),
                              ),
                            ),
                            if (phase == 3)
                              SizedBox(
                                width: double.infinity,
                                child: FilledButton.icon(
                                  onPressed: () =>
                                      Navigator.of(context).pop(true),
                                  icon: const Icon(Icons.check),
                                  label: const Text(
                                    '完成',
                                    style: TextStyle(fontSize: 16),
                                    textScaler: TextScaler.noScaling,
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
                                currentPhase: phase,
                                globalIndex: globalIndex,
                                totalWords: words.length,
                                quizAnswered: quizAnswered,
                                showingAnswer: showingAnswer,
                                onLearnNext: onPhase0Next,
                                onQuizConfirm: onQuizConfirm,
                                onRecallFirstChoice: onRecallFirstChoice,
                                onRecallSecondChoice: onRecallSecondChoice,
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

  @protected
  Widget buildCurrentPhase(ThemeData theme, ColorScheme colorScheme) {
    switch (phase) {
      case 0:
        return buildPhase0(theme, colorScheme);
      case 1:
        return QuizPhaseView(
          word: currentWord,
          options: quizOptions,
          correctOptionIndex: correctOptionIndex,
          selectedOption: selectedQuizOption,
          isAnswered: quizAnswered,
          hintText: quizHint,
          onSelect: onQuizSelect,
        );
      case 2:
        return buildRecallPhase(theme, colorScheme);
      case 3:
        return buildSummaryPhase(theme, colorScheme);
      default:
        return const SizedBox.shrink();
    }
  }

  // ─── 总结阶段 UI ────────────────────────────

  @protected
  Widget buildSummaryPhase(ThemeData theme, ColorScheme colorScheme) {
    final items = summaryItems.values.toList();

    // 统计各类结果数量
    var easyCount = 0;
    var hardCount = 0;
    var forgotCount = 0;
    var masteredCount = 0;
    for (final w in results.keys) {
      switch (results[w]) {
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
      title: summaryTitle,
      icon: summaryIcon,
      items: items,
      learnedCount: items.length,
      easyCount: easyCount,
      hardCount: hardCount,
      forgotCount: forgotCount,
      masteredCount: masteredCount,
    );
  }

  // ─── 回忆阶段 UI ─────────────────────────────

  @protected
  Widget buildRecallPhase(ThemeData theme, ColorScheme colorScheme) {
    final word = currentWord;
    final entry = entryCache[globalIndex];

    if (!showingAnswer) {
      return RecallPhase1View(
        word: word,
        hintText: recallHint,
        autoRead: TtsService.instance.settings.autoReadRecall,
      );
    } else {
      final hasDefinition =
          entry?.translation != null && entry!.translation!.isNotEmpty;
      return RecallPhase2View(
        word: word,
        entry: entry,
        hasDefinition: hasDefinition,
        confirmText: recallConfirmText,
      );
    }
  }
}
