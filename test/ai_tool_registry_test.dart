import 'package:aquamarina/models/ai_chat.dart';
import 'package:aquamarina/services/ai/tools/ai_tool.dart';
import 'package:aquamarina/services/ai/tools/ai_tool_registry.dart';
import 'package:flutter_test/flutter_test.dart';

AiToolDescriptor _tool(
  String name, {
  AiToolRisk risk = AiToolRisk.readOnly,
  Future<AiToolResult> Function(Map<String, dynamic>)? execute,
}) {
  return AiToolDescriptor(
    name: name,
    description: '测试工具 $name',
    risk: risk,
    parameters: {
      'type': 'object',
      'properties': {
        'word': {'type': 'string'},
      },
    },
    execute: execute ?? (args) async => AiToolResult.success('ok'),
  );
}

void main() {
  group('openAiTools', () {
    test('输出结构符合 OpenAI tools 协议', () {
      final registry = AiToolRegistry([_tool('search_dictionary')]);
      final tools = registry.openAiTools();
      expect(tools, hasLength(1));
      final entry = tools.single;
      expect(entry['type'], 'function');
      final fn = entry['function'] as Map<String, dynamic>;
      expect(fn['name'], 'search_dictionary');
      expect(fn['description'], isNotEmpty);
      expect(fn['parameters'], isA<Map<String, dynamic>>());
    });

    test('按 enabledNames 过滤', () {
      final registry = AiToolRegistry([_tool('a'), _tool('b')]);
      final tools = registry.openAiTools(enabledNames: {'b'});
      expect(tools, hasLength(1));
      expect((tools.single['function'] as Map)['name'], 'b');
    });
  });

  group('execute 的容错', () {
    test('未知工具返回 unknown_tool 并列出可用工具', () async {
      final registry = AiToolRegistry([_tool('search_dictionary')]);
      final result = await registry.execute(
        AiToolCall.parse(id: '1', name: 'nope', rawArguments: '{}'),
      );
      expect(result.ok, isFalse);
      expect(result.errorCode, 'unknown_tool');
      expect(result.content, contains('search_dictionary'));
    });

    test('参数不是合法 JSON 时返回 invalid_arguments', () async {
      final registry = AiToolRegistry([_tool('search_dictionary')]);
      final result = await registry.execute(
        AiToolCall.parse(
          id: '1',
          name: 'search_dictionary',
          rawArguments: '{not json',
        ),
      );
      expect(result.ok, isFalse);
      expect(result.errorCode, 'invalid_arguments');
    });

    test('executor 抛异常时收敛为 tool_error', () async {
      final registry = AiToolRegistry([
        _tool('boom', execute: (args) async => throw StateError('炸了')),
      ]);
      final result = await registry.execute(
        AiToolCall.parse(id: '1', name: 'boom', rawArguments: '{}'),
      );
      expect(result.ok, isFalse);
      expect(result.errorCode, 'tool_error');
    });

    test('参数校验失败（AiToolArgumentException）归为 invalid_arguments', () async {
      final registry = AiToolRegistry([
        _tool(
          'needs_word',
          execute: (args) async => AiToolResult.success(
            AiToolArgs(args).requireString('word'),
          ),
        ),
      ]);
      final result = await registry.execute(
        AiToolCall.parse(id: '1', name: 'needs_word', rawArguments: '{}'),
      );
      expect(result.errorCode, 'invalid_arguments');
    });
  });

  group('风险分类', () {
    test('写工具 isMutating 为 true', () {
      expect(_tool('w', risk: AiToolRisk.mutating).isMutating, isTrue);
      expect(_tool('r').isMutating, isFalse);
    });
  });
}
