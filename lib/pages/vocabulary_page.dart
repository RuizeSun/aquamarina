import 'dart:async';
import 'package:flutter/material.dart';
import '../models/word_book.dart';
import '../services/word_book_service.dart';
import '../services/learning_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'vocabulary/word_book_list_page.dart';
import 'vocabulary/learning_page.dart';
import 'vocabulary/review_page.dart';

class VocabularyPage extends StatefulWidget {
  const VocabularyPage({super.key});

  @override
  State<VocabularyPage> createState() => VocabularyPageState();
}

class VocabularyPageState extends State<VocabularyPage> {
  WordBook? _currentBook;
  DailyStats? _stats;
  bool _isLoading = true;
  Timer? _refreshTimer;

  static const _currentBookIdKey = 'vocabulary_current_book_id';
  static const _reviewLimitKey = 'review_limit';
  static const _learningLimitKey = 'learning_limit';

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
    setState(() => _isLoading = true);

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
    final reviewLimit = prefs.getInt(_reviewLimitKey) ?? 20;

    var dueWords = await LearningService.getAllDueWords();

    if (dueWords.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('今日没有待复习的单词！')));
      }
      return;
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

  Future<void> _startLearning() async {
    if (_currentBook == null) return;

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

    final prefs = await SharedPreferences.getInstance();
    final learningLimit = prefs.getInt(_learningLimitKey) ?? 10;

    // 获取新词
    final newWords = await LearningService.getNewWords(
      _currentBook!.id!,
      limit: learningLimit,
    );

    if (newWords.isEmpty) {
      if (mounted) {
        // 检查是否词书所有词已学完
        final allWords = await WordBookService.getBookWords(_currentBook!.id!);
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
            const SizedBox(height: 24),

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
            const SizedBox(height: 32),

            // 操作按钮
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
                    onPressed: dueCount == 0 ? _startLearning : null,
                    icon: const Icon(Icons.auto_stories),
                    label: const Text('开始学习'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                ),
              ],
            ),

            if (dueCount > 0) ...[
              const SizedBox(height: 8),
              Text(
                '请先完成今日复习任务后再学习新词',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.error,
                ),
                textAlign: TextAlign.center,
              ),
            ],

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
