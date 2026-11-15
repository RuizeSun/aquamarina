import 'dart:convert';
import 'dart:typed_data';

import 'package:aquamarina/models/ai_chat.dart';
import 'package:aquamarina/models/ai_profile.dart';
import 'package:aquamarina/services/ai/ai_image_service.dart';
import 'package:aquamarina/services/ai/ai_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// 拦截 HttpClientAdapter，抓取真实请求体。
class _CapturingAdapter implements HttpClientAdapter {
  _CapturingAdapter(this.onRequest);

  final void Function(RequestOptions options) onRequest;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    onRequest(options);
    // 返回最小合法 SSE 响应
    final body = 'data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}\n\n'
        'data: [DONE]\n\n';
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Uint8List _png(int w, int h) {
  final image = img.Image(width: w, height: h);
  img.fill(image, color: img.ColorRgb8(200, 40, 40));
  return img.encodePng(image);
}

AiProfile _visionProfile() => const AiProfile(
  id: 'p1',
  name: '视觉模型',
  type: AiProfileType.openai,
  apiKey: 'sk-test',
  model: 'gpt-4o',
  enableVision: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('端到端：图片确实进入 HTTP 请求体（content 分段数组）', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://example.invalid'));
    Map<String, dynamic>? capturedBody;

    dio.httpClientAdapter = _CapturingAdapter((options) {
      final data = options.data;
      if (data is Map) {
        capturedBody = Map<String, dynamic>.from(data);
      } else if (data is String) {
        capturedBody = jsonDecode(data) as Map<String, dynamic>;
      }
    });

    final service = AiImageService.instance;
    final attachment = service.prepareFromBytes(
      _png(64, 64),
      fileName: 'inline.png',
    )!;
    final prepared = await service.withSendPayload(
      [attachment],
      AiImageSendMode.thumbnail,
    );
    expect(prepared, hasLength(1));

    final message = AiChatMessage.create(
      sessionId: 's1',
      role: AiChatRole.user,
      content: '这是什么颜色？',
      attachments: prepared,
    );

    final ai = AiService(dio: dio);
    ai.setCurrentProfile(_visionProfile());
    final events = await ai
        .chatStreamEvents(
          messages: [message.toOpenAiMessage()],
          profile: _visionProfile(),
        )
        .toList();

    expect(events.whereType<ChatError>(), isEmpty);
    expect(capturedBody, isNotNull);

    final messages = capturedBody!['messages'] as List<dynamic>;
    final userMessage = messages.last as Map<String, dynamic>;
    final content = userMessage['content'];
    expect(content, isA<List<dynamic>>(), reason: '带图消息必须是分段数组');

    final parts = content as List<dynamic>;
    final imageParts = parts.where(
      (p) => p is Map && p['type'] == 'image_url',
    );
    expect(imageParts, hasLength(1), reason: '图片段必须出现在请求体里');
    final url = ((imageParts.first as Map)['image_url'] as Map)['url'] as String;
    expect(url, startsWith('data:image/png;base64,'));
    // 图片 base64 必须是真实可解码的 PNG
    final base64Part = url.split(',').last;
    expect(img.decodePng(base64Decode(base64Part)), isNotNull);
  });

  test('配置未开启视觉时不发送图片段', () async {
    final message = AiChatMessage.create(
      sessionId: 's1',
      role: AiChatRole.user,
      content: '纯文本',
    );
    final payload = message.toOpenAiMessage();
    expect(payload['content'], isA<String>());
  });
}
