import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// 云端同步相关的纯数据模型与工具。
///
/// 这里刻意不依赖 Flutter / path_provider / secure storage，
/// 便于在单元测试中直接验证序列化、版本校验、对象键与哈希逻辑。

/// 云端同步异常（带用户可读中文消息）。
class CloudSyncException implements Exception {
  final String message;

  const CloudSyncException(this.message);

  @override
  String toString() => message;
}

/// 用户主动取消同步 / 快照操作。
///
/// 与普通失败区分开：调用方不应把它展示为错误，也不能因此进入失败退避。
class CloudSyncCancelledException implements Exception {
  final String message;

  const CloudSyncCancelledException([this.message = '操作已取消']);

  @override
  String toString() => message;
}

/// 云端数据由更新版本创建，本机无法安全读取。
///
/// 与普通 [CloudSyncException] 区分：自动同步遇到它应进入“版本阻断”状态，
/// 而不是按网络失败做指数退避。
class CloudSyncIncompatibleException extends FormatException {
  final int? remoteFormatVersion;
  final int? requiredSchemaVersion;
  final int? requiredProtocolVersion;

  const CloudSyncIncompatibleException(
    super.message, {
    this.remoteFormatVersion,
    this.requiredSchemaVersion,
    this.requiredProtocolVersion,
  });

  @override
  String toString() => message;
}

/// 云端快照元信息。
class CloudSnapshotInfo {
  final String key;
  final int size;
  final String sha256;
  final DateTime createdAt;

  /// 该快照是否包含 AI API Key（默认导出不含）。
  final bool containsApiKeys;

  const CloudSnapshotInfo({
    required this.key,
    required this.size,
    required this.sha256,
    required this.createdAt,
    required this.containsApiKeys,
  });

  factory CloudSnapshotInfo.fromJson(Map<String, dynamic> json) {
    final key = json['key'];
    final size = json['size'];
    final sha = json['sha256'];
    final createdAt = json['created_at'];
    final contains = json['contains_api_keys'];
    if (key is! String ||
        key.isEmpty ||
        size is! int ||
        size < 0 ||
        sha is! String ||
        sha.length != 64 ||
        createdAt is! String ||
        contains is! bool) {
      throw const FormatException('快照元信息字段缺失或格式错误');
    }
    return CloudSnapshotInfo(
      key: key,
      size: size,
      sha256: sha,
      createdAt: DateTime.parse(createdAt),
      containsApiKeys: contains,
    );
  }

  Map<String, dynamic> toJson() => {
    'key': key,
    'size': size,
    'sha256': sha256,
    'created_at': createdAt.toUtc().toIso8601String(),
    'contains_api_keys': containsApiKeys,
  };
}

/// 单台设备的云端备份清单（快照索引）。
///
/// `snapshots` 按创建时间倒序，第一个即最新快照。
class CloudDeviceManifest {
  /// 当前支持的清单格式版本。
  static const int currentFormatVersion = 1;

  final int formatVersion;
  final String deviceId;
  final String deviceName;
  final int schemaVersion;
  final String appVersion;

  /// 读取这份数据所需的最低数据库 schema / 同步协议版本。
  ///
  /// 旧清单没有这两个字段（为 null）。写入时只增不减，避免旧设备把
  /// 新版本要求降回去。
  final int? minSchemaVersion;
  final int? minProtocolVersion;

  final DateTime updatedAt;
  final List<CloudSnapshotInfo> snapshots;

  /// 已经把本机数据合并进该数据集的设备 ID。
  ///
  /// 用于判断合并后是否还需要生成新的 datasetId：
  /// - 本机已在列表中：历史数据已经包含在云端快照里，合并后只需更新本机；
  /// - 本机不在列表中：首次贡献数据，需要上传新快照并更换 datasetId，
  ///   让其它设备合并这份新数据。
  ///
  /// 旧版清单没有该字段，读取时为空；调用方可用
  /// [CloudSyncUtils.snapshotContributorIds] 从快照 key 反推上传者。
  final List<String> contributors;

  const CloudDeviceManifest({
    this.formatVersion = currentFormatVersion,
    required this.deviceId,
    required this.deviceName,
    required this.schemaVersion,
    required this.appVersion,
    this.minSchemaVersion,
    this.minProtocolVersion,
    required this.updatedAt,
    required this.snapshots,
    this.contributors = const [],
  });

  CloudSnapshotInfo? get latest => snapshots.isEmpty ? null : snapshots.first;

  factory CloudDeviceManifest.fromJson(Map<String, dynamic> json) {
    final formatVersion = json['format_version'];
    if (formatVersion is! int) {
      throw const FormatException('清单缺少 format_version');
    }
    if (formatVersion > currentFormatVersion) {
      throw CloudSyncIncompatibleException(
        '云端备份格式版本过新（$formatVersion），请先升级应用',
        remoteFormatVersion: formatVersion,
      );
    }
    if (formatVersion < 1) {
      throw const FormatException('云端备份格式版本无效');
    }

    final deviceId = json['device_id'];
    final deviceName = json['device_name'];
    final schemaVersion = json['schema_version'];
    final appVersion = json['app_version'];
    final updatedAt = json['updated_at'];
    if (deviceId is! String ||
        deviceId.isEmpty ||
        deviceName is! String ||
        schemaVersion is! int ||
        appVersion is! String ||
        updatedAt is! String) {
      throw const FormatException('清单字段缺失或格式错误');
    }

    final rawSnapshots = json['snapshots'];
    if (rawSnapshots is! List) {
      throw const FormatException('清单中的快照列表格式错误');
    }
    final minSchemaVersion = _optionalInt(json['min_schema_version']);
    final minProtocolVersion = _optionalInt(json['min_protocol_version']);
    final contributors = _parseContributors(json['contributors']);
    final snapshots = rawSnapshots.map((e) {
      if (e is! Map) {
        throw const FormatException('快照条目格式错误');
      }
      return CloudSnapshotInfo.fromJson(e.cast<String, dynamic>());
    }).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    return CloudDeviceManifest(
      formatVersion: formatVersion,
      deviceId: deviceId,
      deviceName: deviceName,
      schemaVersion: schemaVersion,
      appVersion: appVersion,
      minSchemaVersion: minSchemaVersion,
      minProtocolVersion: minProtocolVersion,
      updatedAt: DateTime.parse(updatedAt),
      snapshots: snapshots,
      contributors: contributors,
    );
  }

  Map<String, dynamic> toJson() => {
    'format_version': formatVersion,
    'device_id': deviceId,
    'device_name': deviceName,
    'schema_version': schemaVersion,
    'app_version': appVersion,
    if (minSchemaVersion != null) 'min_schema_version': minSchemaVersion,
    if (minProtocolVersion != null) 'min_protocol_version': minProtocolVersion,
    if (contributors.isNotEmpty) 'contributors': contributors,
    'updated_at': updatedAt.toUtc().toIso8601String(),
    'snapshots': snapshots.map((e) => e.toJson()).toList(),
  };

  /// 追加一份快照并按 [retainCount] 截断历史。
  ///
  /// - 相同 `key` 覆盖旧条目（重传幂等）；
  /// - 结果始终按时间倒序；
  /// - [retainCount] 至少为 1。
  CloudDeviceManifest addSnapshot(
    CloudSnapshotInfo snapshot, {
    required int retainCount,
  }) {
    final byKey = <String, CloudSnapshotInfo>{
      for (final item in snapshots) item.key: item,
    };
    byKey[snapshot.key] = snapshot;
    final merged = byKey.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final limit = retainCount < 1 ? 1 : retainCount;
    return copyWith(
      updatedAt: DateTime.now(),
      snapshots: merged.take(limit).toList(growable: false),
    );
  }

  CloudDeviceManifest copyWith({
    String? deviceName,
    int? schemaVersion,
    String? appVersion,
    int? minSchemaVersion,
    int? minProtocolVersion,
    DateTime? updatedAt,
    List<CloudSnapshotInfo>? snapshots,
    List<String>? contributors,
  }) {
    return CloudDeviceManifest(
      formatVersion: formatVersion,
      deviceId: deviceId,
      deviceName: deviceName ?? this.deviceName,
      schemaVersion: schemaVersion ?? this.schemaVersion,
      appVersion: appVersion ?? this.appVersion,
      minSchemaVersion: minSchemaVersion ?? this.minSchemaVersion,
      minProtocolVersion: minProtocolVersion ?? this.minProtocolVersion,
      updatedAt: updatedAt ?? this.updatedAt,
      snapshots: snapshots ?? this.snapshots,
      contributors: contributors ?? this.contributors,
    );
  }
}

List<String> _parseContributors(Object? raw) {
  if (raw == null) return const [];
  if (raw is! List) {
    throw const FormatException('清单中的 contributors 格式错误');
  }
  final contributors = <String>[];
  for (final item in raw) {
    if (item is! String || item.isEmpty) {
      throw const FormatException('清单中的 contributors 条目格式错误');
    }
    contributors.add(item);
  }
  return List.unmodifiable(contributors);
}

int? _optionalInt(Object? value) {
  if (value == null) return null;
  if (value is! int || value < 1) {
    throw const FormatException('版本字段格式错误');
  }
  return value;
}

/// 云端设备摘要（用于「从云端恢复」列表）。
class CloudDeviceSummary {
  final CloudDeviceManifest manifest;
  final bool isCurrentDevice;

  const CloudDeviceSummary({
    required this.manifest,
    required this.isCurrentDevice,
  });

  CloudSnapshotInfo? get latest => manifest.latest;
}

/// 同步工具方法（纯 Dart，便于单测）。
class CloudSyncUtils {
  CloudSyncUtils._();

  /// 设备 ID 只允许十六进制与 `-`，长度 8–64（与设备重置逻辑一致）。
  /// 用于过滤旧格式/非数据集快照 key，避免把文件名片段误认成设备 ID。
  static final RegExp _deviceIdPattern = RegExp(r'^[a-fA-F0-9-]{8,64}$');

  /// SHA-256（小写十六进制）。
  static String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

  /// 生成对象键可用的 UTC 时间戳：`20261017T130719123Z`。
  static String utcTimestamp(DateTime time) {
    final utc = time.toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    String three(int v) => v.toString().padLeft(3, '0');
    return '${utc.year}${two(utc.month)}${two(utc.day)}'
        'T${two(utc.hour)}${two(utc.minute)}${two(utc.second)}'
        '${three(utc.millisecond)}Z';
  }

  /// 人类可读的文件大小（用于 UI）。
  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  /// 从统一数据集快照 key 中解析上传该快照的设备 ID。
  ///
  /// key 形如：
  /// `{prefix}/dataset/snapshots/20261018T120000000Z-{deviceId}.zip`
  /// 时间戳部分不含 `-`，因此第一个 `-` 之后直到 `.zip` 就是设备 ID。
  static String? snapshotUploaderDeviceId(String key) {
    final name = key.split('/').last;
    if (!name.endsWith('.zip')) return null;
    final separator = name.indexOf('-');
    if (separator <= 0 || separator >= name.length - 4) return null;
    final id = name.substring(separator + 1, name.length - 4);
    return _deviceIdPattern.hasMatch(id) ? id : null;
  }

  /// 旧版清单没有 `contributors` 字段时，从快照 key 反推贡献设备。
  static Set<String> snapshotContributorIds(
    Iterable<CloudSnapshotInfo> snapshots,
  ) {
    final ids = <String>{};
    for (final snapshot in snapshots) {
      final id = snapshotUploaderDeviceId(snapshot.key);
      if (id != null) ids.add(id);
    }
    return ids;
  }

  /// 计算上传新快照后的 contributors。
  ///
  /// - [stored] 是清单里已有的 contributors；非空时以它为准；
  /// - 旧清单没有该字段时，从 [snapshots] 的上传者反推；
  /// - [reset] 为 true 表示“以本机为准 / 手动上传替换云端”，
  ///   新数据集只记录本机，其它设备需要重新确认。
  static List<String> resolveContributorIds({
    required Iterable<String> stored,
    required Iterable<CloudSnapshotInfo> snapshots,
    required String deviceId,
    bool reset = false,
  }) {
    final base = reset
        ? const <String>[]
        : (stored.isNotEmpty ? stored : snapshotContributorIds(snapshots));
    final ids = <String>{...base, if (deviceId.isNotEmpty) deviceId};
    return ids.toList(growable: false);
  }

  /// 解析清单字节流（UTF-8 JSON），失败时抛出 [FormatException]。
  static CloudDeviceManifest parseManifest(List<int> bytes) {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) {
      throw const FormatException('清单 JSON 顶层不是对象');
    }
    return CloudDeviceManifest.fromJson(decoded.cast<String, dynamic>());
  }

  /// 编码清单为 UTF-8 JSON。
  static Uint8List encodeManifest(CloudDeviceManifest manifest) =>
      Uint8List.fromList(utf8.encode(jsonEncode(manifest.toJson())));
}
