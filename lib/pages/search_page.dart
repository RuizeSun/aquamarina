import 'package:flutter/material.dart';
import '../models/word_entry.dart';
import '../services/dictionary_service.dart';
import 'word_card.dart';

/// 将数据库中的字面 \n 替换为真正的换行符
String _normalizeNewlines(String? text) {
  if (text == null) return '';
  return text.replaceAll('\\n', '\n');
}

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _searchController = TextEditingController();
  final _focusNode = FocusNode();
  List<SearchResult> _suggestions = [];
  CombinedResult? _selectedResult;
  bool _isSearching = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    final query = _searchController.text.trim();
    if (query.isEmpty) {
      setState(() {
        _suggestions = [];
        _selectedResult = null;
        _errorMessage = null;
      });
      return;
    }
    _performFuzzySearch(query);
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
    setState(() {
      _isSearching = true;
      _errorMessage = null;
      _suggestions = [];
    });

    try {
      final result = await DictionaryService.searchAllExact(word);
      if (!mounted) return;
      setState(() {
        _selectedResult = result;
        _isSearching = false;
        if (!result.hasAny) {
          _errorMessage = '未找到 "$word" 的释义';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSearching = false;
        _errorMessage = '查询失败: $e';
      });
    }
  }

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
                        _selectedResult = null;
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
          Expanded(child: _buildContent()),
        ],
      ),
    );
  }

  Widget _buildContent() {
    if (_isSearching) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return Center(
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
    }

    if (_selectedResult != null) {
      return SingleChildScrollView(child: _buildDetailResult());
    }

    if (_suggestions.isNotEmpty) {
      return ListView.separated(
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

          return ListTile(
            leading: Icon(
              leadingIcon,
              color: Theme.of(context).colorScheme.primary,
            ),
            title: Text(result.displayWord),
            subtitle:
                result.displaySubtitle != null &&
                    result.displaySubtitle!.isNotEmpty
                ? Text(
                    _normalizeNewlines(result.displaySubtitle),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  )
                : null,
            trailing: trailing,
            onTap: () => _onSelectWord(result.displayWord),
          );
        },
      );
    }

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.menu_book_rounded,
            size: 80,
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
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

  Widget _buildDetailResult() {
    final result = _selectedResult!;
    final children = <Widget>[];

    if (result.enEntry != null) {
      children.add(WordCard(entry: result.enEntry!));
    }

    if (result.cnEntry != null) {
      children.add(_CedictCard(entry: result.cnEntry!));
    }

    return Column(children: children);
  }
}

class _CedictCard extends StatelessWidget {
  final CedictEntry entry;

  const _CedictCard({required this.entry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 简体中文 & 繁体
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  entry.simplified,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: colorScheme.primary,
                  ),
                ),
                if (entry.traditional != null &&
                    entry.traditional != entry.simplified)
                  Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Text(
                      entry.traditional!,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),

            // 拼音
            if (entry.pinyin != null && entry.pinyin!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  entry.pinyin!,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),

            const SizedBox(height: 16),

            // 英文释义
            _Section(
              title: '英文释义',
              child: Text(
                _normalizeNewlines(entry.definitions),
                style: theme.textTheme.bodyLarge,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final Widget child;

  const _Section({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          child,
        ],
      ),
    );
  }
}
