import 'dart:async';
import 'package:flutter/material.dart';
import '../models/word_book.dart';
import '../services/word_book_service.dart';
import '../services/learning_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'vocabulary/word_book_list_page.dart';
import 'vocabulary/learning_page.dart';
import 'vocabulary/review_page.dart';
import 'vocabulary/review_plan_page.dart';
import 'vocabulary/word_overview_page.dart';
import 'vocabulary/stats_page.dart';
import 'vocabulary/vocab_test_page.dart';

class VocabularyPage extends StatefulWidget {
  const VocabularyPage({super.key});

  @override
  State<VocabularyPage> createState() => VocabularyPageState();
}

class VocabularyPageState extends State<VocabularyPage> {
  WordBook? _currentBook;
  DailyStats? _stats;
  int _streak = 0;
  Map<String, dynamic> _goalProgress = {
    'learned': 0,
    'goal': 10,
    'completed': false,
  };
  bool _isLoading = true;
  Timer? _refreshTimer;

  static const _currentBookIdKey = 'vocabulary_current_book_id';
  static const _reviewLimitKey = 'review_limit';
  static const _learningLimitKey = 'learning_limit';
  static const _reviewAskBookKey = 'review_ask_book';
  static const _requireReviewBeforeLearningKey =
      'require_review_before_learning';

  @override
  void initState() {
    super.initState();
    _loadData();
    // 每15秒自动刷新
    _refreshTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      _loadData();
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
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
    } catch (e) {
      // ignore errors during loading
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

    if (mounted) {
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
          : _currentBook == null
          ? _buildNoBookState(theme, colorScheme)
          : _buildDashboard(theme, colorScheme),
    );
  }

  Widget _buildNoBookState(ThemeData theme, ColorScheme colorScheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.menu_book_rounded,
              size: 80,
              color: colorScheme.primary.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 16),
            Text(
              '还没有词书',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '请先创建或导入一本词书',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => _openBookList(),
              icon: const Icon(Icons.add),
              label: const Text('添加词书'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDashboard(ThemeData theme, ColorScheme colorScheme) {
    final stats = _stats;
    final dueCount =
        (stats?.wrongWordCount ?? 0) + (stats?.dueReviewCount ?? 0);

    // 读取是否强制要求先复习
    final requireReviewFuture = SharedPreferences.getInstance().then(
      (prefs) => prefs.getBool(_requireReviewBeforeLearningKey) ?? true,
    );

    return RefreshIndicator(
      onRefresh: _loadData,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 当前词书卡片
            _buildBookCard(theme, colorScheme),
            const SizedBox(height: 16),

            // 单词总览 + 学习统计 + 词汇测试入口
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const WordOverviewPage(),
                        ),
                      );
                      _loadData();
                    },
                    icon: const Icon(Icons.insights),
                    label: const Text('单词总览'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const StatsPage()),
                      );
                      _loadData();
                    },
                    icon: const Icon(Icons.bar_chart),
                    label: const Text('学习统计'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const VocabTestPage()),
                  );
                  _loadData();
                },
                icon: const Icon(Icons.quiz),
                label: const Text('词汇测试'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // 今日打卡进度卡片
            _buildGoalCard(theme, colorScheme),
            const SizedBox(height: 16),

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
            Text('今日概览', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),

            // 待复习数量
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: dueCount > 0
                    ? colorScheme.errorContainer
                    : colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(
                    dueCount > 0
                        ? Icons.notifications_active
                        : Icons.check_circle,
                    color: dueCount > 0
                        ? colorScheme.error
                        : colorScheme.primary,
                    size: 32,
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '今日待复习',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: dueCount > 0
                              ? colorScheme.onErrorContainer
                              : colorScheme.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        '$dueCount 词',
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: dueCount > 0
                              ? colorScheme.error
                              : colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // 已学习/复习数量
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.trending_up, color: colorScheme.primary, size: 32),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '今日已学习 / 已复习',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        '${stats?.todayLearnedCount ?? 0} 学 / ${stats?.todayReviewedCount ?? 0} 复',
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // 复习计划按钮
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ReviewPlanPage()),
                  );
                  _loadData();
                },
                icon: const Icon(Icons.event_note),
                label: const Text('查看复习计划'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // 操作按钮
            FutureBuilder<bool>(
              future: requireReviewFuture,
              builder: (context, snapshot) {
                final requireReview = snapshot.data ?? true;
                final canLearn = !requireReview || dueCount == 0;

                return Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: dueCount > 0 ? _startReview : null,
                            icon: const Icon(Icons.replay),
                            label: const Text('开始复习'),
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: canLearn ? _startLearning : null,
                            icon: const Icon(Icons.auto_stories),
                            label: const Text('开始学习'),
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (requireReview && dueCount > 0) ...[
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
            if (_currentBook != null) ...[
              Text('词书信息', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _infoRow('总词数', '${_currentBook!.wordCount}', colorScheme),
                    if (_currentBook!.author != null &&
                        _currentBook!.author!.isNotEmpty)
                      _infoRow('作者', _currentBook!.author!, colorScheme),
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
          ],
        ),
      ),
    );
  }

  /// 今日打卡进度卡片
  Widget _buildGoalCard(ThemeData theme, ColorScheme colorScheme) {
    final learned = (_goalProgress['learned'] as int?) ?? 0;
    final goal = (_goalProgress['goal'] as int?) ?? 10;
    final completed = (_goalProgress['completed'] as bool?) ?? false;
    final progress = goal <= 0 ? 0.0 : (learned / goal).clamp(0.0, 1.0);
    final remaining = goal - learned > 0 ? goal - learned : 0;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: completed
            ? Colors.green.withValues(alpha: 0.12)
            : colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: completed
            ? Border.all(color: Colors.green.withValues(alpha: 0.5))
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                completed ? Icons.check_circle : Icons.event_available,
                color: completed ? Colors.green : colorScheme.primary,
                size: 28,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  completed ? '今日已打卡' : '今日打卡进度',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: completed ? Colors.green : colorScheme.primary,
                  ),
                ),
              ),
              Text(
                '$learned / $goal',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: completed ? Colors.green : colorScheme.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 8,
              backgroundColor: colorScheme.surfaceContainerHighest,
              color: completed ? Colors.green : colorScheme.primary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            completed ? '目标达成，继续保持！' : '还差 $remaining 个新词完成今日打卡',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value, ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text(
            '$label: ',
            style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 13),
          ),
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildBookCard(ThemeData theme, ColorScheme colorScheme) {
    final book = _currentBook!;

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _openBookList,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // 封面色块
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: Color(book.coverColor ?? 0xFF00BFA5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.menu_book,
                  color: Colors.white,
                  size: 32,
                ),
              ),
              const SizedBox(width: 16),

              // 词书信息
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      book.title,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (book.description != null &&
                        book.description!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          book.description!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),

              // 切换按钮
              IconButton(
                icon: const Icon(Icons.swap_horiz),
                onPressed: _openBookList,
                tooltip: '切换词书',
              ),
            ],
          ),
        ),
      ),
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
