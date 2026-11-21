import 'dart:convert';

/// 轻量的 token 估算工具（不引入 tokenizer 依赖）。
///
/// 用于在真正发起 AI 请求前，给用户一个「大概要花多少 token / 多少钱」的预估。
/// 采用业界常用的经验规则：
///
/// - 中日韩文字与全角标点：约 1 个字符 ≈ 1 个 token（偏保守，宁可高估）；
/// - 其余（英文、数字、半角标点、空白）：约 4 个字符 ≈ 1 个 token。
///
/// 估算值只用于事前提示，实际用量以服务端返回的 `usage` 为准（已由
/// `AiService` 记录到用量统计中）。
class AiTokenEstimator {
  const AiTokenEstimator._();

  /// 单条消息的对话模板额外开销（role / 分隔符等）。
  static const int _perMessageOverhead = 4;

  /// 单张图片的保守估算值（低细节 + 一次缩放的开销量级）。
  static const int imageTokenEstimate = 850;

  /// 一次回复的固定结构开销（`{"sentences":[]}` 等外壳）。
  static const int _replyEnvelopeOverhead = 12;

  /// 估算一段文本的 token 数。
  static int estimate(String text) {
    if (text.isEmpty) return 0;
    var cjk = 0;
    var other = 0;
    for (final rune in text.runes) {
      if (_isWide(rune)) {
        cjk++;
      } else {
        other++;
      }
    }
    // 非宽字符按 4 字符 1 token 向上取整，避免长文本被系统性低估
    return cjk + ((other + 3) ~/ 4);
  }

  /// 估算一轮 chat 请求的 prompt tokens。
  static int estimateMessages(List<Map<String, String>> messages) {
    var total = 0;
    for (final message in messages) {
      total += _perMessageOverhead;
      total += estimate(message['content'] ?? '');
      // role 等字段本身的开销已并入了消息开销
    }
    return total;
  }

  /// 估算一条已经组装好的 OpenAI message（支持多模态 content 与 tool_calls）。
  static int estimateChatMessage(Map<String, dynamic> message) {
    var total = _perMessageOverhead;
    final content = message['content'];
    if (content is String) {
      total += estimate(content);
    } else if (content is List) {
      for (final part in content) {
        if (part is! Map) continue;
        final type = part['type'];
        if (type == 'image_url') {
          total += imageTokenEstimate;
        } else {
          final text = part['text'];
          if (text is String) total += estimate(text);
        }
      }
    }
    final reasoning = message['reasoning_content'];
    if (reasoning is String) {
      total += estimate(reasoning);
    }
    final toolCalls = message['tool_calls'];
    if (toolCalls is List && toolCalls.isNotEmpty) {
      total += estimate(jsonEncode(toolCalls));
    }
    return total;
  }

  /// 估算一组请求消息的 prompt tokens。
  static int estimateChatMessages(List<Map<String, dynamic>> messages) {
    var total = 0;
    for (final message in messages) {
      total += estimateChatMessage(message);
    }
    return total;
  }

  /// 估算工具定义占用的 prompt tokens（空列表为 0）。
  static int estimateTools(List<Map<String, dynamic>> tools) {
    if (tools.isEmpty) return 0;
    // JSON 外壳 + 每个工具的名称/描述/参数结构开销。
    return estimate(jsonEncode(tools)) + tools.length * 8;
  }

  /// 估算一次回复的固定外壳开销（JSON 包裹结构）。
  static int get replyEnvelopeOverhead => _replyEnvelopeOverhead;

  /// 是否为「一字一 token」量级的宽字符（CJK 汉字、假名、全角标点等）。
  static bool _isWide(int rune) {
    return (rune >= 0x1100 && rune <= 0x115F) || // 韩文字母
        (rune >= 0x2E80 && rune <= 0x303E) || // 部首扩展 / CJK 标点
        (rune >= 0x3041 && rune <= 0x33FF) || // 假名 / 注音 / CJK 兼容
        (rune >= 0x3400 && rune <= 0x4DBF) || // CJK 扩展 A
        (rune >= 0x4E00 && rune <= 0x9FFF) || // CJK 基本区
        (rune >= 0xA000 && rune <= 0xA4CF) || // 彝文
        (rune >= 0xAC00 && rune <= 0xD7A3) || // 韩文音节
        (rune >= 0xF900 && rune <= 0xFAFF) || // CJK 兼容表意文字
        (rune >= 0xFE30 && rune <= 0xFE4F) || // CJK 兼容形式
        (rune >= 0xFF00 && rune <= 0xFF60) || // 全角 ASCII
        (rune >= 0xFFE0 && rune <= 0xFFE6); // 全角符号
  }
}
