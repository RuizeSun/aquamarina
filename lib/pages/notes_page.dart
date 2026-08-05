import 'package:flutter/material.dart';
import '../models/word_entry.dart';
import '../models/word_note.dart';
import '../services/dictionary_service.dart';
import '../services/word_note_service.dart';
import 'word_detail_page.dart';

/// 我的笔记页：查看所有做过笔记的单词
class NotesPage extends StatefulWidget {
  const NotesPage({super.key});

  @override
  State<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends State<NotesPage> {
  final _searchController = TextEditingController();
  List<WordNote> _notes = [];
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

    final notes = _query.trim().isEmpty
        ? await WordNoteService.getNotes()
        : await WordNoteService.searchNotes(_query);

    // 批量查询词典释义
    final words = notes.map((n) => n.word).toList();
    final entries = words.isEmpty
        ? <String, WordEntry>{}
        : await DictionaryService.searchEnExactBatch(words);

    if (!mounted) return;
    setState(() {
      _notes = notes;
      _entryCache = entries;
      _isLoading = false;
    });
  }

  void _onSearchChanged(String value) {
    _query = value;
    _loadData();
  }

  Future<void> _openWordDetail(WordNote note) async {
    final result = await DictionaryService.searchAllExact(note.word);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WordDetailPage(result: result, word: note.word),
      ),
    );
    // 可能从详情页修改/删除了笔记，返回后刷新列表
    await _loadData();
  }

  /// 删除笔记
  Future<void> _deleteNote(WordNote note) async {
    if (!mounted) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除笔记'),
        content: Text('确定要删除「${note.word}」的笔记吗？'),
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

    // 保存空笔记即删除笔记（若该词仅收藏无笔记，会保留收藏标记）
    await WordNoteService.saveNote(note.word, '');
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text('已删除「${note.word}」的笔记'),
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
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: SizedBox(
              width: double.infinity,
              child: SearchBar(
                controller: _searchController,
                hintText: '搜索笔记单词或内容…',
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
                : _notes.isEmpty
                ? _buildEmptyState(theme, colorScheme)
                : _buildNoteList(),
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
            isSearching ? '未找到匹配的笔记' : '还没有单词笔记',
            style: theme.textTheme.titleMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isSearching ? '换个关键词试试吧' : '去词典查词，在单词详情页添加笔记',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoteList() {
    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _notes.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final note = _notes[index];
          final entry = _entryCache[note.word.toLowerCase()];
          return _NoteCard(
            note: note,
            entry: entry,
            onTap: () => _openWordDetail(note),
            onDelete: () => _deleteNote(note),
          );
        },
      ),
    );
  }
}

/// 笔记卡片
class _NoteCard extends StatelessWidget {
  final WordNote note;
  final WordEntry? entry;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _NoteCard({
    required this.note,
    required this.entry,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final translation = entry?.translation;

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
                  Icon(Icons.edit_note, size: 18, color: colorScheme.primary),
                  const SizedBox(width: 8),
                  Text(
                    note.word,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: colorScheme.primary,
                    ),
                  ),
                  const Spacer(),
                  if (note.isFavorited) ...[
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
              if (translation != null && translation.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    translation.replaceAll('\\n', ' '),
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
                  note.note ?? '',
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
