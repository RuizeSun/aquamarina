import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../models/ai_chat.dart';
import '../system/log_service.dart';

/// 送给模型时使用的图片形态。
enum AiImageSendMode {
  /// 发原图（质量最好，token 消耗最大）
  original,

  /// 发压缩后的原图（长边限制到 [AiImageService.maxSendDimension]）
  compressed,

  /// 只发 16/32px 缩略图（token 最少，细节几乎丢失）
  thumbnail;

  static AiImageSendMode fromName(String? name) => values.firstWhere(
    (e) => e.name == name,
    orElse: () => AiImageSendMode.compressed,
  );
}

/// 图片附件的准备、压缩与 base64 编码。
///
/// 设计要点：
/// - **同步**只传 16/32px 缩略图（PNG base64），原图留在本机；
/// - **发给模型**的形态由设置决定（原图 / 压缩 / 缩略图）；
/// - 解码失败、格式不支持、体积过大都只记录日志并跳过该图，不阻断消息发送。
class AiImageService {
  AiImageService._();

  static final AiImageService instance = AiImageService._();

  /// 发给模型时长边上限（压缩模式）。
  static const int maxSendDimension = 1024;

  /// 发给模型时 JPEG 质量（压缩模式）。
  static const int sendJpegQuality = 80;

  /// 单条消息最多附带几张图。
  static const int maxAttachmentsPerMessage = 4;

  /// 读取并解析一张图片，产出可入库的附件对象。
  ///
  /// [thumbnailSize] 决定同步用缩略图边长（16 或 32）。
  Future<AiChatAttachment?> prepareFromFile(
    File file, {
    int thumbnailSize = AiChatAttachment.thumbSizeLarge,
  }) async {
    try {
      final size = await file.length();
      if (size > AiChatAttachment.maxSourceBytes) {
        logWarning('AiImageService', '图片过大已跳过: ${file.path} ($size 字节)');
        return null;
      }
      final bytes = await file.readAsBytes();
      return prepareFromBytes(
        bytes,
        fileName: p.basename(file.path),
        localPath: file.path,
        thumbnailSize: thumbnailSize,
      );
    } catch (e, stackTrace) {
      logError('AiImageService', '读取图片失败: $e', stackTrace);
      return null;
    }
  }

  /// 从内存字节构造附件（也用于剪贴板粘贴）。
  AiChatAttachment? prepareFromBytes(
    Uint8List bytes, {
    required String fileName,
    String? localPath,
    int thumbnailSize = AiChatAttachment.thumbSizeLarge,
  }) {
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        logWarning('AiImageService', '无法解码图片: $fileName');
        return null;
      }
      final normalized = _normalizeOrientation(decoded);
      final thumb = _encodeThumbnail(normalized, thumbnailSize);
      if (thumb == null) return null;

      return AiChatAttachment(
        id: const Uuid().v4(),
        localPath: localPath,
        fileName: fileName,
        width: normalized.width,
        height: normalized.height,
        thumbnailBase64: base64Encode(thumb),
        thumbnailSize: thumbnailSize,
      );
    } catch (e, stackTrace) {
      logError('AiImageService', '解析图片失败: $e', stackTrace);
      return null;
    }
  }

  /// 把原图复制到应用私有目录并返回附件（跨重启仍可读）。
  Future<AiChatAttachment?> importFile(
    File source, {
    int thumbnailSize = AiChatAttachment.thumbSizeLarge,
  }) async {
    try {
      final dir = await _attachmentDir();
      await dir.create(recursive: true);
      final id = const Uuid().v4();
      final ext = p.extension(source.path).toLowerCase();
      final safeExt = ext.isEmpty ? '.img' : ext;
      final target = File(p.join(dir.path, '$id$safeExt'));
      await source.copy(target.path);
      return await prepareFromFile(target, thumbnailSize: thumbnailSize);
    } catch (e, stackTrace) {
      logError('AiImageService', '导入图片失败: $e', stackTrace);
      return null;
    }
  }

  /// 构造发给模型的 data URL。
  Future<String?> buildDataUrl(
    AiChatAttachment attachment,
    AiImageSendMode mode,
  ) async {
    try {
      switch (mode) {
        case AiImageSendMode.thumbnail:
          if (attachment.thumbnailBase64.isEmpty) return null;
          return 'data:image/png;base64,${attachment.thumbnailBase64}';
        case AiImageSendMode.original:
          final bytes = await _readLocalBytes(attachment);
          if (bytes == null) return null;
          return 'data:${_mimeOf(attachment.fileName)};base64,${base64Encode(bytes)}';
        case AiImageSendMode.compressed:
          final bytes = await _readLocalBytes(attachment);
          if (bytes == null) return null;
          final compressed = _compressForSend(bytes);
          if (compressed == null) return null;
          return 'data:image/jpeg;base64,${base64Encode(compressed)}';
      }
    } catch (e, stackTrace) {
      logError('AiImageService', '构造图片 data URL 失败: $e', stackTrace);
      return null;
    }
  }

  /// 为一批附件填充运行期字段（dataUrl / detail）。
  Future<List<AiChatAttachment>> withSendPayload(
    List<AiChatAttachment> attachments,
    AiImageSendMode mode,
  ) async {
    final result = <AiChatAttachment>[];
    for (final attachment in attachments) {
      final url = await buildDataUrl(attachment, mode);
      if (url == null) continue;
      result.add(
        attachment.copyWith(
          dataUrl: url,
          detail: mode == AiImageSendMode.thumbnail ? 'low' : 'auto',
        ),
      );
    }
    return result;
  }

  /// 缩略图的本地 ImageProvider 数据（用于气泡内展示）。
  Uint8List? decodeThumbnail(AiChatAttachment attachment) {
    if (attachment.thumbnailBase64.isEmpty) return null;
    try {
      return base64Decode(attachment.thumbnailBase64);
    } catch (_) {
      return null;
    }
  }

  /// 删除会话时清理本机原图。
  Future<void> deleteLocalFiles(Iterable<AiChatAttachment> attachments) async {
    for (final attachment in attachments) {
      final path = attachment.localPath;
      if (path == null || path.isEmpty) continue;
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (e) {
        logWarning('AiImageService', '删除图片文件失败: $e');
      }
    }
  }

  // ── 内部 ──────────────────────────────────────────

  Future<Directory> _attachmentDir() async {
    final base = await getApplicationSupportDirectory();
    return Directory(p.join(base.path, 'ai_chat_images'));
  }

  Future<Uint8List?> _readLocalBytes(AiChatAttachment attachment) async {
    final path = attachment.localPath;
    if (path == null || path.isEmpty) return null;
    final file = File(path);
    if (!await file.exists()) return null;
    // 原图也做一次体积保护，避免把巨大的 base64 塞进请求体
    final size = await file.length();
    if (size > AiChatAttachment.maxSourceBytes) return null;
    return file.readAsBytes();
  }

  Uint8List? _encodeThumbnail(img.Image source, int size) {
    final target = size == AiChatAttachment.thumbSizeSmall
        ? AiChatAttachment.thumbSizeSmall
        : AiChatAttachment.thumbSizeLarge;
    try {
      final resized = img.copyResize(
        source,
        width: target,
        height: target,
        maintainAspect: false,
        interpolation: img.Interpolation.average,
      );
      return img.encodePng(resized, level: 6);
    } catch (e) {
      logWarning('AiImageService', '生成缩略图失败: $e');
      return null;
    }
  }

  Uint8List? _compressForSend(Uint8List bytes) {
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return null;
      final normalized = _normalizeOrientation(decoded);
      final longest = math.max(normalized.width, normalized.height);
      final resized = longest > maxSendDimension
          ? img.copyResize(
              normalized,
              width: normalized.width >= normalized.height
                  ? maxSendDimension
                  : null,
              height: normalized.height > normalized.width
                  ? maxSendDimension
                  : null,
              interpolation: img.Interpolation.average,
            )
          : normalized;
      return img.encodeJpg(resized, quality: sendJpegQuality);
    } catch (e) {
      logWarning('AiImageService', '压缩图片失败: $e');
      return null;
    }
  }

  /// 应用 EXIF 方向，避免手机竖拍照片被模型看成横向。
  img.Image _normalizeOrientation(img.Image source) {
    try {
      final baked = img.bakeOrientation(source);
      return baked;
    } catch (_) {
      return source;
    }
  }

  String _mimeOf(String fileName) {
    final ext = p.extension(fileName).toLowerCase();
    switch (ext) {
      case '.png':
        return 'image/png';
      case '.webp':
        return 'image/webp';
      case '.gif':
        return 'image/gif';
      case '.bmp':
        return 'image/bmp';
      default:
        return 'image/jpeg';
    }
  }
}
