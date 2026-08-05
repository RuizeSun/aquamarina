import 'package:flutter/material.dart';
import '../models/word_entry.dart';
import '../services/dictionary_service.dart';
import '../services/tts_service.dart';
import '../services/word_note_service.dart';
import 'word_card.dart';

/// 将数据库中的字面 \n 替换为真正的换行符
String _normalizeNewlines(String? text) {
  if (text == null) return '';
  return text.replaceAll('\\n', '\n');
}

class WordDetailPage extends StatefulWidget {
  final CombinedResult result;
  final String word;

  const WordDetailPage({super.key, required this.result, required this.word});

  @override
  State<WordDetailPage> createState() => _WordDetailPageState();
}

class _WordDetailPageState extends State<WordDetailPage> {
  bool _isFavorited = false;
  String? _note;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadWordNote();
  }

  Future<void> _loadWordNote() async {
    final wordNote = await WordNoteService.getWordNote(widget.word);
    if (!mounted) return;
    setState(() {
      _isFavorited = wordNote?.isFavorited ?? false;
      _note = wordNote?.note;
      _isLoading = false;
    });
  }

  /// 切换收藏状态
  Future<void> _toggleFavorite() async {
    final target = !_isFavorited;
    setState(() => _isFavorited = target);
    await WordNoteService.setFavorite(widget.word, favorite: target);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            target ? '已收藏「${widget.word}」' : '已取消收藏「${widget.word}」',
          ),
          duration: const Duration(seconds: 1),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  /// 弹出笔记编辑对话框
  Future<void> _editNote() async {
    final controller = TextEditingController(text: _note ?? '');
    final hasNote = _note != null && _note!.isNotEmpty;

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('笔记 · ${widget.word}'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 6,
          minLines: 3,
          decoration: const InputDecoration(
            hintText: '记录词根词缀、记忆方法、例句或易混淆点…',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          if (hasNote)
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(''),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              child: const Text('删除'),
            ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );

    if (result == null) return;
    final trimmed = result.trim();
    await WordNoteService.saveNote(widget.word, trimmed);
    if (!mounted) return;
    setState(() => _note = trimmed.isEmpty ? null : trimmed);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.word,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: colorScheme.primary,
          ),
        ),
        centerTitle: false,
        actions: [
          IconButton(
            icon: Icon(
              _isFavorited ? Icons.star_rounded : Icons.star_outline_rounded,
              color: _isFavorited ? Colors.amber : colorScheme.primary,
            ),
            tooltip: _isFavorited ? '取消收藏' : '收藏',
            onPressed: _toggleFavorite,
          ),
          IconButton(
            icon: Icon(Icons.volume_up, color: colorScheme.primary),
            tooltip: '朗读',
            onPressed: () => TtsService.instance.speak(widget.word),
          ),
        ],
      ),
      body: _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    final children = <Widget>[];

    if (widget.result.enEntry != null) {
      children.add(WordCard(entry: widget.result.enEntry!));
    }

    if (widget.result.cnEntry != null) {
      children.add(_CedictCard(entry: widget.result.cnEntry!));
    }

    if (!widget.result.hasAny) {
      return Center(
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
              '未找到 "${widget.word}" 的释义',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ],
        ),
      );
    }

    if (!_isLoading) {
      children.add(
        _NoteCard(word: widget.word, note: _note, onEdit: _editNote),
      );
    }

    return SingleChildScrollView(child: Column(children: children));
  }
}

/// 我的笔记卡片
class _NoteCard extends StatelessWidget {
  final String word;
  final String? note;
  final VoidCallback onEdit;

  const _NoteCard({
    required this.word,
    required this.note,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final hasNote = note != null && note!.isNotEmpty;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.edit_note, size: 20, color: colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  '我的笔记',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: Icon(
                    Icons.edit_outlined,
                    size: 18,
                    color: colorScheme.primary,
                  ),
                  tooltip: hasNote ? '编辑笔记' : '添加笔记',
                  onPressed: onEdit,
                ),
              ],
            ),
            if (hasNote)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(note!, style: theme.textTheme.bodyMedium),
              )
            else
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '点击右上角添加笔记，记录词根词缀、记忆方法或易混淆点…',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
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
