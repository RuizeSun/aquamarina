import 'dart:convert';
import 'dart:typed_data';

import 'sync_op.dart';

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

  final DateTime updatedAt;

  const CloudDeviceHead({
    this.formatVersion = currentFormatVersion,
    required this.deviceId,
    required this.deviceName,
    required this.latestChunkKey,
    required this.latestHlc,
    required this.chunkCount,
    required this.updatedAt,
  });

  factory CloudDeviceHead.fromJson(Map<String, dynamic> json) {
    final formatVersion = json['format_version'];
    if (formatVersion is! int || formatVersion < 1) {
      throw const FormatException('设备 head 缺少有效的 format_version');
    }
    if (formatVersion > currentFormatVersion) {
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
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };

  CloudDeviceHead copyWith({
    String? deviceName,
    String? latestChunkKey,
    String? latestHlc,
    int? chunkCount,
    DateTime? updatedAt,
  }) {
    return CloudDeviceHead(
      formatVersion: formatVersion,
      deviceId: deviceId,
      deviceName: deviceName ?? this.deviceName,
      latestChunkKey: latestChunkKey ?? this.latestChunkKey,
      latestHlc: latestHlc ?? this.latestHlc,
      chunkCount: chunkCount ?? this.chunkCount,
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

  factory CloudDeviceState.fromJson(Map<String, dynamic> json) {
    final formatVersion = json['format_version'];
    if (formatVersion is! int || formatVersion < 1) {
      throw const FormatException('设备 state 缺少有效的 format_version');
    }
    if (formatVersion > currentFormatVersion) {
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
  final DateTime lastSeen;

  const CloudDeviceMeta({
    this.formatVersion = currentFormatVersion,
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    required this.schemaVersion,
    required this.lastSeen,
  });

  factory CloudDeviceMeta.fromJson(Map<String, dynamic> json) {
    final formatVersion = json['format_version'];
    final deviceId = json['device_id'];
    final deviceName = json['device_name'];
    final platform = json['platform'];
    final schemaVersion = json['schema_version'];
    final lastSeen = json['last_seen'];
    if (formatVersion is! int ||
        formatVersion < 1 ||
        formatVersion > currentFormatVersion ||
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
      lastSeen: DateTime.parse(lastSeen),
    );
  }

  Map<String, dynamic> toJson() => {
    'format_version': formatVersion,
    'device_id': deviceId,
    'device_name': deviceName,
    'platform': platform,
    'schema_version': schemaVersion,
    'last_seen': lastSeen.toUtc().toIso8601String(),
  };
}

/// head / state / meta 的 JSON 编解码工具。
class CloudDeviceMetaCodec {
  CloudDeviceMetaCodec._();

  static CloudDeviceHead parseHead(List<int> bytes) {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) {
      throw const FormatException('设备 head JSON 顶层不是对象');
    }
    return CloudDeviceHead.fromJson(decoded.cast<String, dynamic>());
  }

  static Uint8List encodeHead(CloudDeviceHead head) =>
      Uint8List.fromList(utf8.encode(jsonEncode(head.toJson())));

  static CloudDeviceState parseState(List<int> bytes) {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) {
      throw const FormatException('设备 state JSON 顶层不是对象');
    }
    return CloudDeviceState.fromJson(decoded.cast<String, dynamic>());
  }

  static Uint8List encodeState(CloudDeviceState state) =>
      Uint8List.fromList(utf8.encode(jsonEncode(state.toJson())));

  static CloudDeviceMeta parseMeta(List<int> bytes) {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) {
      throw const FormatException('设备 meta JSON 顶层不是对象');
    }
    return CloudDeviceMeta.fromJson(decoded.cast<String, dynamic>());
  }

  static Uint8List encodeMeta(CloudDeviceMeta meta) =>
      Uint8List.fromList(utf8.encode(jsonEncode(meta.toJson())));
}
