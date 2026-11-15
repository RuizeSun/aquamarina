import 'dart:convert';

import 'package:flutter/material.dart';

import '../../models/ai_chat.dart';

/// 对话中的一次工具调用卡片：工具名、参数摘要与执行状态。
class ToolCallCard extends StatelessWidget {
  const ToolCallCard({super.key, required this.record});

  final AiToolCallRecord record;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final (icon, color, label) = _appearance(colorScheme);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colorScheme.outlineVariant),
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
      ),
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          leading: Icon(icon, size: 20, color: color),
          title: Text(
            record.call.name,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text('参数', style: theme.textTheme.labelSmall),
            ),
            const SizedBox(height: 4),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: colorScheme.surface.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(6),
              ),
              child: SelectableText(
                _pretty(record.call.rawArguments),
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ),
            if (record.resultPreview != null &&
                record.resultPreview!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text('结果', style: theme.textTheme.labelSmall),
              ),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: colorScheme.surface.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SelectableText(
                  record.resultPreview!,
                  maxLines: 8,
                  style: const TextStyle(fontSize: 12, height: 1.4),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  (IconData, Color, String) _appearance(ColorScheme colorScheme) {
    switch (record.state) {
      case AiToolCallState.pending:
        return (Icons.hourglass_empty, colorScheme.primary, '等待批准');
      case AiToolCallState.approved:
        return (Icons.play_circle_outline, colorScheme.primary, '已批准');
      case AiToolCallState.denied:
        return (Icons.block, colorScheme.error, '已被拒绝');
      case AiToolCallState.done:
        return (Icons.check_circle_outline, Colors.green, '已执行');
      case AiToolCallState.failed:
        return (
          Icons.error_outline,
          colorScheme.error,
          '执行失败${record.errorCode == null ? '' : '（${record.errorCode}）'}',
        );
    }
  }

  String _pretty(String raw) {
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(raw));
    } catch (_) {
      return raw.isEmpty ? '（无参数）' : raw;
    }
  }
}
