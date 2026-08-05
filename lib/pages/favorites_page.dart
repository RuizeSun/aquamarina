import 'package:flutter/material.dart';
import '../models/word_entry.dart';
import '../models/word_note.dart';
import '../services/dictionary_service.dart';
import '../services/word_note_service.dart';
import 'word_detail_page.dart';

/// 单词收藏管理页：查看、搜索、取消收藏
class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key});

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage> {
  final _searchController = TextEditingController();
  List<WordNote> _favorites = [];
  Map<String, WordEntry> _entryCache = {};
  bool _isLoading = true;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);

    final favorites = _query.trim().isEmpty
        ? await WordNoteService.getFavorites()
        : await WordNoteService.searchFavorites(_query);

    // 批量查询词典释义（仅查询 ecdict，收藏大多为英文单词）
    final words = favorites.map((f) => f.word).toList();
    final entries = words.isEmpty
        ? <String, WordEntry>{}
        : await DictionaryService.searchEnExactBatch(words);

    if (!mounted) return;
    setState(() {
      _favorites = favorites;
      _entryCache = entries;
      _isLoading = false;
    });
  }

  void _onSearchChanged(String value) {
    _query = value;
    _loadData();
  }

  Future<void> _openWordDetail(WordNote favorite) async {
    final result = await DictionaryService.searchAllExact(favorite.word);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WordDetailPage(result: result, word: favorite.word),
      ),
    );
    // 可能从详情页取消了收藏，返回后刷新列表
    await _loadData();
  }

  /// 左滑或按钮取消收藏
  Future<void> _removeFavorite(WordNote favorite) async {
    if (!mounted) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('取消收藏'),
        content: Text('确定要取消收藏「${favorite.word}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('取消收藏'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    await WordNoteService.setFavorite(favorite.word, favorite: false);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text('已取消收藏「${favorite.word}」'),
          duration: const Duration(seconds: 1),
          behavior: SnackBarBehavior.floating,
        ),
      );
    await _loadData();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('单词收藏'), centerTitle: false),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: SizedBox(
              width: double.infinity,
              child: SearchBar(
                controller: _searchController,
                hintText: '搜索收藏的单词或笔记…',
                leading: const Icon(Icons.search),
                trailing: [
                  if (_searchController.text.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchController.clear();
                        _onSearchChanged('');
                      },
                    ),
                ],
                onChanged: _onSearchChanged,
              ),
            ),
          ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _favorites.isEmpty
                ? _buildEmptyState(theme, colorScheme)
                : _buildFavoriteList(),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme, ColorScheme colorScheme) {
    final isSearching = _query.trim().isNotEmpty;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isSearching ? Icons.search_off : Icons.star_border_rounded,
            size: 80,
            color: colorScheme.primary.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 16),
          Text(
            isSearching ? '未找到匹配的收藏' : '还没有收藏单词',
            style: theme.textTheme.titleMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isSearching ? '换个关键词试试吧' : '去词典查词，点击 ⭐ 收藏喜欢的单词',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFavoriteList() {
    final books = _favorites;
    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: books.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final favorite = books[index];
          final entry = _entryCache[favorite.word.toLowerCase()];
          return Dismissible(
            key: ValueKey('favorite_${favorite.word}'),
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
            onDismissed: (_) => _removeFavorite(favorite),
            child: ListTile(
              leading: Icon(Icons.star_rounded, color: Colors.amber.shade600),
              title: Row(
                children: [
                  Flexible(
                    child: Text(
                      favorite.word,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (favorite.note != null && favorite.note!.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Icon(
                      Icons.edit_note,
                      size: 16,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ],
                ],
              ),
              subtitle: _buildSubtitle(entry, favorite),
              onTap: () => _openWordDetail(favorite),
            ),
          );
        },
      ),
    );
  }

  Widget? _buildSubtitle(WordEntry? entry, WordNote favorite) {
    final hasNote = favorite.note != null && favorite.note!.isNotEmpty;
    final translation = entry?.translation;

    if (translation != null && translation.isNotEmpty && hasNote) {
      return Text(
        '$translation  ·  笔记: ${favorite.note}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );
    }
    if (hasNote) {
      return Text(
        '笔记: ${favorite.note}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );
    }
    if (translation != null && translation.isNotEmpty) {
      return Text(
        translation.replaceAll('\\n', ' '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );
    }
    return null;
  }
}
