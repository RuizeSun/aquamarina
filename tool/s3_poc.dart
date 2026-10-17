// S3 兼容对象存储连通性 PoC（仅用于开发验证，不参与 App 构建）。
//
// 凭据只从环境变量读取，禁止硬编码到仓库：
//   S3_ENDPOINT / S3_BUCKET / S3_REGION / S3_ACCESS_KEY / S3_SECRET_KEY
//   S3_PATH_STYLE=true|false（默认 true）
//
// 运行：
//   dart run tool/s3_poc.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:minio/minio.dart';

const String _prefix = 'aquamarina/poc/';

Future<void> main() async {
  final env = Platform.environment;
  final endPoint = env['S3_ENDPOINT'] ?? 'cn-nb1.rains3.com';
  final bucket = env['S3_BUCKET'] ?? 'aquamarina-test';
  final region = env['S3_REGION'] ?? 'cn-nb1';
  final accessKey = env['S3_ACCESS_KEY'];
  final secretKey = env['S3_SECRET_KEY'];
  final useSSL = (env['S3_SSL'] ?? 'true').toLowerCase() != 'false';
  final pathStyle = (env['S3_PATH_STYLE'] ?? 'true').toLowerCase() != 'false';

  if (accessKey == null ||
      accessKey.isEmpty ||
      secretKey == null ||
      secretKey.isEmpty) {
    stderr.writeln('缺少 S3_ACCESS_KEY / S3_SECRET_KEY 环境变量');
    exit(2);
  }

  final minio = Minio(
    endPoint: endPoint,
    accessKey: accessKey,
    secretKey: secretKey,
    useSSL: useSSL,
    region: region,
    pathStyle: pathStyle,
  );

  final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
  final key = '${_prefix}hello_$stamp.json';
  final payload = utf8.encode(
    jsonEncode({
      'app': 'aquamarina',
      'purpose': 's3-poc',
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'random': DateTime.now().microsecondsSinceEpoch,
    }),
  );

  _log(
    'endpoint=$endPoint bucket=$bucket region=$region pathStyle=$pathStyle ssl=$useSSL',
  );

  try {
    final exists = await minio.bucketExists(bucket);
    _log('bucketExists($bucket) => $exists');
    if (!exists) {
      stderr.writeln('桶不存在或当前密钥无权访问，后续步骤中止');
      exit(3);
    }

    final etag = await minio.putObject(
      bucket,
      key,
      Stream<Uint8List>.value(Uint8List.fromList(payload)),
      size: payload.length,
      onProgress: (sent) => _log('put progress: $sent/${payload.length}'),
    );
    _log('putObject ok, etag=$etag, bytes=${payload.length}');

    final stat = await minio.statObject(bucket, key);
    _log('statObject ok, size=${stat.size}, etag=${stat.etag}');

    final object = await minio.getObject(bucket, key);
    final chunks = <int>[];
    await for (final chunk in object) {
      chunks.addAll(chunk);
    }
    final roundTrip = utf8.decode(chunks);
    _log(
      'getObject ok, bytes=${chunks.length}, identical=${roundTrip == utf8.decode(payload)}',
    );
    _log('payload => $roundTrip');

    final listed = await minio
        .listObjectsV2(bucket, prefix: _prefix, recursive: true)
        .toList();
    final objects = listed.expand((r) => r.objects).toList();
    _log('listObjectsV2 ok, pages=${listed.length}, objects=${objects.length}');
    for (final item in objects) {
      _log('  - ${item.key} (${item.size} bytes)');
    }

    await minio.removeObject(bucket, key);
    _log('removeObject ok');

    _log('POC PASSED');
  } catch (e, st) {
    stderr.writeln('POC FAILED: $e');
    stderr.writeln(st);
    exit(1);
  }
}

void _log(String message) {
  stdout.writeln('[${DateTime.now().toIso8601String()}] $message');
}
