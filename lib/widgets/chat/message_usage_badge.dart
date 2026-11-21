import 'package:flutter/material.dart';

import '../../models/ai_chat.dart';
import '../../services/ai/ai_chat_export.dart';

/// 消息下方的 token / 费用角标。
///
/// - assistant 消息展示该轮请求的**真实用量**（服务端返回的 usage）；
/// - 用户消息没有真实用量，展示按字符估算的输入 token（带 ≈ 前缀）；
/// - 没有可用数据时完全不占位。
class MessageUsageBadge extends StatelessWidget {
  const MessageUsageBadge({super.key, this.usage, this.estimateTokens});

  /// 真实用量；为空时退回估算。
  final AiMessageUsage? usage;

  /// 估算 token 数（仅用于没有真实用量的消息）。
  final int? estimateTokens;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = _label();
    if (label == null) return const SizedBox.shrink();
    final muted = theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.72);
    return Tooltip(
      message: _tooltip(),
      waitDuration: const Duration(milliseconds: 400),
      child: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.token_outlined, size: 12, color: muted),
            const SizedBox(width: 4),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: muted,
                fontSize: 11,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String? _label() {
    final data = usage;
    if (data != null && !data.isEmpty) {
      final parts = <String>[
        '↑${AiChatExport.formatTokenCount(data.promptTokens)}',
        '↓${AiChatExport.formatTokenCount(data.completionTokens)}',
      ];
      final cost = AiChatExport.formatCost(data);
      if (cost.isNotEmpty) parts.add(cost);
      return parts.join(' · ');
    }
    final estimate = estimateTokens;
    if (estimate != null && estimate > 0) {
      return '≈ ${AiChatExport.formatTokenCount(estimate)} tok';
    }
    return null;
  }

  String _tooltip() {
    final data = usage;
    if (data != null && !data.isEmpty) {
      return [
        '输入 ${data.promptTokens} tokens',
        if (data.cacheHitTokens > 0) '其中缓存命中 ${data.cacheHitTokens} tokens',
        '输出 ${data.completionTokens} tokens',
        '合计 ${data.totalTokens} tokens',
        if (data.cost != null) '费用 ${AiChatExport.formatCost(data)}',
      ].join('\n');
    }
    return '按字符估算，仅作参考';
  }
}
