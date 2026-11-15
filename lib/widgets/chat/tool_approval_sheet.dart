import 'dart:convert';

import 'package:flutter/material.dart';

import '../../models/ai_chat.dart';
import '../../services/ai/tools/ai_tool.dart';
import '../../services/ai/tools/tool_approval.dart';
import 'chat_labels.dart';

/// 工具批准面板：写操作执行前必须由用户显式确认。
///
/// 返回 null 表示用户直接关闭面板（按拒绝处理）。
Future<AiToolApprovalDecision?> showToolApprovalSheet(
  BuildContext context, {
  required AiToolCall call,
  required AiToolDescriptor tool,
}) {
  return showModalBottomSheet<AiToolApprovalDecision>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) {
      final theme = Theme.of(sheetContext);
      final colorScheme = theme.colorScheme;
      final argumentsText = call.rawArguments.trim().isEmpty
          ? '（无参数）'
          : _prettyJson(call.rawArguments);

      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: tool.isMutating
                        ? colorScheme.errorContainer
                        : colorScheme.primaryContainer,
                    child: Icon(
                      tool.isMutating
                          ? Icons.edit_note
                          : Icons.visibility_outlined,
                      size: 20,
                      color: tool.isMutating
                          ? colorScheme.onErrorContainer
                          : colorScheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'AI 请求使用「${ChatLabels.tool(call.name)}」',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          call.name,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (tool.isMutating)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.errorContainer.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        size: 18,
                        color: colorScheme.error,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '此操作将修改你的数据',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.error,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              else
                Text(
                  '此工具只读取本地数据，不会修改任何内容。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              const SizedBox(height: 12),
              Text('工具说明', style: theme.textTheme.labelLarge),
              const SizedBox(height: 4),
              Text(tool.description, style: theme.textTheme.bodySmall),
              const SizedBox(height: 12),
              Text('参数', style: theme.textTheme.labelLarge),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 220),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.45,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    argumentsText,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
              if (call.parseError)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '参数不是合法 JSON，执行时将以 invalid_arguments 回灌给模型。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(
                        sheetContext,
                      ).pop(AiToolApprovalDecision.denied),
                      child: const Text('拒绝'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.of(
                        sheetContext,
                      ).pop(AiToolApprovalDecision.approved),
                      child: const Text('仅本次允许'),
                    ),
                  ),
                ],
              ),
              if (tool.isMutating)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: SizedBox(
                    width: double.infinity,
                    child: TextButton(
                      onPressed: () => Navigator.of(
                        sheetContext,
                      ).pop(AiToolApprovalDecision.alwaysAllowedInSession),
                      child: const Text('本会话总是允许（仅本次运行有效）'),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  ).then((value) => value ?? AiToolApprovalDecision.denied);
}

String _prettyJson(String raw) {
  try {
    return const JsonEncoder.withIndent('  ').convert(jsonDecode(raw));
  } catch (_) {
    return raw;
  }
}
