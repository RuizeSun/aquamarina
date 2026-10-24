import 'package:package_info_plus/package_info_plus.dart';

import '../../models/cloud_sync_device_state.dart';
import '../../models/cloud_sync_manifest.dart';
import '../../models/sync_op.dart';
import 'cloud_sync_device_meta_service.dart';
import 'cloud_sync_settings.dart';
import '../data/database_service.dart';
import '../system/log_service.dart';
import 's3_storage_service.dart';

/// 云同步版本兼容等级。
///
/// - [compatible]：没有发现版本差异；
/// - [softWarning]：App 版本不同，但 schema / 协议兼容，继续同步；
/// - [blocked]：数据格式或同步协议不兼容，必须停止远端收发。
enum CloudSyncCompatibilityLevel { compatible, softWarning, blocked }

/// 一次兼容性检查的结论。
class CloudSyncCompatibilityResult {
  final CloudSyncCompatibilityLevel level;
  final String reason;
  final String signature;

  final String? datasetId;
  final String? peerDeviceId;
  final String? peerDeviceName;
  final String? peerAppVersion;
  final int? peerSchemaVersion;
  final int? peerProtocolVersion;
  final int? peerFormatVersion;

  final int localSchemaVersion;
  final int localProtocolVersion;
  final String? localAppVersion;

  /// 是否必须升级本机才能恢复同步。
  final bool requiresUpgrade;

  const CloudSyncCompatibilityResult({
    required this.level,
    required this.reason,
    required this.signature,
    required this.localSchemaVersion,
    required this.localProtocolVersion,
    this.localAppVersion,
    this.datasetId,
    this.peerDeviceId,
    this.peerDeviceName,
    this.peerAppVersion,
    this.peerSchemaVersion,
    this.peerProtocolVersion,
    this.peerFormatVersion,
    this.requiresUpgrade = false,
  });

  bool get isBlocked => level == CloudSyncCompatibilityLevel.blocked;
  bool get isSoftWarning => level == CloudSyncCompatibilityLevel.softWarning;
  bool get isCompatible => level == CloudSyncCompatibilityLevel.compatible;
  bool get hasNotice => !isCompatible;
}

/// 语义版本号工具（忽略 build number）。
class CloudSyncVersion {
  CloudSyncVersion._();

  static List<int>? parse(String? version) {
    if (version == null) return null;
    var value = version.trim();
    if (value.isEmpty) return null;
    if (value.startsWith('v') || value.startsWith('V')) {
      value = value.substring(1);
    }
    final plus = value.indexOf('+');
    if (plus >= 0) value = value.substring(0, plus);
    final parts = value.split('.');
    if (parts.length < 3) return null;
    try {
      return parts.take(3).map(int.parse).toList(growable: false);
    } catch (_) {
      return null;
    }
  }

  /// 返回 -1 / 0 / 1；任一方无法解析时返回 null。
  static int? compare(String? a, String? b) {
    final left = parse(a);
    final right = parse(b);
    if (left == null || right == null) return null;
    for (var i = 0; i < 3; i++) {
      if (left[i] > right[i]) return 1;
      if (left[i] < right[i]) return -1;
    }
    return 0;
  }
}

/// 云同步版本门禁的纯逻辑部分。
///
/// 只比较“数据能否被安全解释”：
/// - schema / 同步协议更高 → 硬阻断；
/// - App 版本不同但两者兼容 → 软提示；
/// - 旧 meta 没有版本字段 → 未知，不阻断。
class CloudSyncCompatibilityService {
  CloudSyncCompatibilityService._();

  /// 活跃设备窗口：更久没有同步的设备不再参与硬阻断，避免陈旧设备永久阻塞。
  static const Duration activeWindow = Duration(days: 30);
  static const int _maxManifestBytes = 512 * 1024;

  static Future<String?> localAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final build = info.buildNumber.trim();
      final version = info.version.trim();
      if (version.isEmpty) return null;
      return build.isEmpty ? version : '$version+$build';
    } catch (_) {
      return null;
    }
  }

  static Future<CloudSyncCompatibilityResult> evaluate({
    required CloudSyncConfig config,
    required S3StorageService storage,
    required String localDeviceId,
    int localSchemaVersion = DatabaseService.schemaVersion,
    int localProtocolVersion = SyncOp.currentVersion,
    String? localAppVersion,
    DateTime? now,
  }) async {
    final current = now ?? DateTime.now();
    final appVersion =
        localAppVersion ??
        await CloudSyncCompatibilityService.localAppVersion();
    CloudDeviceManifest? manifest;
    try {
      manifest = await _fetchManifest(config, storage);
    } on CloudSyncIncompatibleException catch (e) {
      return _result(
        level: CloudSyncCompatibilityLevel.blocked,
        reason: e.message,
        localSchemaVersion: localSchemaVersion,
        localProtocolVersion: localProtocolVersion,
        localAppVersion: appVersion,
        peerFormatVersion: e.remoteFormatVersion,
        requiresUpgrade: true,
      );
    } catch (e) {
      // 读取清单失败按网络问题处理，不据此阻断。
      logWarning('CloudSyncCompatibility', '读取数据集清单失败，跳过清单版本检查: $e');
    }

    final datasetId = manifest?.deviceId;
    if (manifest != null) {
      final requiredSchema = _maxInt(
        manifest.minSchemaVersion ?? 0,
        manifest.schemaVersion,
      );
      if (requiredSchema > localSchemaVersion) {
        return _result(
          level: CloudSyncCompatibilityLevel.blocked,
          reason:
              '云端数据需要数据库 schema $requiredSchema，本机为 $localSchemaVersion。请升级应用后再同步。',
          localSchemaVersion: localSchemaVersion,
          localProtocolVersion: localProtocolVersion,
          localAppVersion: appVersion,
          datasetId: datasetId,
          peerSchemaVersion: requiredSchema,
          requiresUpgrade: true,
        );
      }
      final requiredProtocol = manifest.minProtocolVersion ?? 0;
      if (requiredProtocol > localProtocolVersion) {
        return _result(
          level: CloudSyncCompatibilityLevel.blocked,
          reason:
              '云端数据需要同步协议 v$requiredProtocol，本机仅支持 v$localProtocolVersion。请升级应用后再同步。',
          localSchemaVersion: localSchemaVersion,
          localProtocolVersion: localProtocolVersion,
          localAppVersion: appVersion,
          datasetId: datasetId,
          peerProtocolVersion: requiredProtocol,
          requiresUpgrade: true,
        );
      }
    }

    final meta = CloudSyncDeviceMetaService(config: config, storage: storage);
    List<String> deviceIds;
    try {
      deviceIds = await meta.listDeviceIds();
    } catch (e) {
      logWarning('CloudSyncCompatibility', '列举设备失败，跳过设备版本检查: $e');
      deviceIds = const [];
    }
    final ignored = await _loadIgnoredDeviceIds();

    CloudSyncCompatibilityResult? hardBlock;
    CloudSyncCompatibilityResult? softWarning;

    for (final id in deviceIds) {
      if (ignored.contains(id)) continue;
      final read = await meta.readMeta(id);
      if (read.isNewerFormat) {
        hardBlock ??= _result(
          level: CloudSyncCompatibilityLevel.blocked,
          reason:
              '设备元数据格式版本过新（v${read.remoteFormatVersion}），本机无法安全读取。请升级应用后再同步。',
          localSchemaVersion: localSchemaVersion,
          localProtocolVersion: localProtocolVersion,
          localAppVersion: appVersion,
          datasetId: datasetId,
          peerDeviceId: id,
          peerDeviceName: read.value?.deviceName,
          peerAppVersion: read.value?.appVersion,
          peerSchemaVersion: read.value?.schemaVersion,
          peerProtocolVersion: read.value?.syncProtocolVersion,
          peerFormatVersion: read.remoteFormatVersion,
          requiresUpgrade: true,
        );
        continue;
      }
      final remote = read.value;
      if (remote == null) continue;

      final isLocal = id == localDeviceId;
      if (!isLocal && current.difference(remote.lastSeen) > activeWindow) {
        continue;
      }

      if (remote.schemaVersion > localSchemaVersion) {
        hardBlock ??= _result(
          level: CloudSyncCompatibilityLevel.blocked,
          reason:
              '设备「${remote.deviceName}」使用数据库 schema ${remote.schemaVersion}，本机为 $localSchemaVersion。请升级应用后再同步。',
          localSchemaVersion: localSchemaVersion,
          localProtocolVersion: localProtocolVersion,
          localAppVersion: appVersion,
          datasetId: datasetId,
          peerDeviceId: id,
          peerDeviceName: remote.deviceName,
          peerAppVersion: remote.appVersion,
          peerSchemaVersion: remote.schemaVersion,
          peerProtocolVersion: remote.syncProtocolVersion,
          peerFormatVersion: read.remoteFormatVersion,
          requiresUpgrade: true,
        );
        continue;
      }
      final remoteProtocol = remote.syncProtocolVersion;
      if (remoteProtocol != null && remoteProtocol > localProtocolVersion) {
        hardBlock ??= _result(
          level: CloudSyncCompatibilityLevel.blocked,
          reason:
              '设备「${remote.deviceName}」使用同步协议 v$remoteProtocol，本机仅支持 v$localProtocolVersion。请升级应用后再同步。',
          localSchemaVersion: localSchemaVersion,
          localProtocolVersion: localProtocolVersion,
          localAppVersion: appVersion,
          datasetId: datasetId,
          peerDeviceId: id,
          peerDeviceName: remote.deviceName,
          peerAppVersion: remote.appVersion,
          peerSchemaVersion: remote.schemaVersion,
          peerProtocolVersion: remoteProtocol,
          peerFormatVersion: read.remoteFormatVersion,
          requiresUpgrade: true,
        );
        continue;
      }

      // 本机自己写入的 meta 版本必然与当前一致；不对自己产生 App 版本软提示。
      if (!isLocal &&
          CloudSyncVersion.compare(remote.appVersion, appVersion) == 1) {
        softWarning ??= _result(
          level: CloudSyncCompatibilityLevel.softWarning,
          reason:
              '设备「${remote.deviceName}」使用 ${remote.appVersion}，本机为 $appVersion。版本不同，但数据格式兼容，同步将继续。',
          localSchemaVersion: localSchemaVersion,
          localProtocolVersion: localProtocolVersion,
          localAppVersion: appVersion,
          datasetId: datasetId,
          peerDeviceId: id,
          peerDeviceName: remote.deviceName,
          peerAppVersion: remote.appVersion,
          peerSchemaVersion: remote.schemaVersion,
          peerProtocolVersion: remote.syncProtocolVersion,
          peerFormatVersion: read.remoteFormatVersion,
        );
      }
    }

    if (hardBlock != null) return hardBlock;
    if (softWarning != null) return softWarning;

    // 数据集清单由更新版本上传时给一次软提示（不作为阻断依据）。
    if (manifest != null &&
        CloudSyncVersion.compare(manifest.appVersion, appVersion) == 1) {
      return _result(
        level: CloudSyncCompatibilityLevel.softWarning,
        reason:
            '云端数据由 ${manifest.appVersion} 上传，本机为 $appVersion。版本不同，但数据格式兼容，同步将继续。',
        localSchemaVersion: localSchemaVersion,
        localProtocolVersion: localProtocolVersion,
        localAppVersion: appVersion,
        datasetId: datasetId,
        peerAppVersion: manifest.appVersion,
        peerSchemaVersion: manifest.schemaVersion,
        peerProtocolVersion: manifest.minProtocolVersion,
      );
    }

    return _result(
      level: CloudSyncCompatibilityLevel.compatible,
      reason: '',
      localSchemaVersion: localSchemaVersion,
      localProtocolVersion: localProtocolVersion,
      localAppVersion: appVersion,
      datasetId: datasetId,
    );
  }

  /// 本机 meta 已被更高版本写过（降级 / 回退场景）。
  static CloudSyncCompatibilityResult fromLocalMetaPublish({
    required CloudMetaPublishResult publish,
    required String deviceId,
    required int localSchemaVersion,
    required int localProtocolVersion,
    required String? localAppVersion,
    String? datasetId,
  }) {
    final remote = publish.remoteMeta;
    final isFormat =
        publish.outcome == CloudMetaPublishOutcome.skippedNewerFormat;
    final reason = isFormat
        ? '本机元数据格式低于云端（v${publish.remoteFormatVersion}），请升级应用后再同步。'
        : '本机数据库 schema $localSchemaVersion 低于云端设备元数据 ${remote?.schemaVersion}，请升级应用后再同步。';
    return _result(
      level: CloudSyncCompatibilityLevel.blocked,
      reason: reason,
      localSchemaVersion: localSchemaVersion,
      localProtocolVersion: localProtocolVersion,
      localAppVersion: localAppVersion,
      datasetId: datasetId,
      peerDeviceId: deviceId,
      peerDeviceName: remote?.deviceName,
      peerAppVersion: remote?.appVersion,
      peerSchemaVersion: remote?.schemaVersion,
      peerProtocolVersion: remote?.syncProtocolVersion,
      peerFormatVersion: publish.remoteFormatVersion,
      requiresUpgrade: true,
    );
  }

  /// 云端清单格式过新（`fetchDatasetManifest` 抛出）。
  static CloudSyncCompatibilityResult fromIncompatibleException({
    required CloudSyncIncompatibleException error,
    required int localSchemaVersion,
    required int localProtocolVersion,
    required String? localAppVersion,
  }) {
    return _result(
      level: CloudSyncCompatibilityLevel.blocked,
      reason: error.message,
      localSchemaVersion: localSchemaVersion,
      localProtocolVersion: localProtocolVersion,
      localAppVersion: localAppVersion,
      peerFormatVersion: error.remoteFormatVersion,
      peerSchemaVersion: error.requiredSchemaVersion,
      peerProtocolVersion: error.requiredProtocolVersion,
      requiresUpgrade: true,
    );
  }

  static CloudSyncCompatibilityResult _result({
    required CloudSyncCompatibilityLevel level,
    required String reason,
    required int localSchemaVersion,
    required int localProtocolVersion,
    required String? localAppVersion,
    String? datasetId,
    String? peerDeviceId,
    String? peerDeviceName,
    String? peerAppVersion,
    int? peerSchemaVersion,
    int? peerProtocolVersion,
    int? peerFormatVersion,
    bool requiresUpgrade = false,
  }) {
    final signature = [
      level.name,
      datasetId ?? '',
      peerDeviceId ?? '',
      peerAppVersion ?? '',
      peerSchemaVersion ?? '',
      peerProtocolVersion ?? '',
      peerFormatVersion ?? '',
      localSchemaVersion,
      localProtocolVersion,
      localAppVersion ?? '',
      reason,
    ].join('|');
    return CloudSyncCompatibilityResult(
      level: level,
      reason: reason,
      signature: signature,
      datasetId: datasetId,
      peerDeviceId: peerDeviceId,
      peerDeviceName: peerDeviceName,
      peerAppVersion: peerAppVersion,
      peerSchemaVersion: peerSchemaVersion,
      peerProtocolVersion: peerProtocolVersion,
      peerFormatVersion: peerFormatVersion,
      localSchemaVersion: localSchemaVersion,
      localProtocolVersion: localProtocolVersion,
      localAppVersion: localAppVersion,
      requiresUpgrade: requiresUpgrade,
    );
  }

  static Future<CloudDeviceManifest?> _fetchManifest(
    CloudSyncConfig config,
    S3StorageService storage,
  ) async {
    final bytes = await storage.getBytes(
      config.datasetManifestKey,
      maxBytes: _maxManifestBytes,
      nullIfMissing: true,
    );
    if (bytes == null) return null;
    return CloudSyncUtils.parseManifest(bytes);
  }

  static Future<Set<String>> _loadIgnoredDeviceIds() async {
    try {
      return (await CloudSyncSettings.loadIgnoredDeviceIds()).toSet();
    } catch (_) {
      return <String>{};
    }
  }

  static int _maxInt(int a, int b) => a > b ? a : b;
}
