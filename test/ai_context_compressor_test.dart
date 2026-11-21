import 'package:aquamarina/models/ai_chat.dart';
import 'package:aquamarina/models/ai_context.dart';
import 'package:aquamarina/models/ai_profile.dart';
import 'package:aquamarina/services/ai/ai_context_compressor.dart';
import 'package:aquamarina/services/ai/ai_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAiService extends AiService {
  _FakeAiService(this.reply);

  final String reply;
  int calls = 0;
  final List<List<Map<String, dynamic>>> requests = [];

  @override
  Future<String> chatOnce({
    required List<Map<String, dynamic>> messages,
    AiProfile? profile,
    double? temperatureOverride,
    int? maxTokensOverride,
    CancelToken? cancelToken,
  }) async {
    calls += 1;
    requests.add(messages);
    return reply;
  }
}

AiProfile _profile({int contextWindow = 0}) => AiProfile(
  id: 'p1',
  name: '测试配置',
  type: AiProfileType.openai,
  apiKey: 'sk-test',
  model: 'gpt-4o-mini',
  contextWindow: contextWindow,
);

String _longText(int chars) => List.filled(chars, '字').join();

AiChatMessage _msg(AiChatRole role, String content) =>
    AiChatMessage.create(sessionId: 's', role: role, content: content);

void main() {
  const compressor = AiContextCompressor();

  test('未启用压缩时全量发送历史', () async {
    final ai = _FakeAiService('不该被调用');
    final messages = [
      for (var i = 0; i < 30; i++)
        _msg(i.isEven ? AiChatRole.user : AiChatRole.assistant, '消息 $i'),
    ];
    final preparation = await compressor.prepare(
      aiService: ai,
      messages: messages,
      systemPrompt: 'SYS',
      tools: const [],
      profile: _profile(),
      policy: AiContextPolicy.defaults.copyWith(compressionEnabled: false),
    );

    expect(ai.calls, 0);
    expect(preparation.compressed, isFalse);
    expect(preparation.summary, isNull);
    // system + 全量 30 条
    expect(preparation.messages, hasLength(31));
    expect(preparation.messages.first['role'], 'system');
    expect(preparation.messages[1]['content'], '消息 0');
    // 未填写上下文窗口时不估算历史用量
    expect(preparation.rawEstimatedTokens, 0);
  });

  test('配置窗口后给出全量历史估算', () async {
    final ai = _FakeAiService('不该被调用');
    final messages = [
      for (var i = 0; i < 100; i++)
        _msg(i.isEven ? AiChatRole.user : AiChatRole.assistant, _longText(100)),
    ];
    final preparation = await compressor.prepare(
      aiService: ai,
      messages: messages,
      systemPrompt: 'SYS',
      tools: const [],
      profile: _profile(contextWindow: 1000000),
      policy: AiContextPolicy.defaults,
    );

    expect(ai.calls, 0);
    expect(preparation.rawEstimatedTokens, greaterThan(10000));
    expect(preparation.messages, hasLength(101));
  });

  test('达到绝对 token 阈值时生成摘要并替换较早消息', () async {
    final ai = _FakeAiService('用户在做英语学习，当前目标是复习第 3 单元。');
    final messages = [
      for (var i = 0; i < 10; i++)
        _msg(i.isEven ? AiChatRole.user : AiChatRole.assistant, _longText(100)),
    ];
    const policy = AiContextPolicy(
      compressionEnabled: true,
      thresholdMode: AiContextThresholdMode.absolute,
      absoluteThreshold: 800,
    );

    final preparation = await compressor.prepare(
      aiService: ai,
      messages: messages,
      systemPrompt: 'SYS',
      tools: const [],
      profile: _profile(),
      policy: policy,
    );

    expect(ai.calls, 1);
    expect(preparation.compressed, isTrue);
    expect(preparation.thresholdTokens, 800);
    expect(preparation.hardLimitTokens, 800);
    expect(preparation.summary, contains('第 3 单元'));
    expect(preparation.summaryCovered, greaterThan(0));
    expect(preparation.estimatedTokens, lessThanOrEqualTo(800));
    expect(preparation.messages.first['content'], contains('较早对话摘要'));
    // 较早的 6 条被摘要替换，只保留最近 4 条（system + 4 条消息）
    expect(preparation.messages, hasLength(5));
  });

  test('按上下文窗口比例触发压缩', () async {
    final ai = _FakeAiService('摘要');
    final messages = [
      for (var i = 0; i < 30; i++)
        _msg(i.isEven ? AiChatRole.user : AiChatRole.assistant, _longText(300)),
    ];
    const policy = AiContextPolicy(
      compressionEnabled: true,
      thresholdMode: AiContextThresholdMode.ratio,
      ratioThreshold: 0.5,
    );

    final preparation = await compressor.prepare(
      aiService: ai,
      messages: messages,
      systemPrompt: 'SYS',
      tools: const [],
      profile: _profile(contextWindow: 10000),
      policy: policy,
    );

    expect(preparation.thresholdTokens, 5000);
    expect(preparation.hardLimitTokens, 10000);
    expect(preparation.compressed, isTrue);
    expect(preparation.estimatedTokens, lessThanOrEqualTo(5000));
    expect(preparation.rawEstimatedTokens, greaterThan(5000));
    expect(ai.calls, 1);
  });

  test('比例模式但未填写上下文窗口时给出明确错误', () async {
    final ai = _FakeAiService('摘要');
    const policy = AiContextPolicy(
      compressionEnabled: true,
      thresholdMode: AiContextThresholdMode.ratio,
      ratioThreshold: 0.5,
    );

    await expectLater(
      compressor.prepare(
        aiService: ai,
        messages: [_msg(AiChatRole.user, '你好')],
        systemPrompt: 'SYS',
        tools: const [],
        profile: _profile(),
        policy: policy,
      ),
      throwsA(
        isA<AiContextOverflowException>().having(
          (e) => e.message,
          'message',
          contains('上下文窗口'),
        ),
      ),
    );
  });

  test('压缩后仍然超限时抛出溢出错误', () async {
    final ai = _FakeAiService('摘要');
    final messages = [_msg(AiChatRole.user, _longText(600))];
    const policy = AiContextPolicy(
      compressionEnabled: true,
      thresholdMode: AiContextThresholdMode.absolute,
      absoluteThreshold: 500,
    );

    await expectLater(
      compressor.prepare(
        aiService: ai,
        messages: messages,
        systemPrompt: 'SYS',
        tools: const [],
        profile: _profile(contextWindow: 500),
        policy: policy,
      ),
      throwsA(
        isA<AiContextOverflowException>().having(
          (e) => e.message,
          'message',
          contains('超出模型上下文窗口'),
        ),
      ),
    );
    expect(ai.calls, 0);
  });

  test('复用已有摘要时只请求压缩新增的旧消息', () async {
    final ai = _FakeAiService('第二轮摘要');
    final messages = [
      for (var i = 0; i < 10; i++)
        _msg(i.isEven ? AiChatRole.user : AiChatRole.assistant, _longText(100)),
    ];
    const policy = AiContextPolicy(
      compressionEnabled: true,
      thresholdMode: AiContextThresholdMode.absolute,
      absoluteThreshold: 500,
    );

    final preparation = await compressor.prepare(
      aiService: ai,
      messages: messages,
      systemPrompt: 'SYS',
      tools: const [],
      profile: _profile(),
      policy: policy,
      summary: '第一轮摘要',
      summaryCovered: 4,
    );

    expect(ai.calls, 1);
    expect(ai.requests.single.last['content'], contains('第一轮摘要'));
    expect(preparation.summary, '第二轮摘要');
    expect(preparation.summaryCovered, greaterThan(4));
  });
}
