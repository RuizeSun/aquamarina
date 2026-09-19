import 'package:flutter/material.dart';
import '../models/word_book.dart';
import '../services/word_book_service.dart';
import '../services/learning_service.dart';
import '../services/log_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'vocabulary/word_book_list_page.dart';
import 'vocabulary/learning_page.dart';
import 'vocabulary/review_page.dart';
import 'vocabulary/review_plan_page.dart';
import 'vocabulary/word_overview_page.dart';
import 'vocabulary/stats_page.dart';
import 'vocabulary/vocab_test_page.dart';
import 'vocabulary/spelling_page.dart';
import 'vocabulary/shared/data_loader.dart';
import 'vocabulary/shared/word_utils.dart';
import 'shared/dashboard_widgets.dart';

class VocabularyPage extends StatefulWidget {
  const VocabularyPage({super.key});

  @override
  State<VocabularyPage> createState() => VocabularyPageState();
}

class VocabularyPageState extends State<VocabularyPage>
    with WidgetsBindingObserver {
  WordBook? _currentBook;
  DailyStats? _stats;
  int _streak = 0;
  Map<String, dynamic> _goalProgress = {
    'learned': 0,
    'goal': 10,
    'completed': false,
  };
  bool _isLoading = true;
  bool _loadFailed = false;
  bool _requireReviewBeforeLearning = true;
  bool _quickSpellingReview = false;

  static const _currentBookIdKey = 'vocabulary_current_book_id';
  static const _reviewLimitKey = 'review_limit';
  static const _learningLimitKey = 'learning_limit';
  static const _reviewAskBookKey = 'review_ask_book';
  static const _requireReviewBeforeLearningKey =
      'require_review_before_learning';
  static const _quickSpellingKey = 'quick_spelling_review_enabled';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadData();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// App 生命周期回调：回到前台时立即刷新数据
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadData();
    }
  }

  /// 供外部调用的刷新方法
  Future<void> refresh() => _loadData();

  Future<void> _loadData() async {
    // 首次加载时显示 loading，后续后台刷新静默更新
    final isFirstLoad = _stats == null;
    if (isFirstLoad) {
      setState(() => _isLoading = true);
    }

    try {
      // 获取上次选中的词书
      final prefs = await SharedPreferences.getInstance();
      final savedBookId = prefs.getInt(_currentBookIdKey);

      if (savedBookId != null) {
        _currentBook = await WordBookService.getBookById(savedBookId);
      }

      // 如果保存的词书已被删除，取第一本
      if (_currentBook == null) {
        final books = await WordBookService.getAllBooks();
        if (books.isNotEmpty) {
          _currentBook = books.first;
          await prefs.setInt(_currentBookIdKey, _currentBook!.id!);
        }
      }

      // 获取今日统计
      _stats = await LearningService.getDailyStats();
      // 获取连续打卡
      _streak = await LearningService.getStreak();
      // 获取今日打卡进度
      _goalProgress = await LearningService.getTodayGoalProgress();
      // 读取是否强制要求先复习（缓存到 state，避免 build 中重复创建 Future）
      _requireReviewBeforeLearning =
          prefs.getBool(_requireReviewBeforeLearningKey) ?? true;
      // 读取是否开启快速拼写复习
      _quickSpellingReview = prefs.getBool(_quickSpellingKey) ?? false;
      _loadFailed = false;
    } catch (e) {
      // 数据加载失败：显示错误状态并提示用户重试
      logError('VocabularyPage', '数据加载失败: $e');
      _loadFailed = true;
    }

    if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _selectBook(WordBook book) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_currentBookIdKey, book.id!);
    setState(() => _currentBook = book);
    _loadData();
  }

  Future<void> _startReview() async {
    if (_currentBook == null) return;

    final prefs = await SharedPreferences.getInstance();
    final reviewLimit = prefs.getInt(_reviewLimitKey) ?? 10;
    final askBook = prefs.getBool(_reviewAskBookKey) ?? true;

    // 所有待复习单词（去重后的全局列表）
    var dueWords = await LearningService.getAllDueWords();

    if (dueWords.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('今日没有待复习的单词！')));
      }
      return;
    }

    // 需要询问词书选择时，获取分组数据
    if (askBook) {
      final groups = await LearningService.getDueWordsGroupedByBook();
      // 仅当存在多本词书有待复习时弹窗选择
      if (groups.length > 1) {
        final selected = await _showReviewBookPicker(groups);
        if (selected == null) return; // 用户取消
        dueWords = selected;
      }
    }

    // 应用复习上限
    if (dueWords.length > reviewLimit) {
      dueWords = dueWords.sublist(0, reviewLimit);
    }

    if (!mounted) return;

    // 开启「快速拼写复习」时，直接进入拼写模式
    if (_quickSpellingReview) {
      await _startQuickSpelling(dueWords);
      return;
    }

    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ReviewPage(
          words: dueWords,
          bookId: _currentBook!.id!,
          reviewType: ReviewType.review,
        ),
      ),
    );
    // 返回后总是刷新数据
    _loadData();
  }

  /// 快速拼写复习：直接对待复习单词进行拼写，并把结果写入记忆复习计划。
  Future<void> _startQuickSpelling(List<String> dueWords) async {
    // 批量加载释义并提取中文释义，跳过无释义的单词
    final entries = await loadEntries(words: dueWords);
    final spellingEntries = <String, String>{};
    for (int i = 0; i < dueWords.length; i++) {
      final meaning = extractFirstMeaning(entries[i]?.translation);
      if (meaning.isNotEmpty) {
        spellingEntries[dueWords[i]] = meaning;
      }
    }

    if (!mounted) return;

    if (spellingEntries.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前待复习单词无可用释义，无法快速拼写')),
      );
      return;
    }

    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            SpellingPage(entries: spellingEntries, recordResults: true),
      ),
    );
    // 返回后总是刷新数据（拼写结果已写入复习计划）
    _loadData();
  }

  /// 弹出词书选择对话框，返回选中的待复习单词列表；取消则返回 null。
  Future<List<String>?> _showReviewBookPicker(
    List<DueWordsGroup> groups,
  ) async {
    // 收集全部单词（去重），作为"全部词书"选项
    final allWords = <String>[];
    final seen = <String>{};
    for (final g in groups) {
      for (final w in g.words) {
        final cleaned = w.trim().toLowerCase();
        if (seen.add(cleaned)) allWords.add(w);
      }
    }

    return showDialog<List<String>>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('选择复习词书'),
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 全部词书
                ListTile(
                  leading: const Icon(Icons.collections_bookmark_outlined),
                  title: const Text('全部词书'),
                  subtitle: Text('${allWords.length} 个待复习单词'),
                  onTap: () => Navigator.of(context).pop(allWords),
                ),
                const Divider(height: 1),
                // 各词书
                ...groups.map(
                  (g) => ListTile(
                    leading: const Icon(Icons.menu_book),
                    title: Text(g.bookTitle),
                    subtitle: Text('${g.words.length} 个待复习单词'),
                    onTap: () => Navigator.of(context).pop(g.words),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _startLearning() async {
    if (_currentBook == null) return;

    // 根据设置决定是否强制要求先复习
    final prefs = await SharedPreferences.getInstance();
    final requireReviewBeforeLearning =
        prefs.getBool(_requireReviewBeforeLearningKey) ?? true;

    if (requireReviewBeforeLearning) {
      // 检查是否有待处理的复习任务
      final hasPending = await LearningService.hasPendingTasks();
      if (hasPending) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('请先完成今日复习任务！')));
        }
        return;
      }
    }

    final learningLimit = prefs.getInt(_learningLimitKey) ?? 10;

    // 获取新词
    final newWords = await LearningService.getNewWords(
      _currentBook!.id!,
      limit: learningLimit,
    );

    if (newWords.isEmpty) {
      if (!mounted) return;
      // 检查是否词书所有词已学完
      final allWords = await WordBookService.getBookWords(_currentBook!.id!);
      if (!mounted) return;
      final totalLearned = allWords.length;
      if (totalLearned >= _currentBook!.wordCount) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('词书中所有单词已学完！')));
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('今天没有新单词可学，明日再来！')));
      }
      return;
    }

    if (mounted) {
      await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) =>
              LearningPage(words: newWords, bookId: _currentBook!.id!),
        ),
      );
      // 返回后总是刷新数据
      _loadData();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('背单词'), centerTitle: false),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _loadFailed
          ? _buildErrorState()
          : _currentBook == null
          ? _buildNoBookState()
          : _buildDashboard(theme, colorScheme),
    );
  }

  /// 数据加载失败时的错误状态 UI
  Widget _buildErrorState() {
    final colorScheme = Theme.of(context).colorScheme;
    return DashboardEmptyState(
      icon: Icons.error_outline,
      iconColor: colorScheme.error.withValues(alpha: 0.6),
      title: '数据加载失败',
      message: '请检查数据库状态后重试',
      actionIcon: Icons.refresh,
      actionLabel: '重试',
      onAction: _loadData,
    );
  }

  Widget _buildNoBookState() {
    return DashboardEmptyState(
      icon: Icons.menu_book_rounded,
      title: '还没有词书',
      message: '请先创建或导入一本词书',
      actionIcon: Icons.add,
      actionLabel: '添加词书',
      onAction: _openBookList,
    );
  }

  Widget _buildDashboard(ThemeData theme, ColorScheme colorScheme) {
    final stats = _stats;
    final dueCount =
        (stats?.wrongWordCount ?? 0) + (stats?.dueReviewCount ?? 0);

    // 今日打卡进度
    final goalLearned = (_goalProgress['learned'] as int?) ?? 0;
    final goal = (_goalProgress['goal'] as int?) ?? 10;
    final goalCompleted = (_goalProgress['completed'] as bool?) ?? false;
    final goalRatio = goal <= 0 ? 0.0 : (goalLearned / goal).clamp(0.0, 1.0);

    return RefreshIndicator(
      onRefresh: _loadData,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: DashboardMetrics.pagePadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 当前词书卡片
            _buildBookCard(),
            const SizedBox(height: 16),

            // 单词总览 + 学习统计 + 词汇测试入口
            DashboardButtonRow(
              children: [
                DashboardEntryButton(
                  icon: Icons.insights,
                  label: '单词总览',
                  onPressed: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const WordOverviewPage(),
                      ),
                    );
                    _loadData();
                  },
                ),
                DashboardEntryButton(
                  icon: Icons.bar_chart,
                  label: '学习统计',
                  onPressed: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const StatsPage()),
                    );
                    _loadData();
                  },
                ),
              ],
            ),
            DashboardMetrics.itemSpacer,
            DashboardButtonRow(
              children: [
                DashboardEntryButton(
                  icon: Icons.quiz,
                  label: '词汇测试',
                  onPressed: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const VocabTestPage()),
                    );
                    _loadData();
                  },
                ),
              ],
            ),
            DashboardMetrics.sectionSpacer,

            // 今日打卡进度卡片
            DashboardProgressCard(
              icon: Icons.event_available,
              title: '今日打卡进度',
              completedTitle: '今日已打卡',
              valueText: '$goalLearned / $goal',
              progress: goalRatio,
              completed: goalCompleted,
            ),
            DashboardMetrics.sectionSpacer,

            // 🔥 连续打卡
            if (_streak > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    const Icon(
                      Icons.local_fire_department,
                      color: Colors.orange,
                      size: 28,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '连续打卡 $_streak 天',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: Colors.orange,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),

            // 今日统计
            const DashboardSectionTitle('今日概览'),
            DashboardMetrics.itemSpacer,

            // 今日概览统计：待复习 + 已学习/已复习（一行两卡片）
            Row(
              children: [
                Expanded(
                  child: DashboardStatCard(
                    icon: dueCount > 0
                        ? Icons.notifications_active
                        : Icons.check_circle,
                    label: '今日待复习',
                    valueText: '$dueCount 词',
                    tone: dueCount > 0
                        ? DashboardStatTone.alert
                        : DashboardStatTone.normal,
                  ),
                ),
                DashboardMetrics.itemGapSpacer,
                Expanded(
                  child: DashboardStatCard(
                    icon: Icons.trending_up,
                    label: '今日背词',
                    valueText:
                        '${stats?.todayLearnedCount ?? 0} 学 / ${stats?.todayReviewedCount ?? 0} 复',
                  ),
                ),
              ],
            ),
            DashboardMetrics.sectionSpacer,

            // 复习计划按钮
            DashboardButtonRow(
              children: [
                DashboardEntryButton(
                  icon: Icons.event_note,
                  label: '查看复习计划',
                  onPressed: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const ReviewPlanPage()),
                    );
                    _loadData();
                  },
                ),
              ],
            ),
            DashboardMetrics.sectionSpacer,

            // 操作按钮
            Builder(
              builder: (context) {
                final canLearn = !_requireReviewBeforeLearning || dueCount == 0;

                return Column(
                  children: [
                    DashboardButtonRow(
                      children: [
                        DashboardPrimaryButton(
                          icon: Icons.replay,
                          label: '开始复习',
                          onPressed: dueCount > 0 ? _startReview : null,
                        ),
                        DashboardPrimaryButton(
                          icon: Icons.auto_stories,
                          label: '开始学习',
                          onPressed: canLearn ? _startLearning : null,
                        ),
                      ],
                    ),
                    if (_requireReviewBeforeLearning && dueCount > 0) ...[
                      const SizedBox(height: 8),
                      Text(
                        '请先完成今日复习任务后再学习新词',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.error,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ],
                );
              },
            ),

            const SizedBox(height: 24),

            // 词书详细信息
            const DashboardSectionTitle('词书信息', small: true),
            const SizedBox(height: 8),
            DashboardPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DashboardInfoRow(
                    label: '总词数',
                    value: '${_currentBook!.wordCount}',
                  ),
                  if (_currentBook!.author != null &&
                      _currentBook!.author!.isNotEmpty)
                    DashboardInfoRow(label: '作者', value: _currentBook!.author!),
                  if (_currentBook!.description != null &&
                      _currentBook!.description!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        _currentBook!.description!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBookCard() {
    final book = _currentBook!;

    return DashboardSelectorCard(
      icon: Icons.menu_book,
      iconBackgroundColor: Color(book.coverColor ?? 0xFF00BFA5),
      iconForegroundColor: Colors.white,
      title: book.title,
      subtitle: book.description,
      switchTooltip: '切换词书',
      onTap: _openBookList,
    );
  }

  Future<void> _openBookList() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WordBookListPage(
          currentBookId: _currentBook?.id,
          onBookSelected: (book) {
            _selectBook(book);
          },
        ),
      ),
    );
    // 当从词书管理页面返回后刷新
    _loadData();
  }
}
