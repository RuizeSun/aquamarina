import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aquamarina/models/ai_chat.dart';
import 'package:aquamarina/services/ai/ai_chat_settings.dart';
import 'package:aquamarina/services/ai/ai_image_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// 生成一张纯色 PNG 测试图。
Uint8List _png(int width, int height) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(120, 30, 200));
  return img.encodePng(image);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AiChatAttachment 序列化', () {
    test('toJson / fromJson 往返保真', () {
      final attachment = AiChatAttachment(
        id: 'a1',
        localPath: '/tmp/x.png',
        fileName: 'x.png',
        width: 800,
        height: 600,
        thumbnailBase64: 'AAAA',
        thumbnailSize: AiChatAttachment.thumbSizeSmall,
      );
      final restored = AiChatAttachment.fromJson(
        jsonDecode(jsonEncode(attachment.toJson())) as Map<String, dynamic>,
      );
      expect(restored.id, 'a1');
      expect(restored.localPath, '/tmp/x.png');
      expect(restored.fileName, 'x.png');
      expect(restored.width, 800);
      expect(restored.height, 600);
      expect(restored.thumbnailBase64, 'AAAA');
      expect(restored.thumbnailSize, AiChatAttachment.thumbSizeSmall);
    });

    test('未知缩略图尺寸回退到 32', () {
      final restored = AiChatAttachment.fromJson({
        'id': 'a1',
        'file_name': 'x.png',
        'thumbnail_size': 99,
      });
      expect(restored.thumbnailSize, AiChatAttachment.thumbSizeLarge);
    });
  });

  group('消息携带附件', () {
    test('toRow / fromRow 保留附件', () {
      final attachment = AiChatAttachment(
        id: 'a1',
        localPath: '/tmp/x.png',
        fileName: 'x.png',
        width: 8,
        height: 8,
        thumbnailBase64: 'AAAA',
        thumbnailSize: AiChatAttachment.thumbSizeLarge,
      );
      final message = AiChatMessage.create(
        sessionId: 's1',
        role: AiChatRole.user,
        content: '看图',
        attachments: [attachment],
      );
      final restored = AiChatMessage.fromRow(message.toRow());
      expect(restored.hasAttachments, isTrue);
      expect(restored.attachments.single.fileName, 'x.png');
    });

    test('带图 user 消息在 OpenAI 协议里是 content 数组', () {
      final attachment = AiChatAttachment(
        id: 'a1',
        localPath: null,
        fileName: 'x.png',
        width: 8,
        height: 8,
        thumbnailBase64: 'AAAA',
        thumbnailSize: AiChatAttachment.thumbSizeLarge,
        dataUrl: 'data:image/png;base64,AAAA',
        detail: 'low',
      );
      final message = AiChatMessage.create(
        sessionId: 's1',
        role: AiChatRole.user,
        content: '这是什么',
        attachments: [attachment],
      );
      final payload = message.toOpenAiMessage();
      expect(payload['role'], 'user');
      final parts = payload['content'] as List<dynamic>;
      expect(parts, hasLength(2));
      expect((parts[0] as Map)['type'], 'text');
      expect((parts[0] as Map)['text'], '这是什么');
      expect((parts[1] as Map)['type'], 'image_url');
      final imageUrl = (parts[1] as Map)['image_url'] as Map;
      expect(imageUrl['url'], startsWith('data:image/png;base64,'));
      expect(imageUrl['detail'], 'low');
    });

    test('没有 dataUrl 的附件不会进入请求体', () {
      final attachment = AiChatAttachment(
        id: 'a1',
        localPath: null,
        fileName: 'x.png',
        width: 8,
        height: 8,
        thumbnailBase64: 'AAAA',
        thumbnailSize: AiChatAttachment.thumbSizeLarge,
      );
      final message = AiChatMessage.create(
        sessionId: 's1',
        role: AiChatRole.user,
        content: '纯文本',
        attachments: [attachment],
      );
      final parts = message.toOpenAiMessage()['content'] as List<dynamic>;
      expect(parts, hasLength(1));
      expect((parts.single as Map)['type'], 'text');
    });

    test('无附件的 user 消息仍然是字符串 content', () {
      final message = AiChatMessage.create(
        sessionId: 's1',
        role: AiChatRole.user,
        content: '你好',
      );
      expect(message.toOpenAiMessage()['content'], '你好');
    });
  });

  group('AiImageService 缩略图', () {
    test('按 16 / 32 生成缩略图并可解码', () {
      final service = AiImageService.instance;
      final bytes = _png(200, 120);

      final small = service.prepareFromBytes(
        bytes,
        fileName: 'a.png',
        thumbnailSize: AiChatAttachment.thumbSizeSmall,
      );
      expect(small, isNotNull);
      expect(small!.width, 200);
      expect(small.height, 120);
      expect(small.thumbnailSize, AiChatAttachment.thumbSizeSmall);

      final decodedSmall = img.decodePng(base64Decode(small.thumbnailBase64));
      expect(decodedSmall, isNotNull);
      expect(decodedSmall!.width, AiChatAttachment.thumbSizeSmall);
      expect(decodedSmall.height, AiChatAttachment.thumbSizeSmall);

      final large = service.prepareFromBytes(
        bytes,
        fileName: 'a.png',
        thumbnailSize: AiChatAttachment.thumbSizeLarge,
      );
      final decodedLarge = img.decodePng(base64Decode(large!.thumbnailBase64));
      expect(decodedLarge!.width, AiChatAttachment.thumbSizeLarge);
    });

    test('无法解码的字节返回 null', () {
      final result = AiImageService.instance.prepareFromBytes(
        Uint8List.fromList([1, 2, 3, 4]),
        fileName: 'broken.png',
      );
      expect(result, isNull);
    });

    test('缩略图形态可直接构造 data URL（无需本机原图）', () async {
      final service = AiImageService.instance;
      final attachment = service.prepareFromBytes(
        _png(64, 64),
        fileName: 'a.png',
        thumbnailSize: AiChatAttachment.thumbSizeLarge,
      )!;
      final url = await service.buildDataUrl(
        attachment,
        AiImageSendMode.thumbnail,
      );
      expect(url, startsWith('data:image/png;base64,'));
    });

    test('回归：降级必须如实上报，不能假装是原图', () async {
      final service = AiImageService.instance;
      final attachment = AiChatAttachment(
        id: 'a1',
        localPath: '/nonexistent/gone.png',
        fileName: 'gone.png',
        width: 2344,
        height: 1343,
        thumbnailBase64:
            'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAJ0lEQVR42u3BAQ0AAADCoPdPbQ43oAAAAAAAAAAAAAAAAAAAAHgNlAABJc1W0wAAAABJRU5ErkJggg==',
        thumbnailSize: AiChatAttachment.thumbSizeLarge,
      );

      // 用户要的是原图 → 必须报告降级，且尺寸如实记为 32x32
      final payload = await service.prepareForSend(
        [attachment],
        AiImageSendMode.original,
      );
      expect(payload.hasDegradation, isTrue);
      expect(payload.degradedFileNames, ['gone.png']);
      expect(payload.missingLocalFileCount, 1);
      expect(payload.attachments, hasLength(1));
      expect(payload.attachments.single.sentWidth, 32);
      expect(payload.attachments.single.sentHeight, 32);
      expect(payload.attachments.single.detail, 'low');
    });

    test('回归：正常原图不会被误报降级且尺寸正确', () async {
      final service = AiImageService.instance;
      final payload = await service.prepareForSend(
        [
          AiChatAttachment(
            id: 'a2',
            localPath: null,
            fileName: 'nope.png',
            width: 100,
            height: 50,
            thumbnailBase64:
                'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAJ0lEQVR42u3BAQ0AAADCoPdPbQ43oAAAAAAAAAAAAAAAAAAAAHgNlAABJc1W0wAAAABJRU5ErkJggg==',
            thumbnailSize: AiChatAttachment.thumbSizeLarge,
          ),
        ],
        AiImageSendMode.thumbnail,
      );
      // 主动选缩略图不算降级
      expect(payload.hasDegradation, isFalse);
      expect(payload.attachments.single.sentWidth, 32);
    });

    test('回归：无本机原图时压缩/原图形态降级为缩略图，而不是丢图', () async {
      final service = AiImageService.instance;
      final attachment = AiChatAttachment(
        id: 'a1',
        localPath: '/nonexistent/gone.png',
        fileName: 'gone.png',
        width: 8,
        height: 8,
        thumbnailBase64:
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8AAAwAB/AL+2QAAAABJRU5ErkJggg==',
        thumbnailSize: AiChatAttachment.thumbSizeLarge,
      );

      for (final mode in [AiImageSendMode.compressed, AiImageSendMode.original]) {
        final sent = await service.withSendPayload([attachment], mode);
        expect(sent, hasLength(1), reason: '模式 $mode 不应丢图');
        expect(sent.single.dataUrl, startsWith('data:image/png;base64,'));
        expect(sent.single.detail, 'low', reason: '降级后按缩略图发送');
      }
    });

    test('原图缺失时原图/压缩形态返回 null', () async {
      final service = AiImageService.instance;
      final attachment = AiChatAttachment(
        id: 'a1',
        localPath: '/nonexistent/path.png',
        fileName: 'a.png',
        width: 8,
        height: 8,
        thumbnailBase64: 'AAAA',
        thumbnailSize: AiChatAttachment.thumbSizeLarge,
      );
      expect(await service.buildDataUrl(attachment, AiImageSendMode.original), isNull);
      expect(await service.buildDataUrl(attachment, AiImageSendMode.compressed), isNull);
    });
  });

  group('回归：剪贴板图片必须落盘', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('aq_chat_img_');
      AiImageService.attachmentDirOverride = () async =>
          Directory(p.join(tempDir.path, 'ai_chat_images'));
    });

    tearDown(() async {
      AiImageService.resetAttachmentDirOverride();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('prepareFromBytesPersisted 会写入本地文件', () async {
      final service = AiImageService.instance;
      final attachment = await service.prepareFromBytesPersisted(
        _png(40, 40),
        fileName: 'clipboard.png',
      );
      expect(attachment, isNotNull);
      expect(attachment!.localPath, isNotNull);
      final file = File(attachment.localPath!);
      expect(await file.exists(), isTrue);

      final sent = await service.withSendPayload(
        [attachment],
        AiImageSendMode.compressed,
      );
      expect(sent, hasLength(1));
      expect(sent.single.dataUrl, startsWith('data:image/jpeg;base64,'));

      await service.deleteLocalFiles([attachment]);
      expect(await file.exists(), isFalse);
    });
  });

  group('多模态设置', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    test('默认发送形态为压缩，缩略图默认 32', () async {
      final settings = AiChatSettings();
      expect(await settings.getImageSendMode(), AiImageSendMode.compressed);
      expect(await settings.getImageThumbnailSize(), AiChatAttachment.thumbSizeLarge);
    });

    test('可切换发送形态与缩略图尺寸', () async {
      final settings = AiChatSettings();
      await settings.setImageSendMode(AiImageSendMode.thumbnail);
      expect(await settings.getImageSendMode(), AiImageSendMode.thumbnail);

      await settings.setImageThumbnailSize(AiChatAttachment.thumbSizeSmall);
      expect(await settings.getImageThumbnailSize(), AiChatAttachment.thumbSizeSmall);
    });

    test('非法缩略图尺寸收敛到 32', () async {
      final settings = AiChatSettings();
      await settings.setImageThumbnailSize(500);
      expect(await settings.getImageThumbnailSize(), AiChatAttachment.thumbSizeLarge);
    });
  });
}
