import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/cloud_sync_manifest.dart';

/// S3 访问端点（只保留 host / port / 协议，避免把路径带进签名）。
class S3Endpoint {
  final String host;
  final int? port;
  final bool useSsl;

  const S3Endpoint({required this.host, this.port, required this.useSsl});

  /// 解析用户输入：支持 `https://host:port`、`host:port`、`host`。
  static S3Endpoint parse(String raw) {
    final input = raw.trim();
    if (input.isEmpty) {
      throw const CloudSyncException('请填写访问端点');
    }
    final withScheme = input.contains('://') ? input : 'https://$input';
    final uri = Uri.tryParse(withScheme);
    if (uri == null) {
      throw const CloudSyncException('访问端点格式不正确');
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw const CloudSyncException('访问端点只支持 http 或 https');
    }
    if (uri.userInfo.isNotEmpty) {
      throw const CloudSyncException('访问端点中不要包含账号密码');
    }
    if (uri.hasQuery || uri.hasFragment) {
      throw const CloudSyncException('访问端点不要包含查询参数或锚点');
    }
    if (uri.path.isNotEmpty && uri.path != '/') {
      throw const CloudSyncException('访问端点只需填写域名和端口，不要带路径');
    }
    if (uri.host.isEmpty || uri.host.contains(' ')) {
      throw const CloudSyncException('访问端点的域名不合法');
    }
    if (uri.hasPort && (uri.port < 1 || uri.port > 65535)) {
      throw const CloudSyncException('访问端点的端口不合法');
    }
    return S3Endpoint(
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      useSsl: uri.scheme == 'https',
    );
  }

  String get display {
    final scheme = useSsl ? 'https' : 'http';
    return port == null ? '$scheme://$host' : '$scheme://$host:$port';
  }
}

/// S3 访问凭据（仅存 Secure Storage）。
class CloudSyncCredentials {
  final String accessKey;
  final String secretKey;

  const CloudSyncCredentials({
    required this.accessKey,
    required this.secretKey,
  });

  bool get isComplete =>
      accessKey.trim().isNotEmpty && secretKey.trim().isNotEmpty;
}

/// 云同步配置（非敏感，存 SharedPreferences）。
class CloudSyncConfig {
  static const int defaultRetainCount = 5;
  static const int minRetainCount = 1;
  static const int maxRetainCount = 50;
  static const String defaultPrefix = 'aquamarina';

  final String endpoint;
  final int? port;
  final bool useSsl;
  final String region;
  final String bucket;
  final String prefix;
  final bool pathStyle;
  final int retainCount;

  /// 启动 / 回到前台时自动增量同步（默认开启）。
  final bool autoSync;

  /// 自动同步最小间隔（分钟），同时用于前台轮询。
  final int autoSyncIntervalMinutes;

  /// 仅在 Wi-Fi / 以太网下自动同步（移动流量下跳过轮询）。
  final bool wifiOnly;

  /// 自动生成完整检查点（每 7 天或 5000 条变更）。
  final bool autoCheckpoint;

  const CloudSyncConfig({
    required this.endpoint,
    this.port,
    required this.useSsl,
    required this.region,
    required this.bucket,
    required this.prefix,
    required this.pathStyle,
    required this.retainCount,
    this.autoSync = true,
    this.autoSyncIntervalMinutes = 5,
    this.wifiOnly = false,
    this.autoCheckpoint = true,
  });

  bool get isConfigured => endpoint.isNotEmpty && bucket.isNotEmpty;

  /// 后端身份指纹：用于检测 endpoint / bucket / prefix 等是否被切换。
  ///
  /// 不含任何密钥；仅用于在配置切换时清理旧的同步水位与去重记录。
  String get backendIdentity => [
    'v1',
    endpoint.toLowerCase(),
    port?.toString() ?? '',
    useSsl ? '1' : '0',
    region.toLowerCase(),
    bucket.toLowerCase(),
    prefix,
    pathStyle ? '1' : '0',
  ].join('|');

  String get displayEndpoint {
    final scheme = useSsl ? 'https' : 'http';
    return port == null ? '$scheme://$endpoint' : '$scheme://$endpoint:$port';
  }

  /// 从表单输入构造并校验配置。
  static CloudSyncConfig create({
    required String endpointInput,
    required String bucket,
    required String region,
    String prefix = defaultPrefix,
    bool pathStyle = true,
    int retainCount = defaultRetainCount,
    bool autoSync = true,
    int autoSyncIntervalMinutes = 5,
    bool wifiOnly = false,
    bool autoCheckpoint = true,
  }) {
    final parsed = S3Endpoint.parse(endpointInput);
    final bucketName = bucket.trim();
    if (!isValidBucketName(bucketName)) {
      throw const CloudSyncException(
        '存储桶名称不合法：需 3-63 位小写字母/数字/点/短横线，且以字母或数字开头结尾',
      );
    }
    final regionName = region.trim();
    if (regionName.isEmpty ||
        !RegExp(r'^[A-Za-z0-9-]+$').hasMatch(regionName)) {
      throw const CloudSyncException('区域不合法，例如 cn-nb1 / us-east-1 / auto');
    }
    if (retainCount < minRetainCount || retainCount > maxRetainCount) {
      throw const CloudSyncException('保留份数需在 1-50 之间');
    }
    if (autoSyncIntervalMinutes < 1 || autoSyncIntervalMinutes > 60) {
      throw const CloudSyncException('自动同步间隔需在 1-60 分钟之间');
    }
    return CloudSyncConfig(
      endpoint: parsed.host,
      port: parsed.port,
      useSsl: parsed.useSsl,
      region: regionName,
      bucket: bucketName,
      prefix: normalizePrefix(prefix),
      pathStyle: pathStyle,
      retainCount: retainCount,
      autoSync: autoSync,
      autoSyncIntervalMinutes: autoSyncIntervalMinutes,
      wifiOnly: wifiOnly,
      autoCheckpoint: autoCheckpoint,
    );
  }

  /// S3 桶名规则（AWS 标准，Rain/MinIO/R2 均兼容）。
  static bool isValidBucketName(String name) {
    if (name.length < 3 || name.length > 63) return false;
    if (!RegExp(r'^[a-z0-9][a-z0-9.-]*[a-z0-9]$').hasMatch(name)) {
      return false;
    }
    if (name.contains('..')) return false;
    if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(name)) return false;
    return true;
  }

  /// 归一化路径前缀：去掉多余斜杠，并校验每段字符。
  static String normalizePrefix(String raw) {
    final segments = raw
        .trim()
        .replaceAll(RegExp(r'/+'), '/')
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList();
    if (segments.isEmpty) return defaultPrefix;
    for (final segment in segments) {
      if (segment == '.' || segment == '..') {
        throw const CloudSyncException('路径前缀不能包含 . 或 ..');
      }
      if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(segment)) {
        throw const CloudSyncException('路径前缀只能包含字母、数字、点、下划线和短横线');
      }
    }
    return segments.join('/');
  }

  /// 校验设备 ID 只含安全字符，避免对象键被注入。
  static void checkDeviceId(String deviceId) {
    if (!RegExp(r'^[a-fA-F0-9-]{8,64}$').hasMatch(deviceId)) {
      throw const CloudSyncException('设备标识格式异常，请在配置页重置设备标识');
    }
  }

  String devicePrefix(String deviceId) {
    checkDeviceId(deviceId);
    return '$prefix/devices/$deviceId';
  }

  String snapshotKey(String deviceId, String timestamp) =>
      '${devicePrefix(deviceId)}/snapshots/$timestamp.zip';

  String manifestKey(String deviceId) =>
      '${devicePrefix(deviceId)}/manifest.json';

  String stateKey(String deviceId) => '${devicePrefix(deviceId)}/state.json';

  String headKey(String deviceId) => '${devicePrefix(deviceId)}/head.json';

  String metaKey(String deviceId) => '${devicePrefix(deviceId)}/meta.json';

  String get devicesPrefix => '$prefix/devices';

  factory CloudSyncConfig.fromJson(Map<String, dynamic> json) {
    final endpoint = json['endpoint'];
    final port = json['port'];
    final useSsl = json['use_ssl'];
    final region = json['region'];
    final bucket = json['bucket'];
    final prefix = json['prefix'];
    final pathStyle = json['path_style'];
    final retainCount = json['retain_count'];
    if (endpoint is! String ||
        (port != null && port is! int) ||
        useSsl is! bool ||
        region is! String ||
        bucket is! String ||
        prefix is! String ||
        pathStyle is! bool ||
        retainCount is! int) {
      throw const FormatException('云同步配置格式错误');
    }
    return CloudSyncConfig(
      endpoint: endpoint,
      port: port as int?,
      useSsl: useSsl,
      region: region,
      bucket: bucket,
      prefix: prefix,
      pathStyle: pathStyle,
      retainCount: retainCount.clamp(minRetainCount, maxRetainCount),
      autoSync: json['auto_sync'] is bool ? json['auto_sync'] as bool : true,
      autoSyncIntervalMinutes:
          (json['auto_sync_interval_minutes'] as int?)?.clamp(1, 60) ?? 5,
      wifiOnly: json['wifi_only'] is bool ? json['wifi_only'] as bool : false,
      autoCheckpoint: json['auto_checkpoint'] is bool
          ? json['auto_checkpoint'] as bool
          : true,
    );
  }

  Map<String, dynamic> toJson() => {
    'endpoint': endpoint,
    'port': port,
    'use_ssl': useSsl,
    'region': region,
    'bucket': bucket,
    'prefix': prefix,
    'path_style': pathStyle,
    'retain_count': retainCount,
    'auto_sync': autoSync,
    'auto_sync_interval_minutes': autoSyncIntervalMinutes,
    'wifi_only': wifiOnly,
    'auto_checkpoint': autoCheckpoint,
  };

  CloudSyncConfig copyWith({
    String? endpoint,
    int? port,
    bool? useSsl,
    String? region,
    String? bucket,
    String? prefix,
    bool? pathStyle,
    int? retainCount,
    bool? autoSync,
    int? autoSyncIntervalMinutes,
    bool? wifiOnly,
    bool? autoCheckpoint,
  }) {
    return CloudSyncConfig(
      endpoint: endpoint ?? this.endpoint,
      port: port ?? this.port,
      useSsl: useSsl ?? this.useSsl,
      region: region ?? this.region,
      bucket: bucket ?? this.bucket,
      prefix: prefix ?? this.prefix,
      pathStyle: pathStyle ?? this.pathStyle,
      retainCount: retainCount ?? this.retainCount,
      autoSync: autoSync ?? this.autoSync,
      autoSyncIntervalMinutes:
          autoSyncIntervalMinutes ?? this.autoSyncIntervalMinutes,
      wifiOnly: wifiOnly ?? this.wifiOnly,
      autoCheckpoint: autoCheckpoint ?? this.autoCheckpoint,
    );
  }
}

/// 云同步运行时状态（存 SharedPreferences，用于设置页展示）。
class CloudSyncRuntimeState {
  final DateTime? lastSuccessAt;
  final String? lastUploadKey;
  final String? lastRestoredDeviceId;
  final String? lastError;
  final DateTime? lastAutoSyncAt;
  final DateTime? lastGcAt;

  /// 最近一次自动检查点时间与当时的累计变更数。
  final DateTime? lastCheckpointAt;
  final int lastCheckpointOps;
  final DateTime? lastCheckpointAttemptAt;
  final int checkpointConsecutiveFailures;
  final DateTime? checkpointBackoffUntil;

  /// 连续失败次数与退避截止时间（P2-7）。
  final int consecutiveFailures;
  final DateTime? backoffUntil;

  const CloudSyncRuntimeState({
    this.lastSuccessAt,
    this.lastUploadKey,
    this.lastRestoredDeviceId,
    this.lastError,
    this.lastAutoSyncAt,
    this.lastGcAt,
    this.lastCheckpointAt,
    this.lastCheckpointOps = 0,
    this.lastCheckpointAttemptAt,
    this.checkpointConsecutiveFailures = 0,
    this.checkpointBackoffUntil,
    this.consecutiveFailures = 0,
    this.backoffUntil,
  });

  factory CloudSyncRuntimeState.fromJson(Map<String, dynamic> json) {
    final lastSuccess = json['last_success_at'];
    final lastAuto = json['last_auto_sync_at'];
    final lastGc = json['last_gc_at'];
    final lastCheckpoint = json['last_checkpoint_at'];
    final lastCheckpointAttempt = json['last_checkpoint_attempt_at'];
    final checkpointBackoff = json['checkpoint_backoff_until'];
    final backoffUntil = json['backoff_until'];
    return CloudSyncRuntimeState(
      lastSuccessAt: lastSuccess is int
          ? DateTime.fromMillisecondsSinceEpoch(lastSuccess)
          : null,
      lastUploadKey: json['last_upload_key'] as String?,
      lastRestoredDeviceId: json['last_restored_device_id'] as String?,
      lastError: json['last_error'] as String?,
      lastAutoSyncAt: lastAuto is int
          ? DateTime.fromMillisecondsSinceEpoch(lastAuto)
          : null,
      lastGcAt: lastGc is int
          ? DateTime.fromMillisecondsSinceEpoch(lastGc)
          : null,
      lastCheckpointAt: lastCheckpoint is int
          ? DateTime.fromMillisecondsSinceEpoch(lastCheckpoint)
          : null,
      lastCheckpointOps: (json['last_checkpoint_ops'] as int?) ?? 0,
      lastCheckpointAttemptAt: lastCheckpointAttempt is int
          ? DateTime.fromMillisecondsSinceEpoch(lastCheckpointAttempt)
          : null,
      checkpointConsecutiveFailures:
          (json['checkpoint_consecutive_failures'] as int?) ?? 0,
      checkpointBackoffUntil: checkpointBackoff is int
          ? DateTime.fromMillisecondsSinceEpoch(checkpointBackoff)
          : null,
      consecutiveFailures: (json['consecutive_failures'] as int?) ?? 0,
      backoffUntil: backoffUntil is int
          ? DateTime.fromMillisecondsSinceEpoch(backoffUntil)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'last_success_at': lastSuccessAt?.millisecondsSinceEpoch,
    'last_upload_key': lastUploadKey,
    'last_restored_device_id': lastRestoredDeviceId,
    'last_error': lastError,
    'last_auto_sync_at': lastAutoSyncAt?.millisecondsSinceEpoch,
    'last_gc_at': lastGcAt?.millisecondsSinceEpoch,
    'last_checkpoint_at': lastCheckpointAt?.millisecondsSinceEpoch,
    'last_checkpoint_ops': lastCheckpointOps,
    'last_checkpoint_attempt_at':
        lastCheckpointAttemptAt?.millisecondsSinceEpoch,
    'checkpoint_consecutive_failures': checkpointConsecutiveFailures,
    'checkpoint_backoff_until': checkpointBackoffUntil?.millisecondsSinceEpoch,
    'consecutive_failures': consecutiveFailures,
    'backoff_until': backoffUntil?.millisecondsSinceEpoch,
  };

  CloudSyncRuntimeState copyWith({
    DateTime? lastSuccessAt,
    String? lastUploadKey,
    String? lastRestoredDeviceId,
    String? lastError,
    DateTime? lastAutoSyncAt,
    DateTime? lastGcAt,
    DateTime? lastCheckpointAt,
    int? lastCheckpointOps,
    DateTime? lastCheckpointAttemptAt,
    int? checkpointConsecutiveFailures,
    DateTime? checkpointBackoffUntil,
    int? consecutiveFailures,
    DateTime? backoffUntil,
    bool clearBackoff = false,
    bool clearCheckpoint = false,
    bool clearCheckpointBackoff = false,
    bool clearError = false,
  }) {
    return CloudSyncRuntimeState(
      lastSuccessAt: lastSuccessAt ?? this.lastSuccessAt,
      lastUploadKey: lastUploadKey ?? this.lastUploadKey,
      lastRestoredDeviceId: lastRestoredDeviceId ?? this.lastRestoredDeviceId,
      lastError: clearError ? null : (lastError ?? this.lastError),
      lastAutoSyncAt: lastAutoSyncAt ?? this.lastAutoSyncAt,
      lastGcAt: lastGcAt ?? this.lastGcAt,
      lastCheckpointAt: clearCheckpoint
          ? null
          : (lastCheckpointAt ?? this.lastCheckpointAt),
      lastCheckpointOps: clearCheckpoint
          ? 0
          : (lastCheckpointOps ?? this.lastCheckpointOps),
      lastCheckpointAttemptAt: clearCheckpoint
          ? null
          : (lastCheckpointAttemptAt ?? this.lastCheckpointAttemptAt),
      checkpointConsecutiveFailures: clearCheckpoint
          ? 0
          : (checkpointConsecutiveFailures ??
                this.checkpointConsecutiveFailures),
      checkpointBackoffUntil: (clearCheckpoint || clearCheckpointBackoff)
          ? null
          : (checkpointBackoffUntil ?? this.checkpointBackoffUntil),
      consecutiveFailures: consecutiveFailures ?? this.consecutiveFailures,
      backoffUntil: clearBackoff ? null : (backoffUntil ?? this.backoffUntil),
    );
  }
}

/// 云同步配置的持久化入口。
///
/// - 非敏感配置 → SharedPreferences（单个 JSON，写入原子）；
/// - AK/SK → FlutterSecureStorage；
/// - 设备 ID 与配置解耦：清除云同步配置不会改变本机在云端的身份。
class CloudSyncSettings {
  CloudSyncSettings._();

  static const String _configKey = 'cloud_sync_config_v1';
  static const String _stateKey = 'cloud_sync_state_v1';
  static const String _deviceIdKey = 'cloud_sync_device_id_v1';
  static const String _deviceNameKey = 'cloud_sync_device_name_v1';

  /// 已重置的旧设备 ID：本机不再把它们当作远端设备拉取。
  static const String _ignoredDeviceIdsKey = 'cloud_sync_ignored_devices_v1';
  static const String accessKeyStorageKey = 'cloud_sync_access_key';
  static const String secretKeyStorageKey = 'cloud_sync_secret_key';

  static const FlutterSecureStorage _secure = FlutterSecureStorage();

  static Future<CloudSyncConfig?> loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_configKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return CloudSyncConfig.fromJson(decoded.cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveConfig(CloudSyncConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_configKey, jsonEncode(config.toJson()));
  }

  static Future<CloudSyncCredentials?> loadCredentials() async {
    try {
      final accessKey = await _secure.read(key: accessKeyStorageKey) ?? '';
      final secretKey = await _secure.read(key: secretKeyStorageKey) ?? '';
      if (accessKey.isEmpty && secretKey.isEmpty) return null;
      return CloudSyncCredentials(accessKey: accessKey, secretKey: secretKey);
    } catch (_) {
      return null;
    }
  }

  /// 保存凭据；传入空串表示删除对应项。
  static Future<void> saveCredentials(CloudSyncCredentials credentials) async {
    final accessKey = credentials.accessKey.trim();
    final secretKey = credentials.secretKey.trim();
    if (accessKey.isEmpty) {
      await _secure.delete(key: accessKeyStorageKey);
    } else {
      await _secure.write(key: accessKeyStorageKey, value: accessKey);
    }
    if (secretKey.isEmpty) {
      await _secure.delete(key: secretKeyStorageKey);
    } else {
      await _secure.write(key: secretKeyStorageKey, value: secretKey);
    }
  }

  static Future<void> clearCredentials() async {
    try {
      await _secure.delete(key: accessKeyStorageKey);
      await _secure.delete(key: secretKeyStorageKey);
    } catch (_) {
      // 安全存储不可用时忽略：调用方会在后续连接测试中感知
    }
  }

  /// 读取本机设备标识；不存在时生成 UUID v4 并持久化。
  static Future<String> getOrCreateDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_deviceIdKey);
    if (existing != null &&
        RegExp(r'^[a-fA-F0-9-]{8,64}$').hasMatch(existing)) {
      return existing;
    }
    final id = const Uuid().v4();
    await prefs.setString(_deviceIdKey, id);
    return id;
  }

  /// 重新生成设备标识（危险操作：云端会视为一台新设备）。
  ///
  /// 旧设备目录不会被删除；把它记入 ignored 列表，避免本机在后续同步中
  /// 把旧目录当成“其它设备”重放，造成计数类字段翻倍。
  static Future<String> resetDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final previous = prefs.getString(_deviceIdKey);
    if (previous != null &&
        previous.isNotEmpty &&
        RegExp(r'^[a-fA-F0-9-]{8,64}$').hasMatch(previous)) {
      final ignored = (prefs.getStringList(_ignoredDeviceIdsKey) ?? []).toList(
        growable: true,
      );
      if (!ignored.contains(previous)) {
        ignored.add(previous);
        await prefs.setStringList(_ignoredDeviceIdsKey, ignored);
      }
    }
    final id = const Uuid().v4();
    await prefs.setString(_deviceIdKey, id);
    await prefs.remove(_deviceNameKey);
    return id;
  }

  /// 本机已重置/忽略的旧设备 ID（不参与拉取）。
  static Future<Set<String>> loadIgnoredDeviceIds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return (prefs.getStringList(_ignoredDeviceIdsKey) ?? const [])
          .where((id) => id.isNotEmpty)
          .toSet();
    } catch (_) {
      // 设置存储不可用时退化为空集合，不影响正常同步。
      return <String>{};
    }
  }

  static Future<String> getOrCreateDeviceName(String deviceId) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_deviceNameKey);
    if (existing != null && existing.trim().isNotEmpty) {
      return existing.trim();
    }
    final name = _defaultDeviceName(deviceId);
    await prefs.setString(_deviceNameKey, name);
    return name;
  }

  static Future<void> saveDeviceName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      await prefs.remove(_deviceNameKey);
    } else {
      await prefs.setString(_deviceNameKey, trimmed);
    }
  }

  static String _defaultDeviceName(String deviceId) {
    final String platform;
    if (Platform.isAndroid) {
      platform = 'Android';
    } else if (Platform.isIOS) {
      platform = 'iOS';
    } else if (Platform.isWindows) {
      platform = 'Windows';
    } else if (Platform.isMacOS) {
      platform = 'macOS';
    } else if (Platform.isLinux) {
      platform = 'Linux';
    } else {
      platform = Platform.operatingSystem;
    }
    final suffix = deviceId.length >= 4 ? deviceId.substring(0, 4) : deviceId;
    String host = '';
    try {
      host = Platform.localHostname.trim();
    } catch (_) {}
    if (host.isEmpty || host == 'localhost' || host.length > 32) {
      return '$platform-$suffix';
    }
    return '$platform-$suffix ($host)';
  }

  static Future<CloudSyncRuntimeState> loadState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_stateKey);
      if (raw == null || raw.isEmpty) {
        return const CloudSyncRuntimeState();
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const CloudSyncRuntimeState();
      return CloudSyncRuntimeState.fromJson(decoded.cast<String, dynamic>());
    } catch (_) {
      // 设置存储不可用或内容损坏时退化为默认状态。
      return const CloudSyncRuntimeState();
    }
  }

  static Future<void> saveState(CloudSyncRuntimeState state) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_stateKey, jsonEncode(state.toJson()));
  }

  /// 串行化运行时状态的「读取 → 修改 → 写回」。
  ///
  /// 自动同步、事件同步、检查点与手动同步都会更新同一个 JSON 状态。
  /// 若各自 `loadState` 后再 `saveState`，后写入者会覆盖先写入者的字段
  /// （例如失败计数 / 退避时间 / 上次检查点）。所有读改写都必须走这里。
  static Future<CloudSyncRuntimeState> updateState(
    CloudSyncRuntimeState Function(CloudSyncRuntimeState current) update,
  ) {
    final completer = Completer<CloudSyncRuntimeState>();
    _stateMutationQueue = _stateMutationQueue.then((_) async {
      try {
        final current = await loadState();
        final next = update(current);
        await saveState(next);
        if (!completer.isCompleted) completer.complete(next);
      } catch (e, stackTrace) {
        if (!completer.isCompleted) completer.completeError(e, stackTrace);
      }
    });
    return completer.future;
  }

  static Future<void> _stateMutationQueue = Future<void>.value();

  /// 配置与凭据是否齐全（纯函数，便于 UI / 测试复用）。
  static bool isCompleteConfiguration(
    CloudSyncConfig? config,
    CloudSyncCredentials? credentials,
  ) {
    return config != null &&
        config.isConfigured &&
        (credentials?.isComplete ?? false);
  }

  /// 本机是否已具备完整云同步配置。
  ///
  /// 该判断用于决定是否必须开启 SQLite 变更捕获：只要配置完整，
  /// 任何业务写入都应进入 oplog，避免恢复快照后到首次同步之间丢变更。
  static Future<bool> hasCompleteConfiguration() async {
    final config = await loadConfig();
    if (config == null || !config.isConfigured) return false;
    final credentials = await loadCredentials();
    return isCompleteConfiguration(config, credentials);
  }

  /// 清除云同步配置、凭据与状态（保留设备 ID）。
  static Future<void> clearAll() async {
    // 等待排队中的状态写入完成，避免清除后又被旧状态写回。
    await _stateMutationQueue;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_configKey);
    await prefs.remove(_stateKey);
    await prefs.remove(_deviceNameKey);
    await clearCredentials();
  }
}
