import 'package:flutter/material.dart';
import '../models/word_entry.dart';
import '../services/dictionary_service.dart';
import '../services/sentence_note_service.dart';
import '../services/word_note_service.dart';
import 'saved_filter_bar.dart';
import 'saved_models.dart';
import 'sentence_detail_sheet.dart';
import 'word_detail_page.dart';

/// 我的笔记页：查看所有做过笔记的单词与句子，支持筛选与排序
class NotesPage extends StatefulWidget {
  const NotesPage({super.key});

  @override
  State<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends State<NotesPage> {
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

    final wordNotes = _query.trim().isEmpty
        ? await WordNoteService.getNotes()
        : await WordNoteService.searchNotes(_query);
    final sentenceNotes = _query.trim().isEmpty
        ? await SentenceNoteService.getNotes()
        : await SentenceNoteService.searchNotes(_query);

    final words = wordNotes.map((n) => n.word).toList();
    final entries = words.isEmpty
        ? <String, WordEntry>{}
        : await DictionaryService.searchEnExactBatch(words);

    final merged = <SavedEntry>[
      for (final w in wordNotes)
        SavedEntry.fromWord(
          w,
          subtitle: _cleanTranslation(entries[w.word.toLowerCase()]?.translation),
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

  /// 删除笔记（单词或句子）
  Future<void> _deleteNote(SavedEntry entry) async {
    if (!mounted) return;
    final label = entry.type == SavedType.word ? '「${entry.title}」' : '该句';
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除笔记'),
        content: Text('确定要删除$label的笔记吗？'),
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
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    if (entry.type == SavedType.word) {
      await WordNoteService.saveNote(entry.title, '');
    } else {
      await SentenceNoteService.saveNote(
        SentenceNoteService.toSentence(entry.sentenceNote!),
        '',
      );
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text('已删除笔记'),
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
      appBar: AppBar(title: const Text('我的笔记'), centerTitle: false),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: SizedBox(
              width: double.infinity,
              child: SearchBar(
                controller: _searchController,
                hintText: '搜索笔记的单词或句子…',
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
                : _buildNotesList(),
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
            isSearching ? Icons.search_off : Icons.edit_note,
            size: 80,
            color: colorScheme.primary.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 16),
          Text(
            isSearching ? '未找到匹配的笔记' : '还没有笔记',
            style: theme.textTheme.titleMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isSearching
                ? '换个关键词试试吧'
                : '去词典给单词记笔记，或在句型练习中给句子记笔记',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNotesList() {
    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _entries.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final entry = _entries[index];
          return _NoteCard(
            entry: entry,
            onTap: () => _openEntry(entry),
            onDelete: () => _deleteNote(entry),
          );
        },
      ),
    );
  }
}


/// 笔记卡片（单词或句子）
class _NoteCard extends StatelessWidget {
  final SavedEntry entry;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _NoteCard({
    required this.entry,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isWord = entry.type == SavedType.word;
    final subtitle = entry.subtitle;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    isWord ? Icons.edit_note : Icons.format_quote,
                    size: 18,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      entry.title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: colorScheme.primary,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (entry.isFavorited) ...[
                    Icon(
                      Icons.star_rounded,
                      size: 16,
                      color: Colors.amber.shade600,
                    ),
                    const SizedBox(width: 8),
                  ],
                  IconButton(
                    icon: Icon(
                      Icons.delete_outline,
                      size: 18,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    tooltip: '删除笔记',
                    onPressed: onDelete,
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
              if (subtitle != null && subtitle.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  entry.note ?? '',
                  style: theme.textTheme.bodyMedium,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
