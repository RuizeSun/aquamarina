import 'dart:convert';

import '../../models/ai_chat.dart';

/// 对话导出：把会话与消息转成 Markdown / JSON 文本。
///
/// 这里只做纯文本生成，不含任何 IO：保存路径与分享面板由页面负责，
/// 便于单元测试直接断言输出内容。
class AiChatExport {
  AiChatExport._();

  static const String markdownExtension = 'md';
  static const String jsonExtension = 'json';

  /// 文件名里需要替换掉的非法字符。
  static const String _illegalFileNameChars = r'\/:*?"<>|';

  /// 生成 Markdown 全文。
  ///
  /// [includeReasoning] 关闭时不导出思维链（分享给别人时更干净）；
  /// [includeUsage] 打开时在每条回答末尾附上 token / 费用。
  static String toMarkdown({
    required AiChatSession session,
    required List<AiChatMessage> messages,
    bool includeReasoning = true,
    bool includeUsage = true,
    DateTime? now,
  }) {
    final visible = messages
        .where((m) => m.role != AiChatRole.system)
        .toList(growable: false);
    final sb = StringBuffer();

    sb.writeln('# ${session.title}');
    sb.writeln();
    sb.writeln('- 导出时间：${formatDateTime(now ?? DateTime.now())}');
    sb.writeln('- 创建时间：${formatDateTime(session.createdAt)}');
    sb.writeln('- 消息数：${visible.length}');
    final totals = _totals(visible);
    if (includeUsage && totals != null) {
      sb.writeln('- 累计用量：${formatTokenCount(totals.totalTokens)} tokens');
    }
    sb.writeln();

    for (final message in visible) {
      switch (message.role) {
        case AiChatRole.user:
          sb.writeln('## 我');
          sb.writeln();
          if (message.hasAttachments) {
            sb.writeln(
              '> 附 ${message.attachments.length} 张图片（仅本机保留原图）',
            );
            sb.writeln();
          }
          if (message.content.trim().isNotEmpty) {
            sb.writeln(message.content.trim());
            sb.writeln();
          }
        case AiChatRole.assistant:
          sb.writeln('## 助手');
          sb.writeln();
          final reasoning = message.reasoning?.trim() ?? '';
          if (includeReasoning && reasoning.isNotEmpty) {
            sb.writeln('<details>');
            sb.writeln('<summary>思考过程</summary>');
            sb.writeln();
            sb.writeln(_quote(reasoning));
            sb.writeln();
            sb.writeln('</details>');
            sb.writeln();
          }
          if (message.content.trim().isNotEmpty) {
            sb.writeln(message.content.trim());
            sb.writeln();
          }
          if (message.hasToolCalls) {
            for (final call in message.toolCalls) {
              sb.writeln(
                '- 工具调用：${call.name} ${_oneLine(call.rawArguments)}',
              );
            }
            sb.writeln();
          }
          if (includeUsage && message.usage != null) {
            final usage = message.usage!;
            final parts = <String>[
              '↑${formatTokenCount(usage.promptTokens)}',
              '↓${formatTokenCount(usage.completionTokens)}',
              if (usage.cost != null) formatCost(usage),
            ];
            sb.writeln('> ${parts.join(' · ')}');
            sb.writeln();
          }
        case AiChatRole.tool:
          final label = message.toolName == null || message.toolName!.isEmpty
              ? '工具结果'
              : '工具结果（${message.toolName!}）';
          final failed = message.status == AiChatMessageStatus.error;
          sb.writeln('> **$label${failed ? ' · 失败' : ''}**');
          sb.writeln('>');
          sb.writeln(_quote(message.content.trim()));
          sb.writeln();
        case AiChatRole.system:
          break;
      }
      sb.writeln('---');
      sb.writeln();
    }

    return sb.toString().trimRight();
  }

  /// 生成 JSON 备份文本（结构比 Markdown 更完整，便于二次处理）。
  static String toJson({
    required AiChatSession session,
    required List<AiChatMessage> messages,
    DateTime? now,
  }) {
    final payload = <String, dynamic>{
      'schema': 1,
      'exported_at': (now ?? DateTime.now()).toIso8601String(),
      'session': {
        'id': session.id,
        'title': session.title,
        'profile_id': session.profileId,
        'created_at': session.createdAt.toIso8601String(),
        'updated_at': session.updatedAt.toIso8601String(),
      },
      'messages': [
        for (final message in messages)
          if (message.role != AiChatRole.system) _messageToJson(message),
      ],
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  static Map<String, dynamic> _messageToJson(AiChatMessage message) => {
    'id': message.id,
    'role': message.role.name,
    'content': message.content,
    if (message.reasoning != null) 'reasoning': message.reasoning,
    if (message.hasToolCalls)
      'tool_calls': [for (final call in message.toolCalls) call.toJson()],
    if (message.toolCallId != null) 'tool_call_id': message.toolCallId,
    if (message.toolName != null) 'tool_name': message.toolName,
    'status': message.status.name,
    if (message.errorMessage != null) 'error_message': message.errorMessage,
    if (message.hasAttachments)
      'attachments': [
        for (final attachment in message.attachments) attachment.toJson(),
      ],
    if (message.usage != null) 'usage': message.usage!.toJson(),
    'created_at': message.createdAt.toIso8601String(),
  };

  /// 导出文件名（已清洗非法字符），例如 天气查询_20261121_1750.md。
  static String fileNameFor(
    AiChatSession session, {
    required String extension,
    DateTime? now,
  }) {
    final time = now ?? DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final buffer = StringBuffer();
    for (final char in session.title.trim().split('')) {
      buffer.write(_illegalFileNameChars.contains(char) ? '_' : char);
    }
    final title = buffer.toString().trim();
    final stamp =
        '${time.year}${two(time.month)}${two(time.day)}'
        '_${two(time.hour)}${two(time.minute)}';
    return '${title.isEmpty ? 'ai_chat' : title}_$stamp.$extension';
  }

  // ── 格式化 ────────────────────────────────────────

  /// 把 token 数压缩成 1.2k / 1.5M 这类紧凑写法。
  static String formatTokenCount(int tokens) {
    if (tokens < 1000) return '$tokens';
    if (tokens < 1000000) {
      final value = tokens / 1000;
      return '${_trimZero(value.toStringAsFixed(value < 10 ? 1 : 0))}k';
    }
    final value = tokens / 1000000;
    return '${_trimZero(value.toStringAsFixed(value < 10 ? 2 : 1))}M';
  }

  /// 费用格式化：小额自动加精度，避免 ¥0.00 这种看不出差别的显示。
  static String formatCost(AiMessageUsage usage) {
    final cost = usage.cost;
    if (cost == null) return '';
    final decimals = cost > 0 && cost < 0.01
        ? (usage.currencyDecimals < 4 ? 4 : usage.currencyDecimals)
        : usage.currencyDecimals;
    return '${usage.currencySymbol}${cost.toStringAsFixed(decimals.clamp(0, 6))}';
  }

  static String formatDateTime(DateTime time) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }

  static AiMessageUsage? _totals(List<AiChatMessage> messages) {
    final usages = <AiMessageUsage>[
      for (final message in messages)
        if (message.usage != null) message.usage!,
    ];
    return usages.isEmpty ? null : AiMessageUsage.combine(usages);
  }

  static String _quote(String text) => text
      .split('\n')
      .map((line) => line.isEmpty ? '>' : '> $line')
      .join('\n');

  static String _oneLine(String text) =>
      text.split(' ').where((part) => part.isNotEmpty).join(' ').trim();

  static String _trimZero(String value) {
    if (!value.contains('.')) return value;
    var end = value.length;
    while (end > 0 && value[end - 1] == '0') {
      end -= 1;
    }
    if (end > 0 && value[end - 1] == '.') end -= 1;
    return value.substring(0, end);
  }
}
