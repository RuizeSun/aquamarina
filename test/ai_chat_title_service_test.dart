import 'package:aquamarina/models/ai_profile.dart';
import 'package:aquamarina/services/ai/ai_chat_service.dart';
import 'package:aquamarina/services/ai/ai_chat_title_service.dart';
import 'package:aquamarina/services/ai/ai_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAiService extends AiService {
  _FakeAiService({this.reply = '', this.error});

  final String reply;
  final Object? error;
  List<Map<String, dynamic>>? messages;

  @override
  Future<String> chatOnce({
    required List<Map<String, dynamic>> messages,
    AiProfile? profile,
    double? temperatureOverride,
    int? maxTokensOverride,
    CancelToken? cancelToken,
  }) async {
    this.messages = messages;
    if (error != null) throw error!;
    return reply;
  }
}

const _profile = AiProfile(
  id: 'p1',
  name: '测试',
  type: AiProfileType.openai,
  apiKey: 'sk-test',
  model: 'gpt-4o-mini',
);

void main() {
  group('sanitize', () {
    test('去掉“标题：”前缀与包裹符号', () {
      expect(
        AiChatTitleService.sanitize('标题：“prevalent 的常见用法”'),
        'prevalent 的常见用法',
      );
    });

    test('只取首行并去掉书名号与结尾标点', () {
      expect(AiChatTitleService.sanitize('《介词用法总结》。\n补充说明'), '介词用法总结');
    });

    test('空白输出返回 null', () {
      expect(AiChatTitleService.sanitize('  \n '), isNull);
      expect(AiChatTitleService.sanitize('“”'), isNull);
    });

    test('超长标题按 titleMaxChars 截断', () {
      final result = AiChatTitleService.sanitize('字' * 30);
      expect(result, isNotNull);
      expect(result!.length, AiChatService.titleMaxChars);
    });
  });

  group('buildPrompt', () {
    test('包含两段素材并各自截断', () {
      final prompt = AiChatTitleService.buildPrompt(
        firstUserText: '字' * 700,
        firstAssistantText: '答' * 1600,
      );
      expect(prompt, contains('【用户第一句】'));
      expect(prompt, contains('【助手回答正文】'));
      final userPart = prompt.split('【用户第一句】').last.split('【助手回答正文】').first;
      final assistantPart = prompt.split('【助手回答正文】').last;
      expect(userPart.trim().length, AiChatTitleService.maxUserChars);
      expect(assistantPart.trim().length, AiChatTitleService.maxAssistantChars);
    });
  });

  group('generate', () {
    test('使用非流式请求并清洗模型输出', () async {
      final ai = _FakeAiService(reply: '「prevalent 的用法。」');
      final service = AiChatTitleService(aiService: ai);
      final title = await service.generate(
        profile: _profile,
        firstUserText: 'prevalent 怎么用',
        firstAssistantText: '它是形容词。',
      );

      expect(title, 'prevalent 的用法');
      expect(ai.messages, hasLength(2));
      expect(ai.messages!.first['role'], 'system');
      expect(ai.messages!.last['content'], contains('prevalent 怎么用'));
    });

    test('请求失败返回 null，不抛出', () async {
      final service = AiChatTitleService(
        aiService: _FakeAiService(error: StateError('boom')),
      );
      final title = await service.generate(
        profile: _profile,
        firstUserText: '你好',
        firstAssistantText: '你好。',
      );
      expect(title, isNull);
    });
  });
}
