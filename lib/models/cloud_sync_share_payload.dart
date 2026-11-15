import 'dart:convert';
import 'dart:typed_data';

import 'cloud_sync_manifest.dart';
import '../services/cloud/cloud_sync_settings.dart';

/// 云同步配置的二维码分享载荷。
///
/// 设计约束（与 `docs/cloud-sync-handoff.md` 的模型约定一致）：
/// - 只依赖 [CloudSyncConfig] 等既有模型，不触碰网络、文件与相机，便于单元测试；
/// - 载荷自带版本号，旧版本设备读到新载荷会明确提示升级，而不是写入半截配置；
/// - **不携带设备 ID / dataset ID**：设备身份必须每台独立，否则两台设备会互相
///   覆盖 `devices/${deviceId}/` 前缀；
/// - 仅复用 [CloudSyncConfig.create] 的既有校验，避免两套规则漂移。
class CloudSyncSharePayload {
  static const String uriScheme = 'aquamarina';
  static const String uriHost = 'cloud-sync';
  static const String uriPathSegment = 'v1';

  /// 当前载荷格式版本。
  static const int currentVersion = 1;

  /// 载荷字符数上限：超过即认为不是本应用的二维码，避免超长内容进入解码器。
  static const int maxPayloadChars = 2048;

  final int version;
  final String endpoint;
  final int? port;
  final bool useSsl;
  final String region;
  final String bucket;
  final String prefix;
  final bool pathStyle;
  final String? accessKey;
  final String? secretKey;
  final String deviceName;
  final DateTime createdAt;

  const CloudSyncSharePayload({
    this.version = currentVersion,
    required this.endpoint,
    this.port,
    required this.useSsl,
    required this.region,
    required this.bucket,
    required this.prefix,
    required this.pathStyle,
    this.accessKey,
    this.secretKey,
    this.deviceName = '',
    required this.createdAt,
  });

  /// 是否携带可用的对象存储凭据。
  bool get hasCredentials {
    final access = accessKey?.trim() ?? '';
    final secret = secretKey?.trim() ?? '';
    return access.isNotEmpty && secret.isNotEmpty;
  }

  /// 从本机配置构造载荷；[credentials] 为 null 表示创建「不含密钥」的分享码。
  factory CloudSyncSharePayload.fromConfig({
    required CloudSyncConfig config,
    CloudSyncCredentials? credentials,
    String deviceName = '',
    DateTime? now,
  }) {
    final includeSecrets = credentials != null && credentials.isComplete;
    return CloudSyncSharePayload(
      endpoint: config.endpoint,
      port: config.port,
      useSsl: config.useSsl,
      region: config.region,
      bucket: config.bucket,
      prefix: config.prefix,
      pathStyle: config.pathStyle,
      accessKey: includeSecrets ? credentials.accessKey.trim() : null,
      secretKey: includeSecrets ? credentials.secretKey.trim() : null,
      deviceName: deviceName.trim(),
      createdAt: (now ?? DateTime.now()).toUtc(),
    );
  }

  /// 压缩后的 JSON 键名：二维码容量有限，短键能把含密钥载荷压到 400 字符内。
  Map<String, dynamic> toJson() => {
    'v': version,
    'ep': endpoint,
    'pt': port,
    'ssl': useSsl,
    'rg': region,
    'bk': bucket,
    'pf': prefix,
    'ps': pathStyle,
    if (accessKey != null) 'ak': accessKey,
    if (secretKey != null) 'sk': secretKey,
    if (deviceName.isNotEmpty) 'dn': deviceName,
    't': createdAt.toUtc().millisecondsSinceEpoch,
  };

  static CloudSyncSharePayload fromJson(Map<String, dynamic> json) {
    final version = json['v'];
    if (version is! int) {
      throw const CloudSyncException('二维码内容缺少版本信息');
    }
    if (version > currentVersion) {
      throw const CloudSyncException('二维码来自更新版本的应用，请先升级本机应用');
    }
    if (version < 1) {
      throw const CloudSyncException('二维码格式过旧，请在旧设备上升级应用后重新生成');
    }
    final endpoint = json['ep'];
    final port = json['pt'];
    final useSsl = json['ssl'];
    final region = json['rg'];
    final bucket = json['bk'];
    final prefix = json['pf'];
    final pathStyle = json['ps'];
    if (endpoint is! String ||
        (port != null && port is! int) ||
        useSsl is! bool ||
        region is! String ||
        bucket is! String ||
        prefix is! String ||
        pathStyle is! bool) {
      throw const CloudSyncException('二维码内容不完整，请重新生成');
    }
    final accessKey = json['ak'];
    final secretKey = json['sk'];
    if ((accessKey != null && accessKey is! String) ||
        (secretKey != null && secretKey is! String)) {
      throw const CloudSyncException('二维码中的访问凭据格式异常');
    }
    final hasAccess = (accessKey as String?)?.trim().isNotEmpty ?? false;
    final hasSecret = (secretKey as String?)?.trim().isNotEmpty ?? false;
    if (hasAccess != hasSecret) {
      throw const CloudSyncException('二维码中的访问凭据不完整，请重新生成');
    }
    final deviceName = json['dn'];
    final createdAtMs = json['t'];
    final payload = CloudSyncSharePayload(
      version: version,
      endpoint: endpoint,
      port: port as int?,
      useSsl: useSsl,
      region: region,
      bucket: bucket,
      prefix: prefix,
      pathStyle: pathStyle,
      accessKey: hasAccess ? (accessKey as String).trim() : null,
      secretKey: hasSecret ? (secretKey as String).trim() : null,
      deviceName: deviceName is String ? deviceName.trim() : '',
      createdAt: createdAtMs is int
          ? DateTime.fromMillisecondsSinceEpoch(createdAtMs, isUtc: true)
          : DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
    // 复用既有校验：桶名 / 区域 / 前缀 / 端口越界都会在这里抛出中文错误。
    payload.toConfig();
    return payload;
  }

  /// 编码为 `aquamarina://cloud-sync/v1/<base64url(utf8(json))>`。
  ///
  /// 用 URI 而不是裸 JSON：一眼可辨识来源，复制粘贴时也不会被当成普通文本。
  /// base64url 去 padding，避免 '+' '/' '=' 在二维码与剪贴板中的歧义。
  String encode() {
    final raw = utf8.encode(jsonEncode(toJson()));
    return '$uriScheme://$uriHost/$uriPathSegment/${base64Url.encode(raw).replaceAll('=', '')}';
  }

  /// 解析任意文本；非本应用内容或损坏内容都会抛 [CloudSyncException]。
  static CloudSyncSharePayload decode(String raw) {
    final text = raw.trim();
    if (text.isEmpty) {
      throw const CloudSyncException('二维码内容为空');
    }
    if (text.length > maxPayloadChars) {
      throw const CloudSyncException('二维码内容过长，可能不是本应用的配置');
    }
    final Uri uri;
    try {
      uri = Uri.parse(text);
    } catch (_) {
      throw const CloudSyncException('这不是 Aquamarina 的云同步二维码');
    }
    if (uri.scheme.toLowerCase() != uriScheme ||
        uri.host.toLowerCase() != uriHost) {
      throw const CloudSyncException('这不是 Aquamarina 的云同步二维码');
    }
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.length != 2 || segments.first != uriPathSegment) {
      throw const CloudSyncException('二维码格式不受支持，请升级应用后重新生成');
    }
    final Uint8List bytes;
    try {
      bytes = base64Url.decode(base64Url.normalize(segments.last));
    } catch (_) {
      throw const CloudSyncException('二维码内容已损坏，请重新生成');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } catch (_) {
      throw const CloudSyncException('二维码内容已损坏，请重新生成');
    }
    if (decoded is! Map) {
      throw const CloudSyncException('二维码内容已损坏，请重新生成');
    }
    return fromJson(decoded.cast<String, dynamic>());
  }

  /// 还原为可直接落盘的配置；所有字段都会重新走一次格式校验。
  CloudSyncConfig toConfig() {
    final scheme = useSsl ? 'https' : 'http';
    final endpointInput = port == null ? '$scheme://$endpoint' : '$scheme://$endpoint:$port';
    return CloudSyncConfig.create(
      endpointInput: endpointInput,
      bucket: bucket,
      region: region,
      prefix: prefix,
      pathStyle: pathStyle,
    );
  }

  /// 还原凭据；载荷不含密钥时返回 null。
  CloudSyncCredentials? toCredentials() {
    if (!hasCredentials) return null;
    return CloudSyncCredentials(
      accessKey: accessKey!.trim(),
      secretKey: secretKey!.trim(),
    );
  }

  /// 展示用摘要：**任何情况下都不回显 Secret Key 明文**。
  String get maskedSummary {
    final lines = <String>[
      '端点：${useSsl ? 'https' : 'http'}://$endpoint${port == null ? '' : ':$port'}',
      '存储桶：$bucket',
      '区域：$region',
      '路径前缀：$prefix',
      'path-style：${pathStyle ? '开启' : '关闭'}',
    ];
    if (deviceName.isNotEmpty) {
      lines.add('来源设备：$deviceName');
    }
    lines.add('访问凭据：${hasCredentials ? '${_maskKey(accessKey!)}（包含 Secret Key）' : '不包含，导入后需要手动填写'}');
    return lines.join('\n');
  }

  /// 只保留首尾各 2 个字符，其余用星号替换。
  static String _maskKey(String value) {
    final trimmed = value.trim();
    if (trimmed.length <= 4) return '****';
    return '${trimmed.substring(0, 2)}****${trimmed.substring(trimmed.length - 2)}';
  }
}
