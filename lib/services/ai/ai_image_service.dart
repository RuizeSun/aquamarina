import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../models/ai_chat.dart';
import '../system/log_service.dart';

/// 一次图片发送准备的完整结果。
///
/// [degradedFileNames] 非空表示用户要的是原图/压缩图，但本机文件读不到了，
/// 实际只发出了缩略图——上层必须把这件事告诉用户，而不是让它静默发生。
class AiImagePayload {
  final List<AiChatAttachment> attachments;
  final List<String> degradedFileNames;
  final AiImageSendMode requestedMode;
  final int missingLocalFileCount;

  const AiImagePayload({
    required this.attachments,
    this.degradedFileNames = const [],
    this.requestedMode = AiImageSendMode.compressed,
    this.missingLocalFileCount = 0,
  });

  bool get hasDegradation => degradedFileNames.isNotEmpty;

  bool get isEmpty => attachments.isEmpty;
}

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

  /// 测试专用：覆盖附件目录解析（默认走 path_provider）。
  @visibleForTesting
  static Future<Directory> Function()? attachmentDirOverride;

  /// 测试专用：恢复默认目录解析。
  @visibleForTesting
  static void resetAttachmentDirOverride() => attachmentDirOverride = null;

  /// 最近一次失败原因（供 UI 提示，落盘/构造 payload 失败时设置）。
  String? lastError;

  /// 本次运行内刚添加过的图片字节。
  ///
  /// 磁盘文件可能因为清理、权限或路径变化而读不到；只要进程还活着，
  /// 就优先用这份内存副本，避免「刚粘贴的图」被降级成 32px 缩略图。
  final Map<String, Uint8List> _memoryBytes = {};

  /// 内存副本上限（按附件数），防止内存无限增长。
  static const int _memoryCacheLimit = 8;

  void _rememberBytes(String id, Uint8List bytes) {
    _memoryBytes.remove(id);
    _memoryBytes[id] = bytes;
    while (_memoryBytes.length > _memoryCacheLimit) {
      _memoryBytes.remove(_memoryBytes.keys.first);
    }
  }

  /// 清理某个附件的内存副本。
  void forgetBytes(String id) => _memoryBytes.remove(id);

  /// 发给模型时长边上限（压缩模式）。
  ///
  /// 1024 对截图里的正文太小：模型会看不清文字。1536 是多数视觉模型
  /// 在「可读性 / token 成本」之间比较划算的档位。
  static const int maxSendDimension = 1536;

  /// 发给模型时 JPEG 质量（压缩模式）。
  ///
  /// 截图是高频文字，质量 80 会有明显压缩噪点，85 更稳。
  static const int sendJpegQuality = 85;

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
      final attachment = prepareFromBytes(
        bytes,
        fileName: p.basename(file.path),
        localPath: file.path,
        thumbnailSize: thumbnailSize,
      );
      if (attachment != null) _rememberBytes(attachment.id, bytes);
      return attachment;
    } catch (e, stackTrace) {
      logError('AiImageService', '读取图片失败: $e', stackTrace);
      return null;
    }
  }

  /// 从内存字节构造附件，并把原始字节写入应用私有目录。
  ///
  /// 剪贴板粘贴必须走这里：`prepareFromBytes` 本身不落盘，若不给 [localPath]，
  /// 「原图 / 压缩」两种发送形态会因为找不到本机文件而静默丢弃图片。
  Future<AiChatAttachment?> prepareFromBytesPersisted(
    Uint8List bytes, {
    required String fileName,
    int thumbnailSize = AiChatAttachment.thumbSizeLarge,
  }) async {
    try {
      // 先把字节解码再统一重编码为 PNG：剪贴板常给 BMP/DIB，
      // 直接原样落盘会出现「扩展名 .png 但内容是 BMP」的错配。
      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        logWarning('AiImageService', '无法解码图片: $fileName');
        return null;
      }
      final normalized = _normalizeOrientation(decoded);
      final png = Uint8List.fromList(img.encodePng(normalized, level: 6));

      final dir = await _attachmentDir();
      await dir.create(recursive: true);
      final id = const Uuid().v4();
      final target = File(p.join(dir.path, '$id.png'));
      await target.writeAsBytes(png, flush: true);
      final attachment = prepareFromBytes(
        png,
        fileName: '$id.png',
        localPath: target.path,
        thumbnailSize: thumbnailSize,
      );
      if (attachment != null) _rememberBytes(attachment.id, png);
      if (attachment == null) {
        // 解析失败时不要留下孤儿文件
        try {
          await target.delete();
        } catch (_) {}
      }
      return attachment;
    } catch (e, stackTrace) {
      logError('AiImageService', '保存剪贴板图片失败: $e', stackTrace);
      return null;
    }
  }

  /// 从内存字节构造附件（不落盘，供测试与缩略图-only 场景使用）。
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
          final bytes = await _readLocalBytes(
            attachment,
            enforceSizeLimit: true,
          );
          if (bytes == null) return null;
          // MIME 按真实字节判定：剪贴板来的 BMP 存成 .png 也不会被错误声明
          return 'data:${_mimeOfBytes(bytes)};base64,${base64Encode(bytes)}';
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

  /// 把附件准备成可发送的形态，并**如实报告**降级情况。
  ///
  /// 关键点：请求「原图 / 压缩」却读不到本机文件时，绝不能悄悄换成 32×32 缩略图
  /// 后当作成功——那正是「截图很清晰、模型却说看不清」的根因。此时按降级处理，
  /// 并把原因交给上层提示用户。
  Future<AiImagePayload> prepareForSend(
    List<AiChatAttachment> attachments,
    AiImageSendMode mode,
  ) async {
    final sent = <AiChatAttachment>[];
    final degraded = <String>[];
    var missingLocalFile = 0;

    for (final attachment in attachments) {
      // 只有缩略图形态才允许在没有本机原图时发送
      final url = await buildDataUrl(attachment, mode);
      if (url != null) {
        final size = _sentDimensions(attachment, mode, url);
        sent.add(
          attachment.copyWith(
            dataUrl: url,
            // 原图/压缩图按 high 发送：'auto' 在部分服务端会被再次降采样，
            // 截图里的文字会直接糊掉。
            detail: mode == AiImageSendMode.thumbnail ? 'low' : 'high',
            sentWidth: size.width,
            sentHeight: size.height,
          ),
        );
        continue;
      }

      if (mode != AiImageSendMode.thumbnail) {
        missingLocalFile += 1;

        // 有序回退：原图 → 压缩图 → 缩略图。
        // 直接跳到缩略图会让「原图读不到但压缩图做得出」的情况白白损失清晰度。
        final chain = mode == AiImageSendMode.original
            ? const [AiImageSendMode.compressed, AiImageSendMode.thumbnail]
            : const [AiImageSendMode.thumbnail];

        for (final fallback in chain) {
          final fallbackUrl = await buildDataUrl(attachment, fallback);
          if (fallbackUrl == null) continue;
          final size = _sentDimensions(attachment, fallback, fallbackUrl);
          sent.add(
            attachment.copyWith(
              dataUrl: fallbackUrl,
              detail: fallback == AiImageSendMode.thumbnail ? 'low' : 'high',
              sentWidth: size.width,
              sentHeight: size.height,
            ),
          );
          degraded.add(attachment.fileName);
          break;
        }
        continue;
      }

      lastError = '无法构造图片数据: ${attachment.fileName}';
      logWarning('AiImageService', lastError!);
    }

    if (degraded.isNotEmpty) {
      logWarning(
        'AiImageService',
        '${degraded.length} 张图片的本机原图不可用，已降级为 32px 缩略图：'
        '${degraded.join(', ')}',
      );
    }

    return AiImagePayload(
      attachments: sent,
      degradedFileNames: degraded,
      requestedMode: mode,
      missingLocalFileCount: missingLocalFile,
    );
  }

  /// 计算本次实际发出的像素尺寸（用于诊断日志）。
  ({int width, int height}) _sentDimensions(
    AiChatAttachment attachment,
    AiImageSendMode mode,
    String dataUrl,
  ) {
    switch (mode) {
      case AiImageSendMode.thumbnail:
        return (width: attachment.thumbnailSize, height: attachment.thumbnailSize);
      case AiImageSendMode.original:
        return (width: attachment.width, height: attachment.height);
      case AiImageSendMode.compressed:
        final longest = math.max(attachment.width, attachment.height);
        if (longest <= maxSendDimension) {
          return (width: attachment.width, height: attachment.height);
        }
        final scale = maxSendDimension / longest;
        return (
          width: (attachment.width * scale).round(),
          height: (attachment.height * scale).round(),
        );
    }
  }

  /// 兼容旧调用：只取附件列表。
  Future<List<AiChatAttachment>> withSendPayload(
    List<AiChatAttachment> attachments,
    AiImageSendMode mode,
  ) async {
    final payload = await prepareForSend(attachments, mode);
    return payload.attachments;
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
    final override = attachmentDirOverride;
    if (override != null) return override();
    final base = await getApplicationSupportDirectory();
    return Directory(p.join(base.path, 'ai_chat_images'));
  }

  /// 读取本机图片字节。
  ///
  /// [enforceSizeLimit] 只对「原图直发」生效：原样发送会把超大 base64 塞进请求体。
  /// 压缩模式必须无上限读取——先读进来再缩放，否则一张 13MB 的截图会
  /// 直接从「清晰原图」掉到 32px 缩略图。
  Future<Uint8List?> _readLocalBytes(
    AiChatAttachment attachment, {
    bool enforceSizeLimit = false,
  }) async {
    final path = attachment.localPath;
    final cached = _memoryBytes[attachment.id];
    if (path == null || path.isEmpty) {
      if (cached != null) return cached;
      return null;
    }
    final file = File(path);
    if (!await file.exists()) {
      // 磁盘文件不在了（被清理/移动），退回内存副本
      if (cached != null) return cached;
      return null;
    }
    if (enforceSizeLimit) {
      final size = await file.length();
      if (size > AiChatAttachment.maxSourceBytes) return null;
    }
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

  /// 按**文件真实字节**判定 MIME，而不是按扩展名。
  ///
  /// 剪贴板常见返回 BMP 位图，若按 `.png` 扩展名声明成 `image/png`，
  /// 服务端会因为「声明与实际不符」而拒收或识别失败，模型看到的就是糊图/黑图。
  String _mimeOfBytes(Uint8List bytes) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'image/png';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'image/jpeg';
    }
    if (bytes.length >= 6 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46) {
      return 'image/gif';
    }
    if (bytes.length >= 12 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'image/webp';
    }
    if (bytes.length >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4D) {
      return 'image/bmp';
    }
    return 'image/jpeg';
  }
}
