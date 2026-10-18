import 'dart:convert';
import 'dart:typed_data';

import 'sync_op.dart';

/// 读取云端设备对象（meta / head / state）的结果状态。
///
/// 关键区别：
/// - [missing]：对象不存在，通常是旧版本从未写过；
/// - [newerFormat]：对象格式版本高于本机，不能当成“不存在”静默忽略；
/// - [corrupted]：内容损坏；
/// - [error]：网络 / 权限等临时错误。
enum CloudDeviceReadStatus { ok, missing, corrupted, newerFormat, error }

/// 带状态的对象读取结果。
class CloudDeviceReadResult<T> {
  final CloudDeviceReadStatus status;
  final T? value;
  final int? remoteFormatVersion;
  final Object? error;

  const CloudDeviceReadResult({
    required this.status,
    this.value,
    this.remoteFormatVersion,
    this.error,
  });

  const CloudDeviceReadResult.ok(this.value, {this.remoteFormatVersion})
    : status = CloudDeviceReadStatus.ok,
      error = null;

  const CloudDeviceReadResult.missing()
    : status = CloudDeviceReadStatus.missing,
      value = null,
      remoteFormatVersion = null,
      error = null;

  const CloudDeviceReadResult.corrupted(this.error, {this.remoteFormatVersion})
    : status = CloudDeviceReadStatus.corrupted,
      value = null;

  const CloudDeviceReadResult.newerFormat({this.remoteFormatVersion})
    : status = CloudDeviceReadStatus.newerFormat,
      value = null,
      error = null;

  const CloudDeviceReadResult.error(this.error)
    : status = CloudDeviceReadStatus.error,
      value = null,
      remoteFormatVersion = null;

  bool get isOk => status == CloudDeviceReadStatus.ok;
  bool get isMissing => status == CloudDeviceReadStatus.missing;
  bool get isNewerFormat => status == CloudDeviceReadStatus.newerFormat;
  bool get isCorrupted => status == CloudDeviceReadStatus.corrupted;
  bool get isError => status == CloudDeviceReadStatus.error;
}

/// `meta.json` 的发布结果。
enum CloudMetaPublishOutcome {
  written,
  unchanged,
  skippedNewerFormat,
  skippedNewerSchema,
  failed,
}

/// `ensureMeta` 的完整结果，供版本门禁判断“本机是否被降级覆盖”。
class CloudMetaPublishResult {
  final CloudMetaPublishOutcome outcome;
  final CloudDeviceReadStatus remoteStatus;
  final CloudDeviceMeta? remoteMeta;
  final int? remoteFormatVersion;

  const CloudMetaPublishResult({
    required this.outcome,
    required this.remoteStatus,
    this.remoteMeta,
    this.remoteFormatVersion,
  });

  bool get skippedByRemote =>
      outcome == CloudMetaPublishOutcome.skippedNewerFormat ||
      outcome == CloudMetaPublishOutcome.skippedNewerSchema;
}

String? _optionalString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) {
    throw FormatException('字段 $key 类型错误');
  }
  return value;
}

int? _optionalPositiveInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! int || value < 1) {
    throw FormatException('字段 $key 类型错误');
  }
  return value;
}

/// 单台设备的增量同步水位（`devices/{deviceId}/head.json`）。
///
/// 其它设备拉取前先读该对象：如果 `latest_hlc` 没有超过本地已应用水位，
/// 就完全跳过对 `chunks/` 的 LIST，避免每次同步都扫描云端全部对象。
class CloudDeviceHead {
  static const int currentFormatVersion = 1;

  final int formatVersion;
  final String deviceId;
  final String deviceName;

  /// 最近一次上传的 chunk 对象键。
  final String latestChunkKey;

  /// 最近一个 chunk 的起始 HLC（固定 16+8 位十六进制）。
  final String latestHlc;

  /// 该设备累计上传的 chunk 数量（仅用于展示 / 诊断）。
  final int chunkCount;

  /// 写入该 head 的设备版本信息。
  ///
  /// 旧版本写出的 head 没有这些字段（为 null），读取方应视为“未知”，
  /// 不能据此阻断同步。
  final String? appVersion;
  final int? schemaVersion;
  final int? syncProtocolVersion;

  final DateTime updatedAt;

  const CloudDeviceHead({
    this.formatVersion = currentFormatVersion,
    required this.deviceId,
    required this.deviceName,
    required this.latestChunkKey,
    required this.latestHlc,
    required this.chunkCount,
    this.appVersion,
    this.schemaVersion,
    this.syncProtocolVersion,
    required this.updatedAt,
  });

  factory CloudDeviceHead.fromJson(Map<String, dynamic> json) =>
      CloudDeviceHead._fromJson(json, allowNewer: false);

  factory CloudDeviceHead._fromJson(
    Map<String, dynamic> json, {
    required bool allowNewer,
  }) {
    final formatVersion = json['format_version'];
    if (formatVersion is! int || formatVersion < 1) {
      throw const FormatException('设备 head 缺少有效的 format_version');
    }
    if (!allowNewer && formatVersion > currentFormatVersion) {
      throw FormatException('设备 head 格式版本过新（$formatVersion），请先升级应用');
    }
    final deviceId = json['device_id'];
    final deviceName = json['device_name'];
    final latestChunkKey = json['latest_chunk_key'];
    final latestHlc = json['latest_hlc'];
    final chunkCount = json['chunk_count'];
    final updatedAt = json['updated_at'];
    if (deviceId is! String ||
        deviceId.isEmpty ||
        deviceName is! String ||
        latestChunkKey is! String ||
        latestChunkKey.isEmpty ||
        latestHlc is! String ||
        latestHlc.isEmpty ||
        chunkCount is! int ||
        chunkCount < 0 ||
        updatedAt is! String) {
      throw const FormatException('设备 head 字段缺失或格式错误');
    }
    SyncHlc.parse(latestHlc);
    return CloudDeviceHead(
      formatVersion: formatVersion,
      deviceId: deviceId,
      deviceName: deviceName,
      latestChunkKey: latestChunkKey,
      latestHlc: latestHlc,
      chunkCount: chunkCount,
      appVersion: _optionalString(json, 'app_version'),
      schemaVersion: _optionalPositiveInt(json, 'schema_version'),
      syncProtocolVersion: _optionalPositiveInt(json, 'sync_protocol_version'),
      updatedAt: DateTime.parse(updatedAt),
    );
  }

  Map<String, dynamic> toJson() => {
    'format_version': formatVersion,
    'device_id': deviceId,
    'device_name': deviceName,
    'latest_chunk_key': latestChunkKey,
    'latest_hlc': latestHlc,
    'chunk_count': chunkCount,
    if (appVersion != null) 'app_version': appVersion,
    if (schemaVersion != null) 'schema_version': schemaVersion,
    if (syncProtocolVersion != null)
      'sync_protocol_version': syncProtocolVersion,
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };

  CloudDeviceHead copyWith({
    String? deviceName,
    String? latestChunkKey,
    String? latestHlc,
    int? chunkCount,
    String? appVersion,
    int? schemaVersion,
    int? syncProtocolVersion,
    DateTime? updatedAt,
  }) {
    return CloudDeviceHead(
      formatVersion: formatVersion,
      deviceId: deviceId,
      deviceName: deviceName ?? this.deviceName,
      latestChunkKey: latestChunkKey ?? this.latestChunkKey,
      latestHlc: latestHlc ?? this.latestHlc,
      chunkCount: chunkCount ?? this.chunkCount,
      appVersion: appVersion ?? this.appVersion,
      schemaVersion: schemaVersion ?? this.schemaVersion,
      syncProtocolVersion: syncProtocolVersion ?? this.syncProtocolVersion,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

/// 单台设备已应用到其它设备的水位（`devices/{deviceId}/state.json`）。
///
/// `applied[sourceDeviceId]` 表示：来自该来源设备、起始 HLC 小于等于该值的
/// chunk 已经全部完整应用。GC 只有确认所有活跃设备都越过某个 chunk 后才会删除它。
class CloudDeviceState {
  static const int currentFormatVersion = 1;

  final int formatVersion;
  final String deviceId;
  final String deviceName;

  /// 来源设备 ID → 已完整应用的最大 chunk 起始 HLC。
  final Map<String, String> applied;

  final DateTime updatedAt;

  const CloudDeviceState({
    this.formatVersion = currentFormatVersion,
    required this.deviceId,
    required this.deviceName,
    required this.applied,
    required this.updatedAt,
  });

  factory CloudDeviceState.fromJson(Map<String, dynamic> json) =>
      CloudDeviceState._fromJson(json, allowNewer: false);

  factory CloudDeviceState._fromJson(
    Map<String, dynamic> json, {
    required bool allowNewer,
  }) {
    final formatVersion = json['format_version'];
    if (formatVersion is! int || formatVersion < 1) {
      throw const FormatException('设备 state 缺少有效的 format_version');
    }
    if (!allowNewer && formatVersion > currentFormatVersion) {
      throw FormatException('设备 state 格式版本过新（$formatVersion），请先升级应用');
    }
    final deviceId = json['device_id'];
    final deviceName = json['device_name'];
    final rawApplied = json['applied'];
    final updatedAt = json['updated_at'];
    if (deviceId is! String ||
        deviceId.isEmpty ||
        deviceName is! String ||
        rawApplied is! Map ||
        updatedAt is! String) {
      throw const FormatException('设备 state 字段缺失或格式错误');
    }
    final applied = <String, String>{};
    for (final entry in rawApplied.entries) {
      final sourceId = entry.key.toString();
      final value = entry.value;
      if (sourceId.isEmpty || value is! String || value.isEmpty) {
        throw const FormatException('设备 state.applied 条目格式错误');
      }
      SyncHlc.parse(value);
      applied[sourceId] = value;
    }
    return CloudDeviceState(
      formatVersion: formatVersion,
      deviceId: deviceId,
      deviceName: deviceName,
      applied: Map.unmodifiable(applied),
      updatedAt: DateTime.parse(updatedAt),
    );
  }

  Map<String, dynamic> toJson() => {
    'format_version': formatVersion,
    'device_id': deviceId,
    'device_name': deviceName,
    'applied': applied,
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };

  /// 读取来源设备的水位；没有记录时返回 null。
  SyncHlc? appliedFor(String sourceDeviceId) {
    final raw = applied[sourceDeviceId];
    if (raw == null || raw.isEmpty) return null;
    try {
      return SyncHlc.parse(raw);
    } on FormatException {
      return null;
    }
  }

  /// 合并一条水位：只保留更大的 HLC。
  CloudDeviceState withApplied(String sourceDeviceId, String hlc) {
    final merged = Map<String, String>.of(applied);
    final existing = merged[sourceDeviceId];
    if (existing == null || existing.isEmpty) {
      merged[sourceDeviceId] = hlc;
    } else {
      try {
        if (SyncHlc.parse(hlc).compareTo(SyncHlc.parse(existing)) > 0) {
          merged[sourceDeviceId] = hlc;
        }
      } on FormatException {
        merged[sourceDeviceId] = hlc;
      }
    }
    return CloudDeviceState(
      formatVersion: formatVersion,
      deviceId: deviceId,
      deviceName: deviceName,
      applied: Map.unmodifiable(merged),
      updatedAt: DateTime.now(),
    );
  }

  CloudDeviceState copyWith({
    String? deviceName,
    Map<String, String>? applied,
    DateTime? updatedAt,
  }) {
    return CloudDeviceState(
      formatVersion: formatVersion,
      deviceId: deviceId,
      deviceName: deviceName ?? this.deviceName,
      applied: applied ?? this.applied,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

/// 设备静态信息（`devices/{deviceId}/meta.json`）。
///
/// 只做增量同步、从未上传过快照的设备没有 `manifest.json`；设备页需要
/// 该对象来展示名称与平台，避免显示成「未知设备」。
class CloudDeviceMeta {
  static const int currentFormatVersion = 1;

  final int formatVersion;
  final String deviceId;
  final String deviceName;
  final String platform;
  final int schemaVersion;

  /// 写入 meta 的设备 App 版本（如 `1.4.1+24`）。
  ///
  /// 旧版本写出的 meta 没有该字段，读取方必须按“未知版本”处理。
  final String? appVersion;

  /// 设备写入时使用的同步协议版本（`SyncOp.currentVersion`）。
  final int? syncProtocolVersion;

  final DateTime lastSeen;

  const CloudDeviceMeta({
    this.formatVersion = currentFormatVersion,
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    required this.schemaVersion,
    this.appVersion,
    this.syncProtocolVersion,
    required this.lastSeen,
  });

  factory CloudDeviceMeta.fromJson(Map<String, dynamic> json) =>
      CloudDeviceMeta._fromJson(json, allowNewer: false);

  factory CloudDeviceMeta._fromJson(
    Map<String, dynamic> json, {
    required bool allowNewer,
  }) {
    final formatVersion = json['format_version'];
    final deviceId = json['device_id'];
    final deviceName = json['device_name'];
    final platform = json['platform'];
    final schemaVersion = json['schema_version'];
    final lastSeen = json['last_seen'];
    if (formatVersion is! int ||
        formatVersion < 1 ||
        (!allowNewer && formatVersion > currentFormatVersion) ||
        deviceId is! String ||
        deviceId.isEmpty ||
        deviceName is! String ||
        deviceName.isEmpty ||
        platform is! String ||
        schemaVersion is! int ||
        schemaVersion < 0 ||
        lastSeen is! String) {
      throw const FormatException('设备 meta 字段缺失或格式错误');
    }
    return CloudDeviceMeta(
      formatVersion: formatVersion,
      deviceId: deviceId,
      deviceName: deviceName,
      platform: platform,
      schemaVersion: schemaVersion,
      appVersion: _optionalString(json, 'app_version'),
      syncProtocolVersion: _optionalPositiveInt(json, 'sync_protocol_version'),
      lastSeen: DateTime.parse(lastSeen),
    );
  }

  Map<String, dynamic> toJson() => {
    'format_version': formatVersion,
    'device_id': deviceId,
    'device_name': deviceName,
    'platform': platform,
    'schema_version': schemaVersion,
    if (appVersion != null) 'app_version': appVersion,
    if (syncProtocolVersion != null)
      'sync_protocol_version': syncProtocolVersion,
    'last_seen': lastSeen.toUtc().toIso8601String(),
  };
}

/// head / state / meta 的 JSON 编解码工具。
///
/// `parseXxx` 保持严格语义（格式过新抛异常）；`decodeXxx` 返回带状态的结果，
/// 供同步门禁区分“不存在 / 损坏 / 格式过新 / 网络错误”。
class CloudDeviceMetaCodec {
  CloudDeviceMetaCodec._();

  static CloudDeviceHead parseHead(List<int> bytes) {
    final result = decodeHead(bytes);
    if (result.isOk && result.value != null) return result.value!;
    throw FormatException(
      result.error?.toString() ??
          '设备 head 格式版本过新（${result.remoteFormatVersion}），请先升级应用',
    );
  }

  static CloudDeviceReadResult<CloudDeviceHead> decodeHead(List<int> bytes) {
    return _decode(
      bytes,
      (json, {required allowNewer}) =>
          CloudDeviceHead._fromJson(json, allowNewer: allowNewer),
      currentFormatVersion: CloudDeviceHead.currentFormatVersion,
      label: '设备 head',
    );
  }

  static Uint8List encodeHead(CloudDeviceHead head) =>
      Uint8List.fromList(utf8.encode(jsonEncode(head.toJson())));

  static CloudDeviceState parseState(List<int> bytes) {
    final result = decodeState(bytes);
    if (result.isOk && result.value != null) return result.value!;
    throw FormatException(
      result.error?.toString() ??
          '设备 state 格式版本过新（${result.remoteFormatVersion}），请先升级应用',
    );
  }

  static CloudDeviceReadResult<CloudDeviceState> decodeState(List<int> bytes) {
    return _decode(
      bytes,
      (json, {required allowNewer}) =>
          CloudDeviceState._fromJson(json, allowNewer: allowNewer),
      currentFormatVersion: CloudDeviceState.currentFormatVersion,
      label: '设备 state',
    );
  }

  static Uint8List encodeState(CloudDeviceState state) =>
      Uint8List.fromList(utf8.encode(jsonEncode(state.toJson())));

  static CloudDeviceMeta parseMeta(List<int> bytes) {
    final result = decodeMeta(bytes);
    if (result.isOk && result.value != null) return result.value!;
    throw FormatException(
      result.error?.toString() ??
          '设备 meta 格式版本过新（${result.remoteFormatVersion}），请先升级应用',
    );
  }

  static CloudDeviceReadResult<CloudDeviceMeta> decodeMeta(List<int> bytes) {
    return _decode(
      bytes,
      (json, {required allowNewer}) =>
          CloudDeviceMeta._fromJson(json, allowNewer: allowNewer),
      currentFormatVersion: CloudDeviceMeta.currentFormatVersion,
      label: '设备 meta',
    );
  }

  static Uint8List encodeMeta(CloudDeviceMeta meta) =>
      Uint8List.fromList(utf8.encode(jsonEncode(meta.toJson())));

  static CloudDeviceReadResult<T> _decode<T>(
    List<int> bytes,
    T Function(Map<String, dynamic> json, {required bool allowNewer}) parser, {
    required int currentFormatVersion,
    required String label,
  }) {
    final Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) {
        return CloudDeviceReadResult<T>.corrupted(
          FormatException('$label JSON 顶层不是对象'),
        );
      }
      json = decoded.cast<String, dynamic>();
    } catch (e) {
      return CloudDeviceReadResult<T>.corrupted(e);
    }

    final format = json['format_version'];
    if (format is! int || format < 1) {
      return CloudDeviceReadResult<T>.corrupted(
        FormatException('$label 缺少有效的 format_version'),
      );
    }
    if (format > currentFormatVersion) {
      try {
        final value = parser(json, allowNewer: true);
        return CloudDeviceReadResult<T>(
          status: CloudDeviceReadStatus.newerFormat,
          value: value,
          remoteFormatVersion: format,
        );
      } catch (e) {
        return CloudDeviceReadResult<T>.newerFormat(
          remoteFormatVersion: format,
        );
      }
    }
    try {
      final value = parser(json, allowNewer: false);
      return CloudDeviceReadResult<T>.ok(value, remoteFormatVersion: format);
    } catch (e) {
      return CloudDeviceReadResult<T>.corrupted(e, remoteFormatVersion: format);
    }
  }
}
