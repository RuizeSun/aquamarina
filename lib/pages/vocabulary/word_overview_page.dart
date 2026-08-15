import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../../services/learning_service.dart';
import '../../services/dictionary_service.dart';
import '../word_detail_page.dart';

/// 单词总览页：按状态（等待学习/已学习/已掌握）查看所有单词，
/// 支持按词书筛选、多选/全选批量标记"已掌握"或"重新学习"。
class WordOverviewPage extends StatefulWidget {
  const WordOverviewPage({super.key});

  @override
  State<WordOverviewPage> createState() => _WordOverviewPageState();
}

class _WordOverviewPageState extends State<WordOverviewPage>
    with SingleTickerProviderStateMixin {
  static const _statusLabels = ['等待学习', '已学习', '已掌握'];

  late final TabController _tabController;
  final ScrollController _bookFilterController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  List<Map<String, dynamic>> _books = [];
  int? _selectedBookId;
  List<List<Map<String, dynamic>>> _wordsByStatus = [[], [], []];
  bool _isLoading = true;
  bool _selectionMode = false;
  final Set<String> _selectedWords = {};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() {
      if (_tabController.indexIsChanging) {
        _exitSelectionMode();
      }
    });
    _loadData();
  }

  @override
  void dispose() {
    _bookFilterController.dispose();
    _searchController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  /// 对单词列表做客户端过滤（大小写不敏感）
  List<Map<String, dynamic>> _filterWords(List<Map<String, dynamic>> source) {
    final query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) return source;
    return source.where((item) {
      final word = (item['word'] as String).toLowerCase();
      return word.contains(query);
    }).toList();
  }

  // ─── 数据加载 ─────────────────────────────────

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final books = await LearningService.getAllBooksBrief();

      // 如果当前筛选的词书已被删除，重置为全部
      int? selectedBookId = _selectedBookId;
      if (selectedBookId != null &&
          !books.any((b) => b['id'] == selectedBookId)) {
        selectedBookId = null;
      }

      final futures = [0, 1, 2].map((status) {
        return LearningService.getWordsByStatus(
          status: status,
          bookId: selectedBookId,
        );
      }).toList();
      final results = await Future.wait(futures);

      if (mounted) {
        setState(() {
          _books = books;
          _selectedBookId = selectedBookId;
          _wordsByStatus = results;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  // ─── 多选模式 ─────────────────────────────────

  void _enterSelectionMode() {
    setState(() {
      _selectionMode = true;
      _selectedWords.clear();
    });
  }

  void _exitSelectionMode() {
    if (!_selectionMode) return;
    setState(() {
      _selectionMode = false;
      _selectedWords.clear();
    });
  }

  void _toggleSelect(String word) {
    setState(() {
      if (_selectedWords.contains(word)) {
        _selectedWords.remove(word);
      } else {
        _selectedWords.add(word);
      }
    });
  }

  void _toggleSelectAll() {
    final words = _filterWords(_wordsByStatus[_tabController.index]);
    setState(() {
      if (_selectedWords.length == words.length) {
        _selectedWords.clear();
      } else {
        _selectedWords
          ..clear()
          ..addAll(words.map((w) => w['word'] as String));
      }
    });
  }

  // ─── 批量操作（带二次确认） ──────────────────

  Future<bool> _confirmAction(String title, String content) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _markSelectedMastered() async {
    final words = _selectedWords.toList();
    if (words.isEmpty) return;

    final confirmed = await _confirmAction(
      '标记为已掌握',
      '确定将选中的 ${words.length} 个单词标记为已掌握吗？\n已掌握的单词将不再参与学习和复习。',
    );
    if (!confirmed || !mounted) return;

    await LearningService.markAsMasteredBatch(words);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已将 ${words.length} 个单词标记为已掌握')));
    _exitSelectionMode();
    await _loadData();
  }

  Future<void> _resetSelectedLearning() async {
    final words = _selectedWords.toList();
    if (words.isEmpty) return;

    final confirmed = await _confirmAction(
      '重新学习',
      '确定重置选中的 ${words.length} 个单词吗？\n重置后单词将回到"等待学习"状态，需要重新学习。',
    );
    if (!confirmed || !mounted) return;

    await LearningService.resetMasteredBatch(words);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已将 ${words.length} 个单词重置为等待学习')));
    _exitSelectionMode();
    await _loadData();
  }

  // ─── 单项操作（带二次确认） ──────────────────

  Future<void> _markOneMastered(String word) async {
    final confirmed = await _confirmAction(
      '标记为已掌握',
      '确定将 "$word" 标记为已掌握吗？\n已掌握的单词将不再参与学习和复习。',
    );
    if (!confirmed || !mounted) return;

    await LearningService.markAsMasteredBatch([word]);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('"$word" 已标记为掌握')));
    await _loadData();
  }

  Future<void> _resetOneLearning(String word) async {
    final confirmed = await _confirmAction(
      '重新学习',
      '确定重置 "$word" 吗？\n重置后单词将回到"等待学习"状态，需要重新学习。',
    );
    if (!confirmed || !mounted) return;

    await LearningService.resetMasteredBatch([word]);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('"$word" 已重置为等待学习')));
    await _loadData();
  }

  // ─── 打开单词详情 ────────────────────────────

  Future<void> _openWordDetail(String word) async {
    final result = await DictionaryService.searchEnExact(word);
    if (result == null || !mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WordDetailPage(
          result: CombinedResult(enEntry: result),
          word: word,
        ),
      ),
    );
  }

  // ─── UI 构建 ─────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('单词总览'),
        centerTitle: false,
        actions: [
          if (!_selectionMode)
            IconButton(
              icon: const Icon(Icons.checklist),
              tooltip: '多选',
              onPressed: _enterSelectionMode,
            )
          else
            TextButton(onPressed: _exitSelectionMode, child: const Text('完成')),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // 词书筛选
                _buildBookFilter(theme, colorScheme),
                // 搜索栏
                _buildSearchBar(theme, colorScheme),
                // TabBar
                TabBar(
                  controller: _tabController,
                  tabs: [
                    for (var i = 0; i < _statusLabels.length; i++)
                      Tab(
                        text:
                            '${_statusLabels[i]} (${_wordsByStatus[i].length})',
                      ),
                  ],
                ),
                // 多选模式时显示选中状态栏
                if (_selectionMode) _buildSelectionBar(theme, colorScheme),
                // Tab 内容
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      for (var i = 0; i < 3; i++)
                        _buildWordList(i, theme, colorScheme),
                    ],
                  ),
                ),
              ],
            ),
      // 多选操作栏
      bottomNavigationBar: _selectionMode
          ? _buildActionBar(theme, colorScheme)
          : null,
    );
  }

  Widget _buildBookFilter(ThemeData theme, ColorScheme colorScheme) {
    return SizedBox(
      height: 48,
      child: Scrollbar(
        controller: _bookFilterController,
        thumbVisibility: true,
        scrollbarOrientation: ScrollbarOrientation.bottom,
        child: Listener(
          onPointerSignal: (event) {
            // 桌面端鼠标滚轮：将垂直滚动转换为水平滚动
            if (event is PointerScrollEvent) {
              final delta = event.scrollDelta.dy;
              if (delta != 0) {
                final maxScroll =
                    _bookFilterController.position.maxScrollExtent;
                final target = (_bookFilterController.offset + delta).clamp(
                  0.0,
                  maxScroll,
                );
                _bookFilterController.jumpTo(target.toDouble());
              }
            }
          },
          child: ListView(
            controller: _bookFilterController,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: const Text('全部词书'),
                  selected: _selectedBookId == null,
                  onSelected: (_) {
                    setState(() => _selectedBookId = null);
                    _loadData();
                  },
                ),
              ),
              for (final book in _books)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(book['title'] as String),
                    selected: _selectedBookId == book['id'],
                    onSelected: (_) {
                      setState(() => _selectedBookId = book['id'] as int);
                      _loadData();
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 搜索栏：对当前 Tab 的单词列表做客户端过滤
  Widget _buildSearchBar(ThemeData theme, ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: TextField(
        controller: _searchController,
        decoration: InputDecoration(
          hintText: '搜索单词...',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear),
                  tooltip: '清空搜索',
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                  },
                )
              : null,
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        ),
        onChanged: (value) {
          setState(() => _searchQuery = value);
        },
      ),
    );
  }

  Widget _buildSelectionBar(ThemeData theme, ColorScheme colorScheme) {
    final total = _wordsByStatus[_tabController.index].length;
    final selected = _selectedWords.length;
    final allSelected = total > 0 && selected == total;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          Checkbox(value: allSelected, onChanged: (_) => _toggleSelectAll()),
          const SizedBox(width: 4),
          Text(
            allSelected ? '取消全选' : '全选（$selected/$total）',
            style: theme.textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }

  Widget _buildActionBar(ThemeData theme, ColorScheme colorScheme) {
    final currentStatus = _tabController.index;
    final selected = _selectedWords.length;

    if (currentStatus == 2) {
      // 已掌握：重新学习
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            onPressed: selected > 0 ? _resetSelectedLearning : null,
            icon: const Icon(Icons.replay),
            label: Text('重新学习（$selected）'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ),
      );
    }

    // 等待学习/已学习：标记已掌握
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: FilledButton.icon(
          onPressed: selected > 0 ? _markSelectedMastered : null,
          icon: const Icon(Icons.check_circle_outline),
          label: Text('标记已掌握（$selected）'),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
      ),
    );
  }

  Widget _buildWordList(int status, ThemeData theme, ColorScheme colorScheme) {
    final allWords = _wordsByStatus[status];
    final words = _filterWords(allWords);

    // 无匹配结果（搜索了但当前状态没有对应单词）
    if (allWords.isNotEmpty && words.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadData,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: 240,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.search_off,
                      size: 64,
                      color: colorScheme.primary.withValues(alpha: 0.3),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '没有匹配"$_searchQuery"的单词',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (words.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadData,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: 240,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      status == 0
                          ? Icons.playlist_add
                          : status == 1
                          ? Icons.school
                          : Icons.emoji_events_outlined,
                      size: 64,
                      color: colorScheme.primary.withValues(alpha: 0.3),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '暂无${_statusLabels[status]}的单词',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: words.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final item = words[index];
          final word = item['word'] as String;
          final books = (item['books'] as List).cast<String>();

          return ListTile(
            leading: _selectionMode
                ? Checkbox(
                    value: _selectedWords.contains(word),
                    onChanged: (_) => _toggleSelect(word),
                  )
                : null,
            onTap: () {
              if (_selectionMode) {
                _toggleSelect(word);
              } else {
                _openWordDetail(word);
              }
            },
            onLongPress: _selectionMode ? null : _enterSelectionMode,
            title: Text(
              word,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: books.isEmpty
                // 来源词书均已删除 → 显示「已删除词书」标签
                ? Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '已删除词书',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: books
                          .map(
                            (b) => Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                b,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  ),
            trailing: _selectionMode
                ? null
                : status == 2
                ? IconButton(
                    icon: const Icon(Icons.replay),
                    color: colorScheme.primary,
                    tooltip: '重新学习',
                    onPressed: () => _resetOneLearning(word),
                  )
                : IconButton(
                    icon: const Icon(Icons.check_circle_outline),
                    color: colorScheme.primary,
                    tooltip: '标记为已掌握',
                    onPressed: () => _markOneMastered(word),
                  ),
          );
        },
      ),
    );
  }
}
