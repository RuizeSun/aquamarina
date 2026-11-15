import 'dart:io';

import 'package:flutter/widgets.dart';

import '../../models/ai_chat.dart';
import '../../services/ai/ai_image_service.dart';

/// 为附件挑选可用的 [ImageProvider]。
///
/// 优先使用本机原图；跨设备同步后没有原图时退回 16/32px 缩略图。
/// 两者都不可用时返回 null（调用方展示占位图标）。
ImageProvider? myAttachmentProvider(AiChatAttachment attachment) {
  final path = attachment.localPath;
  if (path != null && path.isNotEmpty && File(path).existsSync()) {
    return FileImage(File(path));
  }
  final thumb = AiImageService.instance.decodeThumbnail(attachment);
  if (thumb == null) return null;
  return MemoryImage(thumb);
}
