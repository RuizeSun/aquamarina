import 'package:flutter/material.dart';
import '../models/ai_sentence.dart';
import '../services/sentence_note_service.dart';

/// 句子收藏与笔记按钮组
///
/// 供句式集编辑页、练习会话页等处复用。内部自行加载并维护收藏/笔记状态。
class SentenceNoteBar extends StatefulWidget {
  final Sentence sentence;

  /// 图标颜色（默认使用主题主色）
  final Color? iconColor;

  const SentenceNoteBar({super.key, required this.sentence, this.iconColor});

  @override
  State<SentenceNoteBar> createState() => _SentenceNoteBarState();
}

class _SentenceNoteBarState extends State<SentenceNoteBar> {
  bool _isFavorited = false;
  bool _hasNote = false;
  bool _isLoading = true;

  Sentence get _sentence => widget.sentence;

  @override
  void initState() {
    super.initState();
    _loadState();
  }

  Future<void> _loadState() async {
    final sentenceId = _sentence.id;
    if (sentenceId == null || sentenceId.isEmpty) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }
    final note = await SentenceNoteService.getSentenceNote(sentenceId);
    if (!mounted) return;
    setState(() {
      _isFavorited = note?.isFavorited ?? false;
      _hasNote = note?.note != null && note!.note!.isNotEmpty;
      _isLoading = false;
    });
  }

  Future<void> _toggleFavorite() async {
    final target = !_isFavorited;
    setState(() => _isFavorited = target);
    await SentenceNoteService.setFavorite(_sentence, favorite: target);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            target ? '已收藏该句' : '已取消收藏该句',
          ),
          duration: const Duration(seconds: 1),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  /// 弹出句子笔记编辑对话框
  Future<void> _editNote() async {
    final controller = TextEditingController();
    final sentenceId = _sentence.id;
    if (sentenceId != null && sentenceId.isNotEmpty) {
      final note = await SentenceNoteService.getSentenceNote(sentenceId);
      if (mounted) controller.text = note?.note ?? '';
    }
    final hasNote = controller.text.trim().isNotEmpty;
    if (!mounted) return;

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('句子笔记'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 6,
          minLines: 3,
          decoration: const InputDecoration(
            hintText: '记录句型要点、易错点或例句…',
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
    await SentenceNoteService.saveNote(_sentence, trimmed);
    if (!mounted) return;
    setState(() => _hasNote = trimmed.isNotEmpty);
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.iconColor ?? Theme.of(context).colorScheme.primary;
    if (_isLoading) {
      return const SizedBox(
        width: 72,
        height: 40,
        child: Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: Icon(
            _isFavorited ? Icons.star_rounded : Icons.star_outline_rounded,
            color: _isFavorited ? Colors.amber : color,
          ),
          tooltip: _isFavorited ? '取消收藏' : '收藏',
          onPressed: _toggleFavorite,
          visualDensity: VisualDensity.compact,
        ),
        IconButton(
          icon: Icon(
            _hasNote ? Icons.edit_note : Icons.note_add_outlined,
            color: _hasNote ? color : color.withValues(alpha: 0.7),
          ),
          tooltip: _hasNote ? '编辑笔记' : '添加笔记',
          onPressed: _editNote,
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}
