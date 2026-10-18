import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/cloud_sync_device_state.dart';
import 'cloud_sync_settings.dart';
import 'log_service.dart';
import 's3_storage_service.dart';

/// 设备级同步元数据（`meta.json` / `head.json` / `state.json`）的读写入口。
///
/// 读取失败（对象不存在、内容损坏、权限不足）一律降级为 null，
/// 由调用方决定回退策略；写入失败由调用方决定是否计入同步告警。
class CloudSyncDeviceMetaService {
  static const int _maxMetaBytes = 64 * 1024;

  /// 同一后端 + 设备最多每 24 小时检查一次 meta，避免每次同步都多一次 GET。
  static const Duration _metaRecheckInterval = Duration(hours: 24);
  static const String _metaCheckPrefPrefix = 'cloud_sync_meta_checked_v1:';

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

  Future<CloudDeviceHead?> fetchHead(String deviceId) async {
    final key = config.headKey(deviceId);
    try {
      final bytes = await storage.getBytes(
        key,
        maxBytes: _maxMetaBytes,
        nullIfMissing: true,
      );
      if (bytes == null) return null;
      return CloudDeviceMetaCodec.parseHead(bytes);
    } catch (e) {
      logWarning('CloudSyncDeviceMeta', '读取设备 head 失败 $key: $e');
      return null;
    }
  }

  Future<void> saveHead(CloudDeviceHead head) async {
    await storage.putBytes(
      config.headKey(head.deviceId),
      CloudDeviceMetaCodec.encodeHead(head),
    );
  }

  Future<CloudDeviceState?> fetchState(String deviceId) async {
    final key = config.stateKey(deviceId);
    try {
      final bytes = await storage.getBytes(
        key,
        maxBytes: _maxMetaBytes,
        nullIfMissing: true,
      );
      if (bytes == null) return null;
      return CloudDeviceMetaCodec.parseState(bytes);
    } catch (e) {
      logWarning('CloudSyncDeviceMeta', '读取设备 state 失败 $key: $e');
      return null;
    }
  }

  Future<void> saveState(CloudDeviceState state) async {
    await storage.putBytes(
      config.stateKey(state.deviceId),
      CloudDeviceMetaCodec.encodeState(state),
    );
  }

  Future<CloudDeviceMeta?> fetchMeta(String deviceId) async {
    final key = config.metaKey(deviceId);
    try {
      final bytes = await storage.getBytes(
        key,
        maxBytes: _maxMetaBytes,
        nullIfMissing: true,
      );
      if (bytes == null) return null;
      return CloudDeviceMetaCodec.parseMeta(bytes);
    } catch (e) {
      logWarning('CloudSyncDeviceMeta', '读取设备 meta 失败 $key: $e');
      return null;
    }
  }

  Future<void> saveMeta(CloudDeviceMeta meta) async {
    await storage.putBytes(
      config.metaKey(meta.deviceId),
      CloudDeviceMetaCodec.encodeMeta(meta),
    );
  }

  /// 确保设备目录下存在 `meta.json`（名称 / 平台 / schema 版本 / 最近在线）。
  ///
  /// 进程内做 24 小时节流；第一次同步会先 GET 一次判断是否缺失或名称已变。
  Future<void> ensureMeta({
    required String deviceId,
    required String deviceName,
    required int schemaVersion,
  }) async {
    final cacheKey = '$_metaCheckPrefPrefix${config.backendIdentity}|$deviceId';
    final now = DateTime.now();
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
      final checkedMs = prefs.getInt(cacheKey);
      if (checkedMs != null &&
          now.difference(DateTime.fromMillisecondsSinceEpoch(checkedMs)) <
              _metaRecheckInterval) {
        return;
      }
    } catch (_) {
      // 设置存储不可用时不做节流，仍继续补写 meta。
    }
    final existing = await fetchMeta(deviceId);
    final fresh =
        existing != null &&
        existing.deviceName == deviceName &&
        now.difference(existing.lastSeen) < _metaRecheckInterval;
    if (!fresh) {
      await saveMeta(
        CloudDeviceMeta(
          deviceId: deviceId,
          deviceName: deviceName,
          platform: _platformName(),
          schemaVersion: schemaVersion,
          lastSeen: now,
        ),
      );
    }
    try {
      await prefs?.setInt(cacheKey, now.millisecondsSinceEpoch);
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
