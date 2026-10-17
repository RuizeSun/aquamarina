import 'dart:typed_data';

import 'package:aquamarina/models/cloud_sync_manifest.dart';
import 'package:aquamarina/services/cloud_sync_settings.dart';
import 'package:aquamarina/services/s3_storage_service.dart';

/// 内存对象存储，供同步引擎 / 服务测试使用。
class FakeS3Storage extends S3StorageService {
  FakeS3Storage(CloudSyncConfig config)
    : super(config: config, accessKey: 'test-access', secretKey: 'test-secret');

  final Map<String, Uint8List> objects = {};

  /// 模拟接下来 N 次上传失败（用于崩溃/重试测试）。
  int failPuts = 0;

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
    objects[key] = bytes;
    onProgress?.call(bytes.length, bytes.length);
    return 'etag-${objects.length}';
  }

  @override
  Future<Uint8List?> getBytes(
    String key, {
    int maxBytes = 500 * 1024 * 1024,
    bool nullIfMissing = false,
    void Function(int received, int? total)? onProgress,
  }) async {
    final bytes = objects[key];
    if (bytes == null) {
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
  }) async {
    return objects.entries
        .where((entry) => entry.key.startsWith(prefix))
        .map(
          (entry) => S3ObjectInfo(
            key: entry.key,
            size: entry.value.length,
            etag: 'etag',
          ),
        )
        .toList();
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
