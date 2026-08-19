import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/word_entry.dart';
import '../services/dictionary_service.dart';
import 'vocabulary/shared/word_utils.dart';
import 'word_detail_page.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _searchController = TextEditingController();
  final _focusNode = FocusNode();
  List<SearchResult> _suggestions = [];
  bool _isSearching = false;
  String? _errorMessage;
  List<String> _searchHistory = [];
  Timer? _debounceTimer;

  static const _historyKey = 'search_history';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _loadSearchHistory();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
      // 强制弹出系统软键盘（app 启动时仅执行一次）
      SystemChannels.textInput.invokeMethod<void>('TextInput.show');
    });
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _loadSearchHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final history = prefs.getStringList(_historyKey);
    if (!mounted) return;
    setState(() {
      _searchHistory = history ?? [];
    });
  }

  Future<void> _addToHistory(String word) async {
    _searchHistory.remove(word);
    _searchHistory.insert(0, word);
    if (_searchHistory.length > 30) {
      _searchHistory = _searchHistory.sublist(0, 30);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_historyKey, _searchHistory);
  }

  Future<void> _removeFromHistory(int index) async {
    setState(() {
      _searchHistory.removeAt(index);
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_historyKey, _searchHistory);
  }

  Future<void> _clearHistory() async {
    setState(() {
      _searchHistory.clear();
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_historyKey);
  }

  void _onSearchChanged() {
    final query = _searchController.text.trim();
    if (query.isEmpty) {
      _debounceTimer?.cancel();
      setState(() {
        _suggestions = [];
        _errorMessage = null;
      });
      return;
    }
    // 防抖：取消上一次的延迟搜索，等待用户停止输入后再查询
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      _performFuzzySearch(query);
    });
  }

  Future<void> _performFuzzySearch(String query) async {
    setState(() {
      _isSearching = true;
      _errorMessage = null;
    });

    try {
      final results = await DictionaryService.searchAllFuzzy(query);
      if (!mounted) return;
      setState(() {
        _suggestions = results;
        _isSearching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSearching = false;
        _errorMessage = '搜索失败: $e';
      });
    }
  }

  Future<void> _onSelectWord(String word) async {
    if (!mounted) return;

    try {
      final result = await DictionaryService.searchAllExact(word);
      if (!mounted) return;

      // 单词不存在时不允许进入详情页
      if (!result.hasAny) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('未找到「$word」的匹配结果'),
            duration: const Duration(seconds: 1),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      await _addToHistory(word);

      if (!mounted) return;

      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => WordDetailPage(result: result, word: word),
        ),
      );

      // 返回后保留搜索上下文，不清空搜索框和联想结果
      setState(() {
        _errorMessage = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = '查询失败: $e';
      });
    }
  }

  bool get _isIdle => _searchController.text.trim().isEmpty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Aquamarina',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: colorScheme.primary,
          ),
        ),
        centerTitle: false,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: SizedBox(
              width: double.infinity,
              child: SearchBar(
                controller: _searchController,
                focusNode: _focusNode,
                hintText: '输入单词/中文查询...',
                leading: const Icon(Icons.search),
                trailing: [
                  if (_searchController.text.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchController.clear();
                        setState(() {
                          _suggestions = [];
                          _errorMessage = null;
                        });
                        _focusNode.requestFocus();
                      },
                    ),
                ],
                onSubmitted: (value) {
                  if (value.trim().isNotEmpty) {
                    _onSelectWord(value.trim());
                  }
                },
              ),
            ),
          ),
          Expanded(child: _isIdle ? _buildHistoryContent() : _buildContent()),
        ],
      ),
    );
  }

  /// 空闲时显示搜索历史或默认提示
  Widget _buildHistoryContent() {
    if (_searchHistory.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.menu_book_rounded,
              size: 80,
              color: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 16),
            Text(
              '输入单词或中文开始查询',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '支持英汉双词典离线查询',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              Icon(
                Icons.history,
                size: 18,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Text(
                '搜索历史',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                icon: const Icon(Icons.delete_sweep, size: 18),
                label: const Text('清空'),
                onPressed: _clearHistory,
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: _searchHistory.length,
            itemBuilder: (context, index) {
              final word = _searchHistory[index];
              return Dismissible(
                key: ValueKey('history_$word'),
                direction: DismissDirection.endToStart,
                background: Container(
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 20),
                  color: Theme.of(context).colorScheme.error,
                  child: Icon(
                    Icons.delete_outline,
                    color: Theme.of(context).colorScheme.onError,
                  ),
                ),
                onDismissed: (_) => _removeFromHistory(index),
                child: ListTile(
                  leading: Icon(
                    Icons.history,
                    size: 20,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  title: Text(word),
                  trailing: Icon(
                    Icons.chevron_right,
                    size: 20,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  dense: true,
                  onTap: () => _onSelectWord(word),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildContent() {
    final Widget content;
    final query = _searchController.text.trim();

    if (_isSearching) {
      content = const Center(
        key: ValueKey('searching'),
        child: CircularProgressIndicator(),
      );
    } else if (_errorMessage != null) {
      content = Center(
        key: ValueKey('error_$query'),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.search_off,
                size: 64,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
          ),
        ),
      );
    } else if (_suggestions.isNotEmpty) {
      content = ListView.separated(
        key: ValueKey('results_$query'),
        itemCount: _suggestions.length,
        separatorBuilder: (_, a) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final result = _suggestions[index];
          final leadingIcon = result.source == 'ecdict'
              ? Icons.text_fields
              : Icons.translate;
          final trailing =
              result.source == 'ecdict' &&
                  result.enEntry?.collins != null &&
                  result.enEntry!.collins! > 0
              ? Text(
                  '★' * result.enEntry!.collins!,
                  style: TextStyle(color: Colors.amber.shade600),
                )
              : null;

          return _StaggeredFadeIn(
            index: index,
            child: ListTile(
              leading: Icon(
                leadingIcon,
                color: Theme.of(context).colorScheme.primary,
              ),
              title: Text(result.displayWord),
              subtitle:
                  result.displaySubtitle != null &&
                      result.displaySubtitle!.isNotEmpty
                  ? Text(
                      normalizeNewlines(result.displaySubtitle),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    )
                  : null,
              trailing: trailing,
              onTap: () => _onSelectWord(result.displayWord),
            ),
          );
        },
      );
    } else {
      // 搜索完成但无匹配结果
      content = Center(
        key: ValueKey('no_results_$query'),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.search_off,
              size: 64,
              color: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 16),
            Text(
              '未找到"$query"的匹配结果',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '请检查拼写或尝试其他关键词',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      child: content,
    );
  }
}

/// 带交错延迟的淡入动画容器，用于搜索结果列表逐项浮现
class _StaggeredFadeIn extends StatefulWidget {
  static const _duration = Duration(milliseconds: 250);
  static const _delayPerItem = Duration(milliseconds: 40);

  final int index;
  final Widget child;

  const _StaggeredFadeIn({required this.index, required this.child});

  @override
  State<_StaggeredFadeIn> createState() => _StaggeredFadeInState();
}

class _StaggeredFadeInState extends State<_StaggeredFadeIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<Offset> _offset;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: _StaggeredFadeIn._duration,
    );
    final curved = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );
    _opacity = curved;
    _offset = Tween<Offset>(
      begin: const Offset(0, 0.15),
      end: Offset.zero,
    ).animate(curved);

    Future.delayed(_StaggeredFadeIn._delayPerItem * widget.index, () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: SlideTransition(position: _offset, child: widget.child),
    );
  }
}
