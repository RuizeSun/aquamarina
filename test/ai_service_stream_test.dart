import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:aquamarina/models/ai_chat.dart';
import 'package:aquamarina/models/ai_profile.dart';
import 'package:aquamarina/services/ai/ai_service.dart';
import 'package:aquamarina/services/ai/ai_usage_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 返回可自定义 SSE 文本的适配器；按固定块大小切分以模拟跨 chunk 切割。
class _SseAdapter implements HttpClientAdapter {
  _SseAdapter({required this.body});

  final String body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    const chunkSize = 24;
    final bytes = utf8.encode(body);
    final stream = Stream<List<int>>.fromIterable([
      for (var i = 0; i < bytes.length; i += chunkSize)
        bytes.sublist(
          i,
          i + chunkSize > bytes.length ? bytes.length : i + chunkSize,
        ),
    ]).map(Uint8List.fromList);
    // 模拟跨 chunk 切割：每块之间让出事件循环
    final asyncStream = stream.asyncMap(
      (chunk) => Future<Uint8List>.delayed(Duration.zero, () => chunk),
    );
    return ResponseBody(asyncStream, 200);
  }

  @override
  void close({bool force = false}) {}
}

AiProfile _profile() => const AiProfile(
  id: 'p1',
  name: '测试',
  type: AiProfileType.openai,
  apiKey: 'sk-test',
  model: 'gpt-4o-mini',
);

AiService _service(_SseAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'https://example.invalid'));
  dio.httpClientAdapter = adapter;
  return AiService(dio: dio);
}

String _chunk(String content) =>
    'data: ${jsonEncode({
      'choices': [
        {
          'delta': {'content': content},
        },
      ],
    })}\n\n';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('chatStreamEvents SSE 解析', () {
    test('最后一帧无尾随换行时仍会被处理', () async {
      final service = _service(
        _SseAdapter(body: '${_chunk('你好')}data: ${jsonEncode({
          'choices': [
            {
              'delta': {'content': '最后'},
            },
          ],
        })}'),
      );
      final texts = <String>[];
      await for (final event in service.chatStreamEvents(
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
        profile: _profile(),
      )) {
        if (event is ChatTextDelta) texts.add(event.text);
      }
      expect(texts.join(), '你好最后');
    });

    test('尾帧携带的 usage 不会因为缺少换行而丢失', () async {
      final usageJson = jsonEncode({
        'usage': {
          'prompt_tokens': 11,
          'completion_tokens': 7,
          'total_tokens': 18,
        },
      });
      final service = _service(
        _SseAdapter(
          body:
              '${_chunk('答')}'
              'data: ${jsonEncode({
                'choices': [
                  {
                    'delta': {'content': '案'},
                  },
                ],
              })}\n\n'
              'data: $usageJson',
        ),
      );
      AiUsageSnapshot? snapshot;
      await for (final _ in service.chatStreamEvents(
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
        profile: _profile(),
        onUsage: (s) => snapshot = s,
      )) {}
      expect(snapshot, isNotNull);
      expect(snapshot!.totalTokens, 18);
    });

    test('坏字节不会打断整条流（allowMalformed）', () async {
      // 坏字节独占一行（真实代理注入坏数据时也是整行噪声），
      // 后续合法分块仍应正常解析。
      final bytes = utf8.encode(_chunk('前')) +
          [0xC3, 0x28, 0x0A] +
          utf8.encode(_chunk('后'));
      final body = utf8.decode(bytes, allowMalformed: true);
      final service = _service(_SseAdapter(body: body));
      final texts = <String>[];
      await for (final event in service.chatStreamEvents(
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
        profile: _profile(),
      )) {
        if (event is ChatTextDelta) texts.add(event.text);
      }
      expect(texts, containsAll(['前', '后']));
    });

    test('全部解析失败时以 ChatError 暴露格式异常', () async {
      final service = _service(_SseAdapter(body: 'data: not-json\n\n' * 3));
      final errors = <String>[];
      await for (final event in service.chatStreamEvents(
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
        profile: _profile(),
      )) {
        if (event is ChatError) errors.add(event.error.message);
      }
      expect(errors.single, contains('响应格式异常'));
    });

    test('工具调用分片按 index 合并', () async {
      final body =
          'data: ${jsonEncode({
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'call_1',
                      'function': {'name': 'search', 'arguments': '{"a"'},
                    },
                  ],
                },
              },
            ],
          })}\n\n'
          'data: ${jsonEncode({
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'function': {'arguments': ':"b"}'},
                    },
                  ],
                },
              },
            ],
          })}\n\n'
          'data:';
      final service = _service(_SseAdapter(body: body));
      AiToolCall? call;
      await for (final event in service.chatStreamEvents(
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
        profile: _profile(),
      )) {
        if (event is ChatToolCallsCompleted) call = event.calls.single;
      }
      expect(call, isNotNull);
      final parsed = call!;
      expect(parsed.name, 'search');
      expect(parsed.rawArguments, '{"a":"b"}');
    });
  });

  group('chatStream SSE 解析', () {
    test('最后一帧无尾随换行时仍会被处理', () async {
      final service = _service(
        _SseAdapter(body: '${_chunk('一')}data: ${jsonEncode({
          'choices': [
            {
              'delta': {'content': '二'},
            },
          ],
        })}'),
      );
      final texts = await service
          .chatStream(
            messages: const [
              {'role': 'user', 'content': 'hi'},
            ],
            profile: _profile(),
          )
          .toList();
      expect(texts.join(), '一二');
    });
  });
}
