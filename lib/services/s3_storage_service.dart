import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:minio/minio.dart';

import '../models/cloud_sync_manifest.dart';
import 'cloud_sync_settings.dart';
import 'log_service.dart';

/// 文件上传结果（流式上传）。
class S3FileUploadResult {
  final String etag;
  final int size;
  final String sha256;

  const S3FileUploadResult({
    required this.etag,
    required this.size,
    required this.sha256,
  });
}

/// 文件下载结果（流式下载）。
class S3FileDownloadResult {
  final int size;
  final String sha256;

  const S3FileDownloadResult({required this.size, required this.sha256});
}

/// 收集 `startChunkedConversion` 的最终摘要。
class _DigestCollector implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}

/// 对象列表条目（只保留同步需要的字段）。
class S3ObjectInfo {
  final String key;
  final int? size;
  final String? etag;
  final DateTime? lastModified;

  const S3ObjectInfo({
    required this.key,
    this.size,
    this.etag,
    this.lastModified,
  });
}

/// S3 兼容对象存储客户端封装。
///
/// 设计约束（与 `docs/cloud-sync-spec.md` 一致）：
/// - 只使用 PUT / GET / HEAD / LIST / DELETE；
/// - 所有网络操作都有超时；
/// - 对外只抛 [CloudSyncException]，消息中不包含任何密钥或签名；
/// - 自动区分「对象不存在」与真实错误。
class S3StorageService {
  static const Duration _defaultTimeout = Duration(seconds: 40);
  static const Duration _listTimeout = Duration(seconds: 60);

  final CloudSyncConfig config;
  final String accessKey;
  final String secretKey;

  late final Minio _minio;

  S3StorageService({
    required this.config,
    required this.accessKey,
    required this.secretKey,
  }) {
    _minio = Minio(
      endPoint: config.endpoint,
      port: config.port,
      useSSL: config.useSsl,
      region: config.region,
      pathStyle: config.pathStyle,
      accessKey: accessKey,
      secretKey: secretKey,
    );
  }

  String get _rootPrefix {
    final prefix = config.prefix;
    return prefix.isEmpty ? '' : '$prefix/';
  }

  /// 连接 + 权限自检：Bucket 可访问、可写、可读、可删、可列举。
  ///
  /// 返回值用于 UI 展示（不包含敏感信息）。
  Future<String> testConnection() async {
    return _guard('连接测试', () async {
      final exists = await _minio
          .bucketExists(config.bucket)
          .timeout(_defaultTimeout);
      if (!exists) {
        throw const CloudSyncException('存储桶不存在，或当前密钥无权访问该桶');
      }

      final probeKey =
          '$_rootPrefix.healthcheck-${DateTime.now().microsecondsSinceEpoch}';
      final probe = Uint8List.fromList(
        utf8.encode(
          'aquamarina-healthcheck-${DateTime.now().toIso8601String()}',
        ),
      );
      try {
        await _minio
            .putObject(
              config.bucket,
              probeKey,
              Stream<Uint8List>.value(probe),
              size: probe.length,
            )
            .timeout(_defaultTimeout);
        final stat = await _minio
            .statObject(config.bucket, probeKey)
            .timeout(_defaultTimeout);
        if (stat.size != probe.length) {
          throw const CloudSyncException('连接测试失败：写入后读取到的文件大小不一致');
        }
        final object = await _minio
            .getObject(config.bucket, probeKey)
            .timeout(_defaultTimeout);
        final roundTrip = await _readAll(object, maxBytes: 4096);
        if (roundTrip.length != probe.length) {
          throw const CloudSyncException('连接测试失败：读取内容不完整');
        }
      } finally {
        // 清理探测对象；失败不掩盖主流程结果
        try {
          await _minio
              .removeObject(config.bucket, probeKey)
              .timeout(_defaultTimeout);
        } catch (_) {}
      }

      final objects = await list(_rootPrefix, recursive: true);
      return '连接成功：桶 ${config.bucket}，前缀下已有 ${objects.length} 个对象';
    });
  }

  /// 上传字节对象，返回服务端 ETag。
  Future<String> putBytes(
    String key,
    Uint8List bytes, {
    void Function(int sent, int total)? onProgress,
  }) async {
    return _guard('上传对象', () async {
      final timeout = _uploadTimeout(bytes.length);
      final etag = await _minio
          .putObject(
            config.bucket,
            key,
            Stream<Uint8List>.value(bytes),
            size: bytes.length,
            onProgress: (sent) {
              onProgress?.call(sent, bytes.length);
            },
          )
          .timeout(timeout);
      return etag;
    });
  }

  /// 流式上传文件，避免把大文件整体读入内存（P0-2）。
  ///
  /// 同时计算完整 SHA-256，供快照清单直接使用。
  Future<S3FileUploadResult> putFile(
    String key,
    File file, {
    void Function(int sent, int total)? onProgress,
  }) async {
    return _guard('上传文件', () async {
      final size = await file.length();
      final timeout = _uploadTimeout(size);
      final collector = _DigestCollector();
      final hashSink = sha256.startChunkedConversion(collector);
      final stream = file.openRead().map((chunk) {
        final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
        hashSink.add(bytes);
        return bytes;
      });
      try {
        final etag = await _minio
            .putObject(
              config.bucket,
              key,
              stream,
              size: size,
              onProgress: (sent) => onProgress?.call(sent, size),
            )
            .timeout(timeout);
        hashSink.close();
        return S3FileUploadResult(
          etag: etag,
          size: size,
          sha256: collector.value?.toString() ?? '',
        );
      } finally {
        try {
          hashSink.close();
        } catch (_) {}
      }
    });
  }

  /// 流式下载对象到文件，边写边算 SHA-256。
  ///
  /// [maxBytes] 防止异常大文件占满磁盘/内存；[nullIfMissing] 为 true 时
  /// 对象不存在返回 null（用于可选清单/状态文件）。
  Future<S3FileDownloadResult?> downloadToFile(
    String key,
    File output, {
    int maxBytes = 500 * 1024 * 1024,
    bool nullIfMissing = false,
    void Function(int received, int? total)? onProgress,
  }) async {
    return _guard('下载文件', () async {
      try {
        final object = await _minio
            .getObject(config.bucket, key)
            .timeout(_defaultTimeout);
        final total = object.contentLength;
        if (total != null && total > maxBytes) {
          throw CloudSyncException(
            '云端文件过大（${CloudSyncUtils.formatBytes(total)}），已中止下载',
          );
        }
        final parent = output.parent;
        if (!await parent.exists()) {
          await parent.create(recursive: true);
        }
        final sink = output.openWrite();
        final collector = _DigestCollector();
        final hashSink = sha256.startChunkedConversion(collector);
        var received = 0;
        try {
          await for (final chunk in object.timeout(
            const Duration(seconds: 60),
            onTimeout: (s) => s.addError(
              TimeoutException('读取对象超时', const Duration(seconds: 60)),
            ),
          )) {
            final bytes = chunk is Uint8List
                ? chunk
                : Uint8List.fromList(chunk);
            received += bytes.length;
            if (received > maxBytes) {
              throw CloudSyncException(
                '云端文件超过大小上限（${CloudSyncUtils.formatBytes(maxBytes)}），已中止下载',
              );
            }
            sink.add(bytes);
            hashSink.add(bytes);
            onProgress?.call(received, total);
          }
        } finally {
          await sink.close();
          hashSink.close();
        }
        if (total != null && received != total) {
          throw const CloudSyncException('下载内容不完整，请重试');
        }
        return S3FileDownloadResult(
          size: received,
          sha256: collector.value?.toString() ?? '',
        );
      } catch (e) {
        if (nullIfMissing && _isNotFound(e)) return null;
        try {
          if (await output.exists()) await output.delete();
        } catch (_) {}
        rethrow;
      }
    });
  }

  /// 下载对象。
  ///
  /// [maxBytes] 防止异常大文件把内存打满；[nullIfMissing] 为 true 时
  /// 对象不存在返回 null（用于可选清单/状态文件）。
  Future<Uint8List?> getBytes(
    String key, {
    int maxBytes = 500 * 1024 * 1024,
    bool nullIfMissing = false,
    void Function(int received, int? total)? onProgress,
  }) async {
    return _guard('下载对象', () async {
      try {
        final object = await _minio
            .getObject(config.bucket, key)
            .timeout(_defaultTimeout);
        final total = object.contentLength;
        if (total != null && total > maxBytes) {
          throw CloudSyncException(
            '云端文件过大（${CloudSyncUtils.formatBytes(total)}），已中止下载',
          );
        }
        final bytes = await _readAll(
          object,
          maxBytes: maxBytes,
          onProgress: onProgress,
        );
        if (total != null && bytes.length != total) {
          throw const CloudSyncException('下载内容不完整，请重试');
        }
        return bytes;
      } catch (e) {
        if (nullIfMissing && _isNotFound(e)) return null;
        rethrow;
      }
    });
  }

  /// 查询对象元信息；[nullIfMissing] 为 true 时不存在返回 null。
  Future<S3ObjectInfo?> stat(String key, {bool nullIfMissing = false}) async {
    return _guard('查询对象', () async {
      try {
        final stat = await _minio
            .statObject(config.bucket, key)
            .timeout(_defaultTimeout);
        return S3ObjectInfo(
          key: key,
          size: stat.size,
          etag: stat.etag,
          lastModified: stat.lastModified,
        );
      } catch (e) {
        if (nullIfMissing && _isNotFound(e)) return null;
        rethrow;
      }
    });
  }

  /// 列举前缀下的对象。
  ///
  /// [startAfter] 用于增量拉取：只返回键严格大于该值的对象，
  /// 配合 `sync_state.last_chunk_key` 可以避免重复列举历史 chunk。
  Future<List<S3ObjectInfo>> list(
    String prefix, {
    bool recursive = true,
    String? startAfter,
  }) async {
    return _guard('列举对象', () async {
      final pages = await _minio
          .listObjectsV2(
            config.bucket,
            prefix: prefix,
            recursive: recursive,
            startAfter: startAfter,
          )
          .toList()
          .timeout(_listTimeout);
      final out = <S3ObjectInfo>[];
      for (final page in pages) {
        for (final item in page.objects) {
          final key = item.key;
          if (key == null || key.isEmpty) continue;
          out.add(
            S3ObjectInfo(
              key: key,
              size: item.size,
              etag: item.eTag,
              lastModified: item.lastModified,
            ),
          );
        }
      }
      return out;
    });
  }

  /// 只列举「目录」（S3 CommonPrefixes），不展开其下对象。
  ///
  /// 用于发现 `{prefix}/devices/` 下的设备 ID：一次请求即可拿到设备列表，
  /// 不必递归列举所有 chunk。
  Future<List<String>> listCommonPrefixes(String prefix) async {
    return _guard('列举目录', () async {
      final pages = await _minio
          .listObjectsV2(config.bucket, prefix: prefix, recursive: false)
          .toList()
          .timeout(_listTimeout);
      final out = <String>{};
      for (final page in pages) {
        out.addAll(page.prefixes);
      }
      final sorted = out.toList()..sort();
      return sorted;
    });
  }

  /// 删除单个对象（不存在时视为成功）。
  Future<void> delete(String key) async {
    await _guard('删除对象', () async {
      try {
        await _minio.removeObject(config.bucket, key).timeout(_defaultTimeout);
      } catch (e) {
        if (_isNotFound(e)) return;
        rethrow;
      }
    });
  }

  /// 批量删除（失败继续，返回失败数量）。
  Future<int> deleteMany(Iterable<String> keys) async {
    var failures = 0;
    for (final key in keys) {
      try {
        await delete(key);
      } catch (e) {
        failures++;
        logWarning('S3StorageService', '删除对象失败 $key: $e');
      }
    }
    return failures;
  }

  // ── 内部工具 ────────────────────────────────────────

  Future<Uint8List> _readAll(
    Stream<List<int>> stream, {
    required int maxBytes,
    void Function(int received, int? total)? onProgress,
  }) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream.timeout(
      const Duration(seconds: 60),
      onTimeout: (sink) => sink.addError(
        TimeoutException('读取对象超时', const Duration(seconds: 60)),
      ),
    )) {
      builder.add(chunk);
      if (builder.length > maxBytes) {
        throw CloudSyncException(
          '云端文件超过大小上限（${CloudSyncUtils.formatBytes(maxBytes)}），已中止下载',
        );
      }
      onProgress?.call(builder.length, null);
    }
    return builder.takeBytes();
  }

  /// 上传超时：至少 40 秒，按 50 KB/s 下限估算，最多 15 分钟。
  Duration _uploadTimeout(int bytes) {
    final estimatedSeconds = (bytes / (50 * 1024)).ceil() + 30;
    final capped = estimatedSeconds.clamp(40, 15 * 60);
    return Duration(seconds: capped);
  }

  Future<T> _guard<T>(String action, Future<T> Function() body) async {
    try {
      return await body();
    } on CloudSyncException {
      rethrow;
    } catch (e, stackTrace) {
      final message = _friendlyMessage(e);
      logWarning('S3StorageService', '$action 失败: $message');
      logDebug('S3StorageService', '原始错误: $e\n$stackTrace');
      throw CloudSyncException(message);
    }
  }

  static bool _isNotFound(Object error) {
    if (error is MinioS3Error) {
      if (error.response?.statusCode == 404) return true;
      final code = error.error?.code?.toLowerCase() ?? '';
      if (code == 'nosuchkey' || code == 'nosuchobject' || code == 'notfound') {
        return true;
      }
    }
    final text = error.toString().toLowerCase();
    return text.contains('nosuchkey') ||
        text.contains('no such key') ||
        text.contains('statuscode: 404');
  }

  static String _friendlyMessage(Object error) {
    if (error is CloudSyncException) return error.message;
    if (error is MinioS3Error) {
      final code = error.error?.code ?? '';
      final raw = error.error?.message ?? error.message ?? '';
      switch (code) {
        case 'NoSuchBucket':
          return '存储桶不存在，或当前密钥无权访问该桶';
        case 'NoSuchKey':
          return '云端对象不存在';
        case 'AccessDenied':
          return '无权访问该存储桶，请检查密钥权限';
        case 'InvalidAccessKeyId':
          return 'Access Key 无效，请重新填写';
        case 'SignatureDoesNotMatch':
          return 'Secret Key 不正确，或端点/区域配置与服务器不一致';
        case 'RequestTimeTooSkewed':
          return '本机时间与服务器相差过大，请校准系统时间后重试';
        case 'SlowDown':
          return '请求过于频繁，请稍后重试';
        case 'EntityTooLarge':
          return '文件超过对象存储的大小限制';
      }
      return '对象存储返回错误${code.isEmpty ? '' : '（$code）'}：$raw';
    }
    if (error is MinioInvalidEndpointError) {
      return '访问端点无效，请检查域名与端口';
    }
    if (error is MinioInvalidBucketNameError) {
      return '存储桶名称不合法';
    }
    if (error is HandshakeException) {
      return 'TLS 握手失败：请确认端点使用 HTTPS 且证书有效';
    }
    if (error is SocketException) {
      return '无法连接对象存储：${error.message}';
    }
    if (error is TimeoutException) {
      return '连接超时，请检查网络、端点与端口';
    }
    return '对象存储请求失败：$error';
  }
}
