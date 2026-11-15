import 'package:flutter/material.dart';

/// 对话中的「上下文注入」卡片。
///
/// 参照 DeepSeek Harness 的呈现：默认折叠成一行小字，点开才看到注入的
/// 原始文本。避免把 <context-note> 这类系统内容当成用户气泡直接铺开。
class ContextNoteCard extends StatelessWidget {
  const ContextNoteCard({
    super.key,
    required this.note,
    required this.tags,
  });

  /// 注入的完整文本（含 <context-note> 包装）。
  final String note;

  /// 注入包含的分块名，例如 runtime-context、time-context。
  final List<String> tags;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final label = tags.isEmpty ? '上下文注入' : '上下文注入 · ${tags.join(' + ')}';

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.6)),
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.25),
      ),
      // ExpansionTile 内部是 ListTile，必须在 Material 之上绘制水波纹，
      // 否则外层带背景色的 Container 会触发框架断言。
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 10),
          childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
          dense: true,
          visualDensity: VisualDensity.compact,
          leading: Icon(
            Icons.download_done,
            size: 16,
            color: colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
          ),
          title: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: colorScheme.surface.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(6),
              ),
              child: SelectableText(
                _stripWrapper(note),
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  height: 1.5,
                ),
              ),
            ),
          ],
          ),
        ),
      ),
    );
  }

  /// 去掉 <context-note> 包装与说明文字，只留各分块的原始内容。
  static String _stripWrapper(String note) {
    final start = note.indexOf('<runtime-context>');
    final tags = RegExp(r'<(?:runtime|time)-context>').firstMatch(note);
    final index = start >= 0 ? start : (tags?.start ?? -1);
    final body = index >= 0 ? note.substring(index) : note;
    return body.replaceAll('</context-note>', '').trimRight();
  }
}
