import 'dart:io';
import 'dart:typed_data';

import 'package:aquamarina/models/cloud_sync_manifest.dart';
import 'package:aquamarina/services/cloud/cloud_sync_settings.dart';
import 'package:aquamarina/services/cloud/s3_storage_service.dart';

/// 内存对象存储，供同步引擎 / 服务测试使用。
class FakeS3Storage extends S3StorageService {
  FakeS3Storage(CloudSyncConfig config)
    : super(config: config, accessKey: 'test-access', secretKey: 'test-secret');

  final Map<String, Uint8List> objects = {};

  /// 对象最后修改时间；维护测试用它模拟「超过保留期」。
  final Map<String, DateTime> lastModified = {};

  /// 模拟接下来 N 次上传失败（用于崩溃/重试测试）。
  int failPuts = 0;

  /// 键包含该子串时上传失败（用于 head / state 写失败测试）。
  String? failPutKeyContains;

  /// LIST 调用计数，用于验证 head 命中时完全不列举 chunk。
  int listCalls = 0;

  /// 已调用的 LIST 前缀（用于验证 GC 不再做全设备递归列举）。
  final List<String> listPrefixes = [];

  /// 仅对 `chunks/` 前缀的 LIST 计数。
  int chunkListCalls = 0;

  @override
  Future<String> putBytes(
    String key,
    Uint8List bytes, {
    void Function(int sent, int total)? onProgress,
  }) async {
    if (failPuts > 0) {
      failPuts--;
      throw const CloudSyncException('模拟上传失败');
    }
    if (failPutKeyContains != null && key.contains(failPutKeyContains!)) {
      throw const CloudSyncException('模拟上传失败');
    }
    objects[key] = bytes;
    lastModified[key] = DateTime.now().toUtc();
    onProgress?.call(bytes.length, bytes.length);
    return 'etag-${objects.length}';
  }

  @override
  Future<S3FileUploadResult> putFile(
    String key,
    File file, {
    void Function(int sent, int total)? onProgress,
  }) async {
    final bytes = await file.readAsBytes();
    final etag = await putBytes(key, bytes, onProgress: onProgress);
    return S3FileUploadResult(
      etag: etag,
      size: bytes.length,
      sha256: CloudSyncUtils.sha256Hex(bytes),
    );
  }

  @override
  Future<S3FileDownloadResult?> downloadToFile(
    String key,
    File output, {
    int maxBytes = 500 * 1024 * 1024,
    bool nullIfMissing = false,
    void Function(int received, int? total)? onProgress,
  }) async {
    final bytes = await getBytes(
      key,
      maxBytes: maxBytes,
      nullIfMissing: nullIfMissing,
      onProgress: onProgress,
    );
    if (bytes == null) return null;
    await output.parent.create(recursive: true);
    await output.writeAsBytes(bytes, flush: true);
    return S3FileDownloadResult(
      size: bytes.length,
      sha256: CloudSyncUtils.sha256Hex(bytes),
    );
  }

  /// 键包含该子串时模拟 GET 返回 null（对象在 LIST 之后被清理）。
  String? nullGetKeyContains;

  @override
  Future<Uint8List?> getBytes(
    String key, {
    int maxBytes = 500 * 1024 * 1024,
    bool nullIfMissing = false,
    void Function(int received, int? total)? onProgress,
  }) async {
    final bytes = objects[key];
    final missing =
        bytes == null ||
        (nullGetKeyContains != null && key.contains(nullGetKeyContains!));
    if (missing) {
      if (nullIfMissing) return null;
      throw const CloudSyncException('云端对象不存在');
    }
    onProgress?.call(bytes.length, bytes.length);
    return bytes;
  }

  @override
  Future<S3ObjectInfo?> stat(String key, {bool nullIfMissing = false}) async {
    final bytes = objects[key];
    if (bytes == null) {
      if (nullIfMissing) return null;
      throw const CloudSyncException('云端对象不存在');
    }
    return S3ObjectInfo(key: key, size: bytes.length, etag: 'etag');
  }

  @override
  Future<List<S3ObjectInfo>> list(
    String prefix, {
    bool recursive = true,
    String? startAfter,
    bool Function(String key)? stopWhen,
  }) async {
    listCalls++;
    listPrefixes.add(prefix);
    if (prefix.contains('/chunks/')) chunkListCalls++;
    final entries =
        objects.entries
            .where((entry) => entry.key.startsWith(prefix))
            .where(
              (entry) =>
                  startAfter == null || entry.key.compareTo(startAfter) > 0,
            )
            .toList()
          ..sort((a, b) => a.key.compareTo(b.key));
    final out = <S3ObjectInfo>[];
    for (final entry in entries) {
      out.add(
        S3ObjectInfo(
          key: entry.key,
          size: entry.value.length,
          etag: 'etag',
          lastModified: lastModified[entry.key],
        ),
      );
      if (stopWhen != null && stopWhen(entry.key)) break;
    }
    return out;
  }

  @override
  Future<List<String>> listCommonPrefixes(String prefix) async {
    final out = <String>{};
    for (final key in objects.keys) {
      if (!key.startsWith(prefix)) continue;
      final rest = key.substring(prefix.length);
      final slash = rest.indexOf('/');
      if (slash < 0) continue;
      out.add('$prefix${rest.substring(0, slash + 1)}');
    }
    final sorted = out.toList()..sort();
    return sorted;
  }

  @override
  Future<void> delete(String key) async {
    objects.remove(key);
  }

  @override
  Future<int> deleteMany(Iterable<String> keys) async {
    var failures = 0;
    for (final key in keys) {
      if (objects.remove(key) == null) failures++;
    }
    return failures;
  }
}
