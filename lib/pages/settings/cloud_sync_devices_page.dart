import 'package:flutter/material.dart';

import '../../services/cloud_sync_device_meta_service.dart';
import '../../services/cloud_sync_service.dart';
import '../../services/cloud_sync_settings.dart';

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
    // 只做增量同步的设备没有 manifest.json；用 meta.json（旧数据回退到
    // head/state 中的 device_name）避免显示成「未知设备」。
    for (final id in ids) {
      if (names[id] != null && names[id]!.trim().isNotEmpty) continue;
      final deviceMeta = await meta.fetchMeta(id);
      if (deviceMeta != null && deviceMeta.deviceName.trim().isNotEmpty) {
        names[id] = deviceMeta.deviceName;
        continue;
      }
      final head = await meta.fetchHead(id);
      if (head != null && head.deviceName.trim().isNotEmpty) {
        names[id] = head.deviceName;
        continue;
      }
      final state = await meta.fetchState(id);
      if (state != null && state.deviceName.trim().isNotEmpty) {
        names[id] = state.deviceName;
      }
    }
    return _DeviceListData(currentId: currentId, deviceIds: ids, names: names);
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
              final name = data.names[id];
              return ListTile(
                leading: Icon(
                  isCurrent ? Icons.phone_android : Icons.devices_other,
                  color: isCurrent
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                title: Text(name ?? (isCurrent ? '当前设备' : '未知设备')),
                subtitle: Text(id),
                trailing: isCurrent
                    ? const Chip(label: Text('本机'))
                    : const Icon(Icons.cloud_done_outlined),
              );
            },
          );
        },
      ),
    );
  }
}

class _DeviceListData {
  final String currentId;
  final List<String> deviceIds;
  final Map<String, String> names;

  const _DeviceListData({
    required this.currentId,
    required this.deviceIds,
    required this.names,
  });
}
