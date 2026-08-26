import 'package:flutter/material.dart';
import '../models/word_entry.dart';
import '../services/dictionary_service.dart';
import '../services/sentence_note_service.dart';
import '../services/word_note_service.dart';
import 'saved_filter_bar.dart';
import 'saved_models.dart';
import 'sentence_detail_sheet.dart';
import 'word_detail_page.dart';

/// 收藏管理页：查看、搜索单词与句子收藏，支持筛选与排序
class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key});

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage> {
  final _searchController = TextEditingController();
  List<SavedEntry> _entries = [];
  bool _isLoading = true;
  String _query = '';
  SavedType? _filterType;
  SavedSort _sort = SavedSort.time;

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

    // 加载单词收藏 + 句子收藏
    final wordNotes = _query.trim().isEmpty
        ? await WordNoteService.getFavorites()
        : await WordNoteService.searchFavorites(_query);
    final sentenceNotes = _query.trim().isEmpty
        ? await SentenceNoteService.getFavorites()
        : await SentenceNoteService.searchFavorites(_query);

    // 批量查询词典释义
    final words = wordNotes.map((f) => f.word).toList();
    final entries = words.isEmpty
        ? <String, WordEntry>{}
        : await DictionaryService.searchEnExactBatch(words);

    // 合并为统一条目
    final merged = <SavedEntry>[
      for (final w in wordNotes)
        SavedEntry.fromWord(
          w,
          subtitle: _cleanTranslation(
            entries[w.word.toLowerCase()]?.translation,
          ),
        ),
      for (final s in sentenceNotes) SavedEntry.fromSentence(s),
    ];

    final filtered = filterSavedEntries(merged, _filterType);
    final sorted = sortSavedEntries(filtered, _sort);

    if (!mounted) return;
    setState(() {
      _entries = sorted;
      _isLoading = false;
    });
  }

  String? _cleanTranslation(String? translation) {
    if (translation == null || translation.isEmpty) return null;
    return translation.replaceAll('\\n', ' ');
  }

  void _onSearchChanged(String value) {
    _query = value;
    _loadData();
  }

  void _onFilterChanged(SavedType? type) {
    setState(() => _filterType = type);
    _loadData();
  }

  void _onSortChanged(SavedSort sort) {
    setState(() => _sort = sort);
    _loadData();
  }

  Future<void> _openEntry(SavedEntry entry) async {
    if (entry.type == SavedType.word) {
      final wordNote = entry.wordNote!;
      final result = await DictionaryService.searchAllExact(wordNote.word);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) =>
              WordDetailPage(result: result, word: wordNote.word),
        ),
      );
      await _loadData();
    } else {
      await showSentenceDetailSheet(context, entry.sentenceNote!,
          onChanged: _loadData);
    }
  }

  /// 取消收藏（单词或句子）
  Future<void> _removeEntry(SavedEntry entry) async {
    if (!mounted) return;
    final label = entry.type == SavedType.word ? entry.title : '该句';
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('取消收藏'),
        content: Text(
          entry.type == SavedType.word
              ? '确定要取消收藏「${entry.title}」吗？'
              : '确定要取消收藏这个句子吗？',
        ),
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

    if (entry.type == SavedType.word) {
      await WordNoteService.setFavorite(entry.title, favorite: false);
    } else {
      await SentenceNoteService.setFavorite(
        SentenceNoteService.toSentence(entry.sentenceNote!),
        favorite: false,
      );
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text('已取消收藏「$label」'),
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
      appBar: AppBar(title: const Text('我的收藏'), centerTitle: false),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: SizedBox(
              width: double.infinity,
              child: SearchBar(
                controller: _searchController,
                hintText: '搜索收藏的单词或句子…',
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
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: SavedFilterBar(
              filterType: _filterType,
              sort: _sort,
              onFilterChanged: _onFilterChanged,
              onSortChanged: _onSortChanged,
            ),
          ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _entries.isEmpty
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
            isSearching ? '未找到匹配的收藏' : '还没有收藏内容',
            style: theme.textTheme.titleMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isSearching
                ? '换个关键词试试吧'
                : '去词典收藏单词，或在句型练习中点 ⭐ 收藏句子',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFavoriteList() {
    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _entries.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final entry = _entries[index];
          return Dismissible(
            key: ValueKey('fav_${entry.type}_${entry.title}'),
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
            onDismissed: (_) => _removeEntry(entry),
            child: _SavedListTile(entry: entry, onTap: () => _openEntry(entry)),
          );
        },
      ),
    );
  }
}

/// 收藏/笔记页通用条目卡片（单词或句子）
class _SavedListTile extends StatelessWidget {
  final SavedEntry entry;
  final VoidCallback onTap;

  const _SavedListTile({required this.entry, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isWord = entry.type == SavedType.word;
    final hasNote = entry.note != null && entry.note!.isNotEmpty;

    return ListTile(
      leading: Icon(
        isWord ? Icons.star_rounded : Icons.format_quote,
        color: isWord ? Colors.amber.shade600 : theme.colorScheme.primary,
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              entry.title,
              style: const TextStyle(fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (hasNote) ...[
            const SizedBox(width: 6),
            Icon(
              Icons.edit_note,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ],
      ),
      subtitle: _buildSubtitle(),
      isThreeLine: isWord,
      onTap: onTap,
    );
  }

  Widget? _buildSubtitle() {
    final hasNote = entry.note != null && entry.note!.isNotEmpty;
    final subtitle = entry.subtitle;

    if (entry.type == SavedType.sentence) {
      // 句子：中文翻译 + 笔记
      final parts = <String>[
        if (subtitle != null && subtitle.isNotEmpty) subtitle,
        if (hasNote) '笔记: ${entry.note}',
      ];
      return parts.isEmpty
          ? null
          : Text(
              parts.join('  ·  '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            );
    }

    // 单词
    if (subtitle != null && subtitle.isNotEmpty && hasNote) {
      return Text(
        '$subtitle  ·  笔记: ${entry.note}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );
    }
    if (hasNote) {
      return Text(
        '笔记: ${entry.note}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );
    }
    if (subtitle != null && subtitle.isNotEmpty) {
      return Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis);
    }
    return null;
  }
}
