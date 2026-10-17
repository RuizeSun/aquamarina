import '../models/cloud_sync_device_state.dart';
import 'cloud_sync_settings.dart';
import 'log_service.dart';
import 's3_storage_service.dart';

/// 设备级同步元数据（`head.json` / `state.json`）的读写入口。
///
/// 读取失败（对象不存在、内容损坏、权限不足）一律降级为 null，
/// 由调用方决定回退策略；写入失败由调用方决定是否计入同步告警。
class CloudSyncDeviceMetaService {
  static const int _maxMetaBytes = 64 * 1024;

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
