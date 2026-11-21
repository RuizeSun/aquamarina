import 'package:flutter/material.dart';

import '../../models/ai_chat.dart';
import 'chat_labels.dart';
import 'tool_arguments_view.dart';

/// 对话中的一次工具调用卡片：中文动作名、执行状态、参数与结果。
///
/// 卡片本身是「思考过程」手风琴里的一页：折叠时只露一行摘要，展开后才看到
/// 送给模型的参数和工具返回的原始文本，避免工具输出把正式回答挤到屏幕外。
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
      // ExpansionTile 内部是 ListTile，水波纹必须画在 Material 上；
      // 外层 Container 自带背景色，不隔一层 Material 会触发框架断言。
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: Theme(
          data: theme.copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 12),
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            leading: Icon(icon, size: 20, color: color),
            title: Text(
              ChatLabels.tool(record.call.name),
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
                child: Text(
                  '参数',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: colorScheme.surface.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: ToolArgumentsView(call: record.call),
              ),
              if (record.resultPreview != null &&
                  record.resultPreview!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '结果',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
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
                    maxLines: 12,
                    style: const TextStyle(fontSize: 12, height: 1.4),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '工具标识：${record.call.name}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  (IconData, Color, String) _appearance(ColorScheme colorScheme) {
    final icon = ChatLabels.toolIcon(record.call.name);
    switch (record.state) {
      case AiToolCallState.pending:
        return (icon, colorScheme.primary, '等待批准');
      case AiToolCallState.approved:
        return (icon, colorScheme.primary, '已批准');
      case AiToolCallState.denied:
        return (icon, colorScheme.error, '已被拒绝');
      case AiToolCallState.done:
        return (icon, Colors.green, '已执行');
      case AiToolCallState.failed:
        return (
          icon,
          colorScheme.error,
          '执行失败${record.errorCode == null ? '' : '（${record.errorCode}）'}',
        );
    }
  }
}
