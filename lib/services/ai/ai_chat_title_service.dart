import '../../models/ai_profile.dart';
import '../system/log_service.dart';
import 'ai_chat_service.dart';
import 'ai_service.dart';

/// 用「用户第一句 + 助手首条回答正文」生成会话标题。
///
/// 标题只用于会话列表展示，生成失败时保留本地截断标题，不向 UI 报错。
class AiChatTitleService {
  AiChatTitleService({AiService? aiService})
    : _aiService = aiService ?? AiService();

  final AiService _aiService;

  /// 送给模型的两段素材上限，避免为一句标题重复消耗整篇回复。
  static const int maxUserChars = 600;
  static const int maxAssistantChars = 1500;

  static const String systemPrompt =
      '你是对话标题生成器。请根据用户的第一句话和助手回答的正文，'
      '概括这次对话的主题，生成一个 8-16 字的中文短标题。'
      '要求：名词短语，具体、可检索；不加引号、书名号或结尾标点；'
      '不要出现“对话”“关于”“咨询”等空泛词；只输出标题本身。';

  /// 组装标题生成请求的用户消息。
  static String buildPrompt({
    required String firstUserText,
    required String firstAssistantText,
  }) {
    final user = _clip(_normalize(firstUserText), maxUserChars);
    final assistant = _clip(_normalize(firstAssistantText), maxAssistantChars);
    return '【用户第一句】\n$user\n\n【助手回答正文】\n$assistant';
  }

  /// 清洗模型输出：取首行、去掉“标题：”前缀与包裹符号、去掉结尾标点。
  ///
  /// 返回 null 表示没有可用标题。
  static String? sanitize(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return null;

    // 先取首行，再把行内空白折叠成单个空格。
    text = text.split(RegExp(r'\r?\n')).first.trim();
    text = text.replaceAll(RegExp(r'\s+'), ' ');
    text = text.replaceFirst(
      RegExp(r'^(标题|题目|title)\s*[:：]\s*', caseSensitive: false),
      '',
    );
    text = text.trim();

    const leading = '"\'“”‘’「」『』《》【】〈〉<>()（）[] \t';
    const trailing = '"\'“”‘’「」『』《》【】〈〉<>()（）[]。．.！!？?：:；;，,、~～-—… \t';
    while (text.isNotEmpty && leading.contains(text[0])) {
      text = text.substring(1).trimLeft();
    }
    while (text.isNotEmpty && trailing.contains(text[text.length - 1])) {
      text = text.substring(0, text.length - 1).trimRight();
    }

    if (text.isEmpty) return null;
    if (text.length > AiChatService.titleMaxChars) {
      text = text.substring(0, AiChatService.titleMaxChars);
    }
    return text;
  }

  /// 请求模型生成标题；异常或空结果返回 null。
  Future<String?> generate({
    required AiProfile profile,
    required String firstUserText,
    required String firstAssistantText,
  }) async {
    if (firstUserText.trim().isEmpty && firstAssistantText.trim().isEmpty) {
      return null;
    }
    try {
      final reply = await _aiService.chatOnce(
        messages: [
          {'role': 'system', 'content': systemPrompt},
          {
            'role': 'user',
            'content': buildPrompt(
              firstUserText: firstUserText,
              firstAssistantText: firstAssistantText,
            ),
          },
        ],
        profile: profile,
        temperatureOverride: 0.3,
        maxTokensOverride: 64,
      );
      return sanitize(reply);
    } catch (e) {
      logWarning('AiChatTitleService', '生成会话标题失败: $e');
      return null;
    }
  }

  static String _normalize(String text) =>
      text.trim().replaceAll(RegExp(r'\s+'), ' ');

  static String _clip(String text, int maxChars) {
    if (text.length <= maxChars) return text;
    return text.substring(0, maxChars);
  }
}
