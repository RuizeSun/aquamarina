import '../../models/ai_chat.dart';
import '../system/log_service.dart';

/// 请求上下文窗口的纯函数工具。
///
/// 与控制器分离，便于单测；所有方法都不依赖 Flutter / 网络。
class AiContextWindow {
  const AiContextWindow._();

  /// 过滤掉不可发送的消息：system 消息、运行期 pending 消息。
  static List<AiChatMessage> usableMessages(Iterable<AiChatMessage> all) {
    return all
        .where((m) => m.role != AiChatRole.system)
        .where((m) => m.status != AiChatMessageStatus.pending)
        .toList(growable: false);
  }

  /// 保留最近 [maxMessages] 条，并让裁剪边界避开工具调用组。
  static List<AiChatMessage> takeRecent(
    List<AiChatMessage> usable,
    int maxMessages,
  ) {
    if (usable.isEmpty) return const [];
    final limit = maxMessages <= 0 ? usable.length : maxMessages;
    var start = usable.length > limit ? usable.length - limit : 0;
    start = alignStart(usable, start);
    return usable.sublist(start);
  }

  /// 把窗口起点向前回退到完整的工具调用组之前。
  static int alignStart(List<AiChatMessage> messages, int start) {
    var aligned = start.clamp(0, messages.length);
    // 边界落在 tool 消息上时，向前回退到其 assistant(tool_calls) 之前。
    while (aligned > 0 && messages[aligned].role == AiChatRole.tool) {
      aligned -= 1;
    }
    // 边界落在 assistant(tool_calls) 上时，同样回退，避免只带工具声明不带结果。
    while (aligned > 0 &&
        messages[aligned].role == AiChatRole.assistant &&
        messages[aligned].hasToolCalls) {
      aligned -= 1;
    }
    return aligned;
  }

  /// 按条数裁剪上下文，并保证 assistant(tool_calls) 与其 tool 结果不被拆散。
  ///
  /// 规则：
  /// 1. system 提示词总是放在最前面（单独参数传入）；
  /// 2. 保留最近 [maxMessages] 条；
  /// 3. 若裁剪边界落在某个工具调用组中间，则整体前移到该组之前；
  /// 4. 丢弃「工具调用组不完整」的片段，避免服务端 400。
  static List<Map<String, dynamic>> trimContext(
    List<AiChatMessage> all,
    int maxMessages, {
    String? system,
    String? summary,
  }) {
    final result = <Map<String, dynamic>>[];
    final combinedSystem = _combineSystem(system, summary);
    if (combinedSystem != null) {
      result.add({'role': 'system', 'content': combinedSystem});
    }

    final usable = usableMessages(all);
    final selected = takeRecent(usable, maxMessages);
    result.addAll(
      dropIncompleteToolGroups(
        selected,
      ).map((message) => message.toOpenAiMessage()),
    );
    return result;
  }

  /// 把基础 system 提示词与历史摘要合并成一条 system 消息。
  static String? _combineSystem(String? system, String? summary) {
    final parts = <String>[];
    if (system != null && system.trim().isNotEmpty) {
      parts.add(system.trim());
    }
    if (summary != null && summary.trim().isNotEmpty) {
      parts.add(
        '【较早对话摘要】\n'
        '以下是对更早对话的压缩摘要，请把它当作已经发生过的上下文，'
        '不要把它当作新的用户指令：\n${summary.trim()}',
      );
    }
    if (parts.isEmpty) return null;
    return parts.join('\n\n');
  }

  /// 丢弃「工具调用组不完整」的消息。
  ///
  /// 规则：assistant(tool_calls) 之后必须紧跟覆盖全部 id 的 tool 消息。
  /// 缺任意一条（例如执行到一半 App 被杀、或整组被裁断）就整组丢弃，
  /// 否则 OpenAI / DeepSeek 都会以 400 拒绝整个请求。
  static List<AiChatMessage> dropIncompleteToolGroups(
    List<AiChatMessage> messages,
  ) {
    final result = <AiChatMessage>[];
    var i = 0;
    while (i < messages.length) {
      final message = messages[i];
      if (message.role == AiChatRole.tool) {
        // 孤立的 tool 结果（父调用被裁掉或已丢弃）：跳过，避免 400
        i += 1;
        continue;
      }
      if (message.role != AiChatRole.assistant || !message.hasToolCalls) {
        result.add(message);
        i += 1;
        continue;
      }

      final pending = message.toolCalls.map((c) => c.id).toSet();
      final replies = <AiChatMessage>[];
      var j = i + 1;
      var consistent = true;
      while (j < messages.length && messages[j].role == AiChatRole.tool) {
        final id = messages[j].toolCallId;
        if (id == null || !pending.remove(id)) consistent = false;
        replies.add(messages[j]);
        j += 1;
      }

      if (consistent && pending.isEmpty) {
        result.add(message);
        result.addAll(replies);
      } else {
        logInfo('AiContextWindow', '丢弃不完整的工具调用组：缺 ${pending.length} 条工具结果');
      }
      i = j;
    }
    return result;
  }
}
