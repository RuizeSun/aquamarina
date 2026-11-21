import 'package:aquamarina/models/ai_chat.dart';
import 'package:aquamarina/models/ai_profile.dart';
import 'package:aquamarina/services/ai/ai_chat_controller.dart';
import 'package:aquamarina/services/ai/ai_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// DeepSeek 思考模式 + tools 的 `reasoning_content` 回传规则回归测试。
///
/// 背景：只要请求带 `tools`，历史轮次的 reasoning_content 必须完整回传，
/// 否则 API 直接返回 400（见 DeepSeek thinking_mode 文档）。
void main() {
  const tools = [
    {
      'type': 'function',
      'function': {
        'name': 'noop',
        'description': 'noop',
        'parameters': {'type': 'object', 'properties': <String, dynamic>{}},
      },
    },
  ];

  const deepSeek = AiProfile(
    id: 'd1',
    name: 'DeepSeek',
    type: AiProfileType.deepseek,
    baseUrl: 'https://api.deepseek.com',
    apiKey: 'sk-test',
    model: 'deepseek-flash',
    enableThinking: true,
    reasoningEffort: 'high',
  );

  const openai = AiProfile(
    id: 'o1',
    name: 'OpenAI',
    type: AiProfileType.openai,
    apiKey: 'sk-test',
    model: 'gpt-4o-mini',
  );

  AiChatMessage assistantWithReasoning({String? reasoning}) =>
      AiChatMessage.create(
        sessionId: 's',
        role: AiChatRole.assistant,
        content: '正文',
        reasoning: reasoning,
        toolCalls: [
          AiToolCall.parse(id: 'c1', name: 'noop', rawArguments: '{}'),
        ],
      );

  group('toOpenAiMessage', () {
    test('assistant 消息带出 reasoning_content', () {
      final payload = assistantWithReasoning(
        reasoning: '先想想',
      ).toOpenAiMessage();
      expect(payload['reasoning_content'], '先想想');
      expect((payload['tool_calls'] as List).single['id'], 'c1');
    });

    test('没有思维链时不写入空字段', () {
      final payload = assistantWithReasoning().toOpenAiMessage();
      expect(payload.containsKey('reasoning_content'), isFalse);
    });
  });

  group('buildChatBody', () {
    test('DeepSeek 思考模式 + tools：保留并补全 reasoning_content', () {
      final body = AiService().buildChatBody(
        profile: deepSeek,
        stream: true,
        tools: tools,
        messages: [
          {'role': 'user', 'content': '今天天气'},
          assistantWithReasoning(reasoning: '先查日期').toOpenAiMessage(),
          {'role': 'tool', 'tool_call_id': 'c1', 'content': '2026-04-19'},
          // 历史里缺少思维链的 assistant 消息（旧数据 / 未开思考模式时产生）
          {'role': 'assistant', 'content': '好的'},
        ],
      );
      final messages = body['messages'] as List<dynamic>;
      expect((messages[1] as Map)['reasoning_content'], '先查日期');
      expect(
        (messages[3] as Map)['reasoning_content'],
        '',
        reason: '带 tools 时字段必须存在，否则 400',
      );
      expect(body['tools'], isNotNull);
    });

    test('OpenAI 兼容端点：剔除 reasoning_content', () {
      final body = AiService().buildChatBody(
        profile: openai,
        stream: true,
        tools: tools,
        messages: [assistantWithReasoning(reasoning: '先想想').toOpenAiMessage()],
      );
      final messages = body['messages'] as List<dynamic>;
      expect(
        (messages.single as Map).containsKey('reasoning_content'),
        isFalse,
      );
    });

    test('DeepSeek 未开思考模式：同样剔除', () {
      final body = AiService().buildChatBody(
        profile: deepSeek.copyWith(enableThinking: false),
        stream: true,
        tools: tools,
        messages: [assistantWithReasoning(reasoning: '先想想').toOpenAiMessage()],
      );
      final messages = body['messages'] as List<dynamic>;
      expect(
        (messages.single as Map).containsKey('reasoning_content'),
        isFalse,
      );
    });
  });

  group('dropIncompleteToolGroups', () {
    test('结果齐全时保留整组', () {
      final kept = AiChatController.dropIncompleteToolGroups([
        AiChatMessage.create(
          sessionId: 's',
          role: AiChatRole.assistant,
          content: '',
          toolCalls: [
            AiToolCall.parse(id: 'c1', name: 'noop', rawArguments: '{}'),
          ],
        ),
        AiChatMessage.create(
          sessionId: 's',
          role: AiChatRole.tool,
          content: 'ok',
          toolCallId: 'c1',
        ),
      ]);
      expect(kept, hasLength(2));
    });

    test('多条调用只回了一半时整组丢弃', () {
      final kept = AiChatController.dropIncompleteToolGroups([
        AiChatMessage.create(
          sessionId: 's',
          role: AiChatRole.assistant,
          content: '',
          toolCalls: [
            AiToolCall.parse(id: 'c1', name: 'noop', rawArguments: '{}'),
            AiToolCall.parse(id: 'c2', name: 'noop', rawArguments: '{}'),
          ],
        ),
        AiChatMessage.create(
          sessionId: 's',
          role: AiChatRole.tool,
          content: 'ok',
          toolCallId: 'c1',
        ),
      ]);
      expect(kept, isEmpty);
    });

    test('孤立的 tool 消息被跳过', () {
      final kept = AiChatController.dropIncompleteToolGroups([
        AiChatMessage.create(
          sessionId: 's',
          role: AiChatRole.tool,
          content: 'ok',
          toolCallId: 'c9',
        ),
      ]);
      expect(kept, isEmpty);
    });
  });
}
