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
