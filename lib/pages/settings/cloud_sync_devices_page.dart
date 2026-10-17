import 'package:flutter/material.dart';

import '../../services/cloud_sync_device_meta_service.dart';
import '../../services/cloud_sync_engine.dart';
import '../../services/cloud_sync_run_lock.dart';
import '../../services/cloud_sync_service.dart';
import '../../services/cloud_sync_settings.dart';

/// 云端设备管理（P2-8）：查看设备、删除旧设备数据。
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
    return _DeviceListData(
      service: service,
      currentId: currentId,
      deviceIds: ids,
      names: names,
    );
  }

  /// 接管：先把旧设备的所有变更拉取并合并到本机，再删除其云端目录。
  Future<void> _takeOver(_DeviceListData data, String deviceId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('接管并合并旧设备'),
        content: Text(
          '将先执行一次增量同步，把设备 $deviceId 的变更合并到本机，'
          '成功后再删除该设备的云端 chunk/快照/清单。\n\n'
          '适合不再使用的旧设备。删除后如果旧设备再次同步，会重新创建目录。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('接管并删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      // 合并 + 删除在同一把锁内完成，避免中间插入另一轮同步。
      final result = await CloudSyncRunLock.runExclusive(() async {
        final engine = await CloudSyncEngine.create();
        final run = await engine.run(pull: true, push: false);
        await data.service.deleteDeviceData(deviceId);
        return run;
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '已接管并合并 ${result.pulledOps} 条变更，'
            '旧设备云端数据已删除',
          ),
        ),
      );
      setState(() => _future = _load());
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('接管失败：$e')));
    }
  }

  Future<void> _delete(_DeviceListData data, String deviceId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除云端设备数据'),
        content: Text(
          '将永久删除设备 $deviceId 的 chunk、快照与清单。\n\n'
          '该设备如果仍在使用，下次同步会重新上传本地变更，但历史快照无法恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await data.service.deleteDeviceData(deviceId);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('云端设备数据已删除')));
      setState(() => _future = _load());
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('删除失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('云端设备')),
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
            return const Center(child: Text('云端还没有设备'));
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
                    : PopupMenuButton<String>(
                        tooltip: '设备操作',
                        onSelected: (value) {
                          if (value == 'takeover') {
                            _takeOver(data, id);
                          } else if (value == 'delete') {
                            _delete(data, id);
                          }
                        },
                        itemBuilder: (context) => const [
                          PopupMenuItem(
                            value: 'takeover',
                            child: Text('接管并合并'),
                          ),
                          PopupMenuItem(
                            value: 'delete',
                            child: Text('仅删除云端数据'),
                          ),
                        ],
                      ),
              );
            },
          );
        },
      ),
    );
  }
}

class _DeviceListData {
  final CloudSyncService service;
  final String currentId;
  final List<String> deviceIds;
  final Map<String, String> names;

  const _DeviceListData({
    required this.service,
    required this.currentId,
    required this.deviceIds,
    required this.names,
  });
}
