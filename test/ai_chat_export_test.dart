import 'dart:convert';

import 'package:aquamarina/models/ai_chat.dart';
import 'package:aquamarina/services/ai/ai_chat_export.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  AiChatSession session() => AiChatSession.create(title: '天气/查询:测试');

  AiChatMessage user(String text) => AiChatMessage.create(
    sessionId: 's',
    role: AiChatRole.user,
    content: text,
    createdAt: DateTime(2026, 11, 21, 10),
  );

  AiChatMessage assistant({
    String text = '今天多云。',
    String? reasoning,
    List<AiToolCall> calls = const [],
    AiMessageUsage? usage,
  }) => AiChatMessage.create(
    sessionId: 's',
    role: AiChatRole.assistant,
    content: text,
    reasoning: reasoning,
    toolCalls: calls,
    usage: usage,
    createdAt: DateTime(2026, 11, 21, 10, 1),
  );

  const usage = AiMessageUsage(
    promptTokens: 1200,
    cacheHitTokens: 800,
    cacheMissTokens: 400,
    completionTokens: 240,
    totalTokens: 1440,
    cost: 0.0021,
  );

  group('toMarkdown', () {
    test('包含标题、提问、回答、思考与用量', () {
      final md = AiChatExport.toMarkdown(
        session: session(),
        messages: [
          user('明天天气怎么样？'),
          assistant(
            reasoning: '先看日期',
            calls: [AiToolCall.parse(id: 'c1', name: 'get_date', rawArguments: '{}')],
            usage: usage,
          ),
        ],
        now: DateTime(2026, 11, 21, 18, 30),
      );

      expect(md, contains('# 天气/查询:测试'));
      expect(md, contains('## 我'));
      expect(md, contains('明天天气怎么样？'));
      expect(md, contains('## 助手'));
      expect(md, contains('今天多云。'));
      expect(md, contains('先看日期'));
      expect(md, contains('get_date'));
      expect(md, contains('↑1.2k'));
      expect(md, contains('↓240'));
      expect(md, contains('¥0.0021'));
      expect(md, contains('2026-11-21 18:30'));
    });

    test('关闭思维链与用量后不再输出', () {
      final md = AiChatExport.toMarkdown(
        session: session(),
        messages: [assistant(reasoning: '先看日期', usage: usage)],
        includeReasoning: false,
        includeUsage: false,
      );
      expect(md, isNot(contains('先看日期')));
      expect(md, isNot(contains('↑')));
    });

    test('工具结果以引用块导出', () {
      final md = AiChatExport.toMarkdown(
        session: session(),
        messages: [
          assistant(calls: [AiToolCall.parse(id: 'c1', name: 'get_date', rawArguments: '{}')]),
          AiChatMessage.create(
            sessionId: 's',
            role: AiChatRole.tool,
            content: '2026-11-22',
            toolCallId: 'c1',
            toolName: 'get_date',
          ),
        ],
      );
      expect(md, contains('工具结果（get_date）'));
      expect(md, contains('> 2026-11-22'));
    });
  });

  group('toJson', () {
    test('结构完整且含用量', () {
      final json = AiChatExport.toJson(
        session: session(),
        messages: [user('你好'), assistant(usage: usage)],
      );
      final decoded = jsonDecodeForTest(json);
      expect(decoded['schema'], 1);
      expect((decoded['session'] as Map)['title'], '天气/查询:测试');
      final messages = decoded['messages'] as List<dynamic>;
      expect(messages, hasLength(2));
      expect((messages[1] as Map)['usage']['total_tokens'], 1440);
    });
  });

  group('fileNameFor', () {
    test('清洗非法字符并带时间戳', () {
      final name = AiChatExport.fileNameFor(
        AiChatSession.create(title: 'a/b:c*d'),
        extension: 'md',
        now: DateTime(2026, 11, 21, 17, 5),
      );
      expect(name, 'a_b_c_d_20261121_1705.md');
    });

    test('空标题回退为 ai_chat', () {
      final name = AiChatExport.fileNameFor(
        AiChatSession.create(title: '   '),
        extension: 'json',
        now: DateTime(2026, 1, 2, 3, 4),
      );
      expect(name, '新对话_20260102_0304.json');
    });
  });

  group('格式化', () {
    test('token 紧凑写法', () {
      expect(AiChatExport.formatTokenCount(0), '0');
      expect(AiChatExport.formatTokenCount(999), '999');
      expect(AiChatExport.formatTokenCount(1200), '1.2k');
      expect(AiChatExport.formatTokenCount(12000), '12k');
      expect(AiChatExport.formatTokenCount(1500000), '1.5M');
    });

    test('小额费用保留 4 位小数', () {
      expect(
        AiChatExport.formatCost(usage),
        '¥0.0021',
      );
      expect(
        AiChatExport.formatCost(
          const AiMessageUsage(
            promptTokens: 1,
            completionTokens: 1,
            totalTokens: 2,
            cost: 1.234,
          ),
        ),
        '¥1.23',
      );
    });
  });

  group('AiMessageUsage', () {
    test('combine 求和并合并费用', () {
      final merged = AiMessageUsage.combine([
        usage,
        const AiMessageUsage(
          promptTokens: 800,
          completionTokens: 60,
          totalTokens: 860,
          cost: 0.001,
        ),
      ]);
      expect(merged.promptTokens, 2000);
      expect(merged.completionTokens, 300);
      expect(merged.totalTokens, 2300);
      expect(merged.cost, closeTo(0.0031, 1e-9));
    });

    test('任一缺失费用时总额为 null', () {
      final merged = AiMessageUsage.combine([
        usage,
        const AiMessageUsage(
          promptTokens: 10,
          completionTokens: 1,
          totalTokens: 11,
        ),
      ]);
      expect(merged.cost, isNull);
    });

    test('JSON 往返与损坏数据', () {
      final restored = AiMessageUsage.tryDecode(jsonEncodeForTest(usage.toJson()));
      expect(restored?.totalTokens, 1440);
      expect(restored?.cost, closeTo(0.0021, 1e-9));
      expect(AiMessageUsage.tryDecode(null), isNull);
      expect(AiMessageUsage.tryDecode('not json'), isNull);
      expect(AiMessageUsage.tryDecode('{}'), isNull);
    });
  });
}

Map<String, dynamic> jsonDecodeForTest(String raw) =>
    Map<String, dynamic>.from(const JsonDecoder().convert(raw) as Map);

String jsonEncodeForTest(Map<String, dynamic> value) =>
    const JsonEncoder().convert(value);
