import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/cloud_sync_device_state.dart';
import 'cloud_sync_settings.dart';
import 'log_service.dart';
import 's3_storage_service.dart';

/// 以有限并发执行异步任务。
///
/// 设备元数据是彼此独立的小对象请求。串行执行会把每次往返的 RTT 累加
/// 起来（设备越多越慢），而对象存储通常可以轻松承受少量并发 GET。
/// [concurrency] 保持较小值，避免触发部分服务商的并发限流。
Future<void> runWithConcurrency<T>(
  Iterable<T> items,
  Future<void> Function(T item) action, {
  int concurrency = 4,
}) async {
  final list = items.toList(growable: false);
  if (list.isEmpty) return;
  final limit = concurrency < 1 ? 1 : concurrency;
  var next = 0;
  Future<void> worker() async {
    while (true) {
      final index = next++;
      if (index >= list.length) return;
      await action(list[index]);
    }
  }

  await Future.wait([
    for (var i = 0; i < limit && i < list.length; i++) worker(),
  ]);
}

/// 设备级同步元数据（`meta.json` / `head.json` / `state.json`）的读写入口。
///
/// 读取失败（对象不存在、内容损坏、权限不足）一律降级为 null，
/// 由调用方决定回退策略；写入失败由调用方决定是否计入同步告警。
class CloudSyncDeviceMetaService {
  static const int _maxMetaBytes = 64 * 1024;

  /// 同一后端 + 设备最多每 24 小时检查一次 meta，避免每次同步都多一次 GET。
  static const Duration _metaRecheckInterval = Duration(hours: 24);
  static const String _metaCheckPrefPrefix = 'cloud_sync_meta_checked_v1:';
  static const String _metaVersionPrefPrefix = 'cloud_sync_meta_version_v1:';

  final CloudSyncConfig config;
  final S3StorageService storage;

  const CloudSyncDeviceMetaService({
    required this.config,
    required this.storage,
  });

  /// 发现云端所有设备 ID。
  ///
  /// 优先使用一次非递归 LIST 的 CommonPrefixes；兼容实现不返回目录时，
  /// 回退到一次递归 LIST（旧行为），保证仍能发现设备。
  Future<List<String>> listDeviceIds() async {
    final prefix = '${config.devicesPrefix}/';
    final ids = <String>{};
    try {
      final prefixes = await storage.listCommonPrefixes(prefix);
      for (final raw in prefixes) {
        final id = _deviceIdFromPrefix(raw);
        if (id != null) ids.add(id);
      }
    } catch (e) {
      logWarning('CloudSyncDeviceMeta', '列举设备目录失败，回退到递归列举: $e');
    }
    if (ids.isEmpty) {
      final objects = await storage.list(prefix, recursive: true);
      for (final object in objects) {
        final id = deviceIdOfKey(object.key);
        if (id != null) ids.add(id);
      }
    }
    final sorted = ids.toList()..sort();
    return sorted;
  }

  Future<CloudDeviceReadResult<CloudDeviceHead>> readHead(
    String deviceId,
  ) async {
    final key = config.headKey(deviceId);
    try {
      final bytes = await storage.getBytes(
        key,
        maxBytes: _maxMetaBytes,
        nullIfMissing: true,
      );
      if (bytes == null) return const CloudDeviceReadResult.missing();
      return CloudDeviceMetaCodec.decodeHead(bytes);
    } catch (e) {
      logWarning('CloudSyncDeviceMeta', '读取设备 head 失败 $key: $e');
      return CloudDeviceReadResult.error(e);
    }
  }

  Future<CloudDeviceHead?> fetchHead(String deviceId) async {
    final result = await readHead(deviceId);
    return result.isOk ? result.value : null;
  }

  Future<void> saveHead(CloudDeviceHead head) async {
    await storage.putBytes(
      config.headKey(head.deviceId),
      CloudDeviceMetaCodec.encodeHead(head),
    );
  }

  Future<CloudDeviceReadResult<CloudDeviceState>> readState(
    String deviceId,
  ) async {
    final key = config.stateKey(deviceId);
    try {
      final bytes = await storage.getBytes(
        key,
        maxBytes: _maxMetaBytes,
        nullIfMissing: true,
      );
      if (bytes == null) return const CloudDeviceReadResult.missing();
      return CloudDeviceMetaCodec.decodeState(bytes);
    } catch (e) {
      logWarning('CloudSyncDeviceMeta', '读取设备 state 失败 $key: $e');
      return CloudDeviceReadResult.error(e);
    }
  }

  Future<CloudDeviceState?> fetchState(String deviceId) async {
    final result = await readState(deviceId);
    return result.isOk ? result.value : null;
  }

  Future<void> saveState(CloudDeviceState state) async {
    await storage.putBytes(
      config.stateKey(state.deviceId),
      CloudDeviceMetaCodec.encodeState(state),
    );
  }

  Future<CloudDeviceReadResult<CloudDeviceMeta>> readMeta(
    String deviceId,
  ) async {
    final key = config.metaKey(deviceId);
    try {
      final bytes = await storage.getBytes(
        key,
        maxBytes: _maxMetaBytes,
        nullIfMissing: true,
      );
      if (bytes == null) return const CloudDeviceReadResult.missing();
      return CloudDeviceMetaCodec.decodeMeta(bytes);
    } catch (e) {
      logWarning('CloudSyncDeviceMeta', '读取设备 meta 失败 $key: $e');
      return CloudDeviceReadResult.error(e);
    }
  }

  Future<CloudDeviceMeta?> fetchMeta(String deviceId) async {
    final result = await readMeta(deviceId);
    return result.isOk ? result.value : null;
  }

  Future<void> saveMeta(CloudDeviceMeta meta) async {
    await storage.putBytes(
      config.metaKey(meta.deviceId),
      CloudDeviceMetaCodec.encodeMeta(meta),
    );
  }

  /// 确保设备目录下存在 `meta.json`（名称 / 平台 / schema / App / 协议版本）。
  ///
  /// - 名称或任一版本变化时立即重写，不受 24 小时节流限制；
  /// - 云端 meta 格式高于本机、或 schema 高于本机时**拒绝写入**，避免降级覆盖；
  /// - 网络错误时不写，避免把“读不到”误判为“云端没有”。
  Future<CloudMetaPublishResult> ensureMeta({
    required String deviceId,
    required String deviceName,
    required int schemaVersion,
    String? appVersion,
    int? syncProtocolVersion,
    bool force = false,
  }) async {
    final cacheKey = '$_metaCheckPrefPrefix${config.backendIdentity}|$deviceId';
    final versionKey =
        '$_metaVersionPrefPrefix${config.backendIdentity}|$deviceId';
    final versionTag =
        '${appVersion ?? ''}|$schemaVersion|${syncProtocolVersion ?? ''}';
    final now = DateTime.now();
    SharedPreferences? prefs;
    var versionChanged = true;
    try {
      prefs = await SharedPreferences.getInstance();
      versionChanged = prefs.getString(versionKey) != versionTag;
      if (!force && !versionChanged) {
        final checkedMs = prefs.getInt(cacheKey);
        if (checkedMs != null &&
            now.difference(DateTime.fromMillisecondsSinceEpoch(checkedMs)) <
                _metaRecheckInterval) {
          return const CloudMetaPublishResult(
            outcome: CloudMetaPublishOutcome.unchanged,
            remoteStatus: CloudDeviceReadStatus.missing,
          );
        }
      }
    } catch (_) {
      // 设置存储不可用时不做节流，仍继续补写 meta。
    }

    final existing = await readMeta(deviceId);
    switch (existing.status) {
      case CloudDeviceReadStatus.error:
        return CloudMetaPublishResult(
          outcome: CloudMetaPublishOutcome.failed,
          remoteStatus: existing.status,
        );
      case CloudDeviceReadStatus.newerFormat:
        logWarning(
          'CloudSyncDeviceMeta',
          '本机 meta 格式低于云端（${existing.remoteFormatVersion}），拒绝覆盖',
        );
        return CloudMetaPublishResult(
          outcome: CloudMetaPublishOutcome.skippedNewerFormat,
          remoteStatus: existing.status,
          remoteMeta: existing.value,
          remoteFormatVersion: existing.remoteFormatVersion,
        );
      case CloudDeviceReadStatus.ok:
        final remote = existing.value;
        if (remote != null && remote.schemaVersion > schemaVersion) {
          logWarning(
            'CloudSyncDeviceMeta',
            '云端 meta schema=${remote.schemaVersion} 高于本机 $schemaVersion，拒绝覆盖',
          );
          return CloudMetaPublishResult(
            outcome: CloudMetaPublishOutcome.skippedNewerSchema,
            remoteStatus: existing.status,
            remoteMeta: remote,
            remoteFormatVersion: existing.remoteFormatVersion,
          );
        }
        break;
      case CloudDeviceReadStatus.missing:
      case CloudDeviceReadStatus.corrupted:
        break;
    }

    final remote = existing.value;
    final fresh =
        remote != null &&
        !force &&
        !versionChanged &&
        remote.deviceName == deviceName &&
        remote.schemaVersion == schemaVersion &&
        remote.appVersion == appVersion &&
        remote.syncProtocolVersion == syncProtocolVersion &&
        now.difference(remote.lastSeen) < _metaRecheckInterval;
    if (fresh) {
      await _writeThrottle(prefs, cacheKey, versionKey, now, versionTag);
      return CloudMetaPublishResult(
        outcome: CloudMetaPublishOutcome.unchanged,
        remoteStatus: existing.status,
        remoteMeta: remote,
        remoteFormatVersion: existing.remoteFormatVersion,
      );
    }

    try {
      await saveMeta(
        CloudDeviceMeta(
          deviceId: deviceId,
          deviceName: deviceName,
          platform: _platformName(),
          schemaVersion: schemaVersion,
          appVersion: appVersion,
          syncProtocolVersion: syncProtocolVersion,
          lastSeen: now,
        ),
      );
      await _writeThrottle(prefs, cacheKey, versionKey, now, versionTag);
      return CloudMetaPublishResult(
        outcome: CloudMetaPublishOutcome.written,
        remoteStatus: existing.status,
        remoteMeta: remote,
        remoteFormatVersion: existing.remoteFormatVersion,
      );
    } catch (e) {
      logWarning('CloudSyncDeviceMeta', '写入设备 meta 失败: $e');
      return CloudMetaPublishResult(
        outcome: CloudMetaPublishOutcome.failed,
        remoteStatus: existing.status,
        remoteMeta: remote,
        remoteFormatVersion: existing.remoteFormatVersion,
      );
    }
  }

  Future<void> _writeThrottle(
    SharedPreferences? prefs,
    String cacheKey,
    String versionKey,
    DateTime now,
    String versionTag,
  ) async {
    if (prefs == null) return;
    try {
      await prefs.setInt(cacheKey, now.millisecondsSinceEpoch);
      await prefs.setString(versionKey, versionTag);
    } catch (_) {
      // 节流写入失败不影响 meta 本身。
    }
  }

  static String _platformName() {
    if (Platform.isAndroid) return 'Android';
    if (Platform.isIOS) return 'iOS';
    if (Platform.isWindows) return 'Windows';
    if (Platform.isMacOS) return 'macOS';
    if (Platform.isLinux) return 'Linux';
    return Platform.operatingSystem;
  }

  /// 从 `{prefix}/devices/{deviceId}/` 中解析设备 ID。
  String? _deviceIdFromPrefix(String prefix) {
    var value = prefix;
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    final marker = '/devices/';
    final start = value.indexOf(marker);
    if (start < 0) return null;
    final id = value.substring(start + marker.length);
    if (id.isEmpty || id.contains('/')) return null;
    return id;
  }

  /// 从任意对象键中解析设备 ID（`.../devices/{id}/...`）。
  static String? deviceIdOfKey(String key) {
    const marker = '/devices/';
    final start = key.indexOf(marker);
    if (start < 0) return null;
    final idStart = start + marker.length;
    final idEnd = key.indexOf('/', idStart);
    if (idEnd < 0) return null;
    final id = key.substring(idStart, idEnd);
    return id.isEmpty ? null : id;
  }
}
