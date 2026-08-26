import 'package:flutter/material.dart';
import '../models/ai_sentence.dart';
import '../models/sentence_note.dart';
import '../services/sentence_note_service.dart';

/// 展示句子详情底部弹窗：可查看内容、编辑笔记、取消收藏。
///
/// [onChanged] 在收藏/笔记状态变化后回调，用于刷新列表。
Future<void> showSentenceDetailSheet(
  BuildContext context,
  SentenceNote note, {
  Future<void> Function()? onChanged,
}) async {
  final sentence = Sentence(
    id: note.sentenceId,
    setId: note.setId ?? '',
    english: note.english,
    chinese: note.chinese,
  );

  final action = await showModalBottomSheet<dynamic>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      final colorScheme = theme.colorScheme;
      return SafeArea(
        child: Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '句子详情',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                note.english,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                note.chinese,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              if (note.note != null && note.note!.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colorScheme.secondaryContainer.withValues(
                      alpha: 0.3,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    note.note!,
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.edit_note, size: 18),
                    label: const Text('编辑笔记'),
                    onPressed: () async {
                      final edited = await _editSentenceNote(ctx, sentence);
                      if (edited && ctx.mounted) {
                        Navigator.of(ctx).pop(true);
                      }
                    },
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.star_outline, size: 18),
                    label: const Text('取消收藏'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: colorScheme.error,
                    ),
                    onPressed: () async {
                      await SentenceNoteService.setFavorite(
                        sentence,
                        favorite: false,
                      );
                      if (ctx.mounted) Navigator.of(ctx).pop(true);
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );

  if (action == true) {
    await onChanged?.call();
  }
}

/// 编辑句子笔记对话框（与 SentenceNoteBar 逻辑一致）
Future<bool> _editSentenceNote(BuildContext context, Sentence sentence) async {
  final existing = await SentenceNoteService.getSentenceNote(
    sentence.id ?? '',
  );
  final controller = TextEditingController(text: existing?.note ?? '');
  final hasNote = controller.text.trim().isNotEmpty;
  if (!context.mounted) return false;

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
              foregroundColor: Theme.of(ctx).colorScheme.error,
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

  if (result == null) return false;
  await SentenceNoteService.saveNote(sentence, result.trim());
  return true;
}
