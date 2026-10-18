import 'package:flutter/material.dart';

import '../../services/cloud_sync_device_meta_service.dart';
import '../../services/cloud_sync_service.dart';
import '../../services/cloud_sync_settings.dart';
import '../../services/database_service.dart';

/// 已连接设备（只读）：云端只有一份数据，这里仅展示哪些设备在使用它。
class CloudSyncDevicesPage extends StatefulWidget {
  const CloudSyncDevicesPage({super.key});

  @override
  State<CloudSyncDevicesPage> createState() => _CloudSyncDevicesPageState();
}

class _CloudSyncDevicesPageState extends State<CloudSyncDevicesPage> {
  late Future<_DeviceListData> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_DeviceListData> _load() async {
    final service = await CloudSyncService.create();
    final currentId = await CloudSyncSettings.getOrCreateDeviceId();
    final meta = CloudSyncDeviceMetaService(
      config: service.config,
      storage: service.storage,
    );
    final ids = await meta.listDeviceIds();
    final summaries = await service.listDevices();
    final names = {
      for (final item in summaries)
        item.manifest.deviceId: item.manifest.deviceName,
    };

    final devices = <String, _DeviceInfo>{};
    for (final id in ids) {
      var info = _DeviceInfo(name: names[id]);
      final metaRead = await meta.readMeta(id);
      if (metaRead.value != null) {
        final value = metaRead.value!;
        info = info.copyWith(
          name: value.deviceName,
          appVersion: value.appVersion,
          schemaVersion: value.schemaVersion,
          protocolVersion: value.syncProtocolVersion,
          platform: value.platform,
          lastSeen: value.lastSeen,
          newerFormat: metaRead.isNewerFormat,
          metadataError: metaRead.isCorrupted || metaRead.isError,
        );
      } else {
        // 旧数据 / 只上传过快照的设备：回退到 head / state 中的名称；
        // head 也可能带有版本信息。
        final headRead = await meta.readHead(id);
        final head = headRead.value;
        final stateRead = await meta.readState(id);
        final state = stateRead.value;
        info = info.copyWith(
          name: head?.deviceName ?? state?.deviceName,
          appVersion: head?.appVersion,
          schemaVersion: head?.schemaVersion,
          protocolVersion: head?.syncProtocolVersion,
          lastSeen: head?.updatedAt ?? state?.updatedAt,
          newerFormat:
              metaRead.isNewerFormat ||
              headRead.isNewerFormat ||
              stateRead.isNewerFormat,
          metadataError:
              metaRead.isCorrupted ||
              metaRead.isError ||
              headRead.isCorrupted ||
              stateRead.isCorrupted,
        );
      }
      devices[id] = info;
    }
    return _DeviceListData(
      currentId: currentId,
      deviceIds: ids,
      devices: devices,
      localSchemaVersion: DatabaseService.schemaVersion,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('已连接设备')),
      body: FutureBuilder<_DeviceListData>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('读取设备失败：${snapshot.error}'));
          }
          final data = snapshot.data!;
          if (data.deviceIds.isEmpty) {
            return const Center(child: Text('还没有设备同步过这份云端数据'));
          }
          return ListView.separated(
            itemCount: data.deviceIds.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final id = data.deviceIds[index];
              final isCurrent = id == data.currentId;
              final info = data.devices[id] ?? const _DeviceInfo();
              final name = info.name?.trim().isNotEmpty == true
                  ? info.name
                  : (isCurrent ? '当前设备' : '未知设备');
              final incompatible =
                  !isCurrent &&
                  info.schemaVersion != null &&
                  info.schemaVersion! > data.localSchemaVersion;
              final formatTooNew = info.newerFormat;
              final trailing = isCurrent
                  ? const Chip(label: Text('本机'))
                  : (incompatible || formatTooNew)
                  ? Chip(
                      label: Text(formatTooNew ? '格式过新' : '版本不兼容'),
                      backgroundColor: Theme.of(
                        context,
                      ).colorScheme.errorContainer,
                    )
                  : const Icon(Icons.cloud_done_outlined);
              return ListTile(
                leading: Icon(
                  isCurrent ? Icons.phone_android : Icons.devices_other,
                  color: isCurrent
                      ? Theme.of(context).colorScheme.primary
                      : (incompatible || formatTooNew
                            ? Theme.of(context).colorScheme.error
                            : null),
                ),
                title: Text(name ?? '未知设备'),
                subtitle: Text(_subtitle(info, id)),
                isThreeLine: true,
                trailing: trailing,
              );
            },
          );
        },
      ),
    );
  }

  String _subtitle(_DeviceInfo info, String id) {
    final version = info.appVersion?.trim();
    final schema = info.schemaVersion;
    final parts = <String>[
      if (version != null && version.isNotEmpty) 'App $version',
      if (schema != null) 'schema $schema',
      if (info.platform?.trim().isNotEmpty == true) info.platform!,
      if (info.lastSeen != null) '最近同步 ${_formatTime(info.lastSeen!)}',
    ];
    if (parts.isEmpty) {
      parts.add(info.newerFormat ? '元数据格式过新，请升级应用查看' : id);
    } else {
      parts.add(id);
    }
    return parts.join(' · ');
  }

  String _formatTime(DateTime time) {
    final local = time.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}

class _DeviceListData {
  final String currentId;
  final List<String> deviceIds;
  final Map<String, _DeviceInfo> devices;
  final int localSchemaVersion;

  const _DeviceListData({
    required this.currentId,
    required this.deviceIds,
    required this.devices,
    required this.localSchemaVersion,
  });
}

class _DeviceInfo {
  final String? name;
  final String? appVersion;
  final int? schemaVersion;
  final int? protocolVersion;
  final String? platform;
  final DateTime? lastSeen;
  final bool newerFormat;
  final bool metadataError;

  const _DeviceInfo({
    this.name,
    this.appVersion,
    this.schemaVersion,
    this.protocolVersion,
    this.platform,
    this.lastSeen,
    this.newerFormat = false,
    this.metadataError = false,
  });

  _DeviceInfo copyWith({
    String? name,
    String? appVersion,
    int? schemaVersion,
    int? protocolVersion,
    String? platform,
    DateTime? lastSeen,
    bool? newerFormat,
    bool? metadataError,
  }) {
    return _DeviceInfo(
      name: name ?? this.name,
      appVersion: appVersion ?? this.appVersion,
      schemaVersion: schemaVersion ?? this.schemaVersion,
      protocolVersion: protocolVersion ?? this.protocolVersion,
      platform: platform ?? this.platform,
      lastSeen: lastSeen ?? this.lastSeen,
      newerFormat: newerFormat ?? this.newerFormat,
      metadataError: metadataError ?? this.metadataError,
    );
  }
}
