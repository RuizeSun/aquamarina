import 'package:flutter/material.dart';

import '../../../models/cloud_sync_manifest.dart';
import '../../../services/cloud_sync_service.dart';
import '../../../services/cloud_sync_settings.dart';
import '../cloud_sync_config_page.dart';
import '../cloud_sync_progress.dart';
import '../settings_section_header.dart';

/// 云同步分区（阶段 2：设备隔离快照上传 / 恢复）。
class CloudSyncSection extends StatefulWidget {
  const CloudSyncSection({super.key});

  @override
  State<CloudSyncSection> createState() => _CloudSyncSectionState();
}

class _CloudSyncSectionState extends State<CloudSyncSection> {
  CloudSyncConfig? _config;
  CloudSyncRuntimeState _state = const CloudSyncRuntimeState();
  bool _hasCredentials = false;
  bool _loading = true;
  bool _busy = false;

  bool get _configured => (_config?.isConfigured ?? false) && _hasCredentials;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final config = await CloudSyncSettings.loadConfig();
    final credentials = await CloudSyncSettings.loadCredentials();
    final state = await CloudSyncSettings.loadState();
    if (!mounted) return;
    setState(() {
      _config = config;
      _hasCredentials = credentials?.isComplete ?? false;
      _state = state;
      _loading = false;
    });
  }

  void _showSnack(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Theme.of(context).colorScheme.error : null,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  String _formatTime(DateTime? time) {
    if (time == null) return '尚未同步';
    final local = time.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  Future<void> _openConfig() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (context) => const CloudSyncConfigPage()),
    );
    if (changed == true) {
      await _load();
    }
  }

  Future<void> _upload() async {
    if (_busy) return;
    final includeApiKeys = await showDialog<bool>(
      context: context,
      builder: (context) {
        var includeKeys = false;
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('上传到云端'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '将本机的词书、学习记录、句子练习与设置打包上传。\n'
                  '云端按设备隔离保存，不会覆盖其它设备的备份。',
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('同时上传 AI API Key'),
                  subtitle: const Text(
                    '默认关闭。开启后备份文件将包含敏感凭据，'
                    '任何能读取该存储桶的人都可以获取你的 Key。',
                  ),
                  value: includeKeys,
                  onChanged: (value) =>
                      setDialogState(() => includeKeys = value),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, includeKeys),
                child: const Text('开始上传'),
              ),
            ],
          ),
        );
      },
    );
    if (includeApiKeys == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final service = await CloudSyncService.create();
      if (!mounted) return;
      final snapshot = await runWithProgressDialog<CloudSnapshotInfo>(
        context,
        title: '上传备份',
        task: (update) async {
          update('正在生成数据库一致性快照…');
          final info = await service.uploadSnapshot(
            includeApiKeys: includeApiKeys,
            onProgress: (sent, total) {
              final percent = total <= 0 ? 0 : (sent * 100 / total).round();
              update(
                '正在上传 $percent%（${CloudSyncUtils.formatBytes(sent)} / '
                '${CloudSyncUtils.formatBytes(total)}）',
              );
            },
          );
          update('正在更新云端清单…');
          return info;
        },
      );
      await _load();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.cloud_done_outlined, color: Colors.green),
          title: const Text('上传完成'),
          content: Text(
            '快照大小：${CloudSyncUtils.formatBytes(snapshot.size)}\n'
            '包含 API Key：${snapshot.containsApiKeys ? '是' : '否'}\n'
            '云端保留份数：${_config?.retainCount ?? 0} 份\n\n'
            '其它设备可以在「从云端恢复」中选择本设备。',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('确定'),
            ),
          ],
        ),
      );
    } catch (e) {
      _showSnack('上传失败：$e', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    if (_busy) return;
    final service = await _createServiceSafely();
    if (service == null) return;
    if (!mounted) return;

    setState(() => _busy = true);
    try {
      final devices = await runWithProgressDialog<List<CloudDeviceSummary>>(
        context,
        title: '读取云端备份',
        task: (update) async {
          update('正在读取云端设备列表…');
          return service.listDevices();
        },
      );
      if (!mounted) return;
      final available = devices.where((d) => d.latest != null).toList();
      if (available.isEmpty) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('云端还没有可用备份'),
            content: const Text('请先在任意一台设备上执行「立即上传备份」。'),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('知道了'),
              ),
            ],
          ),
        );
        return;
      }

      final selected = await showModalBottomSheet<CloudDeviceSummary>(
        context: context,
        isScrollControlled: true,
        builder: (context) =>
            _DevicePickerSheet(devices: available, formatTime: _formatTime),
      );
      if (selected == null || !mounted) return;

      final snapshot = selected.latest!;
      final confirmed = await _confirmRestore(selected);
      if (confirmed != true || !mounted) return;

      final outcome = await runWithProgressDialog<CloudRestoreOutcome>(
        context,
        title: '从云端恢复',
        task: (update) async {
          update('正在下载并校验云端备份…');
          final result = await service.restoreSnapshot(
            selected,
            onProgress: (received, total) {
              if (total != null && total > 0) {
                final percent = (received * 100 / total).round();
                update(
                  '正在下载 $percent%（${CloudSyncUtils.formatBytes(received)} / '
                  '${CloudSyncUtils.formatBytes(total)}）',
                );
              } else {
                update('正在下载（${CloudSyncUtils.formatBytes(received)}）…');
              }
            },
          );
          update('正在导入数据…');
          return result;
        },
      );
      await _load();
      if (!mounted) return;
      await _showRestoreResult(outcome, snapshot);
    } catch (e) {
      _showSnack('恢复失败：$e', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<CloudSyncService?> _createServiceSafely() async {
    try {
      return await CloudSyncService.create();
    } catch (e) {
      _showSnack('$e', isError: true);
      return null;
    }
  }

  Future<bool?> _confirmRestore(CloudDeviceSummary device) {
    final snapshot = device.latest;
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认恢复'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '来源设备：${device.manifest.deviceName}'
              '${device.isCurrentDevice ? '（本机）' : ''}\n'
              '备份时间：${_formatTime(snapshot?.createdAt)}\n'
              '备份大小：${CloudSyncUtils.formatBytes(snapshot?.size ?? 0)}\n'
              '包含 API Key：${(snapshot?.containsApiKeys ?? false) ? '是' : '否'}',
            ),
            const SizedBox(height: 12),
            Text(
              '恢复将覆盖本机当前所有数据，且无法撤销。\n\n'
              '恢复前会自动保留一份本机数据库快照，导入失败时会自动回滚。',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('覆盖恢复'),
          ),
        ],
      ),
    );
  }

  Future<void> _showRestoreResult(
    CloudRestoreOutcome outcome,
    CloudSnapshotInfo snapshot,
  ) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.check_circle, color: Colors.green),
        title: const Text('恢复完成'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '来源：${outcome.manifest.deviceName}\n'
              '备份时间：${_formatTime(snapshot.createdAt)}\n'
              'API Key：${outcome.result.restoredApiKeys ? '已恢复' : '未包含'}',
            ),
            if (outcome.safetyCopyPath != null) ...[
              const SizedBox(height: 8),
              Text(
                '恢复前本机快照：\n${outcome.safetyCopyPath}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 12),
            const Text('为避免页面状态与数据库不一致，建议立即重启应用。'),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final config = _config;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsSectionHeader(title: '云同步'),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        ListTile(
          leading: Icon(Icons.cloud_outlined, color: colorScheme.primary),
          title: const Text('对象存储配置'),
          subtitle: Text(
            config == null
                ? '未配置（S3 兼容：Rain / MinIO / R2 / AWS）'
                : '${config.displayEndpoint}\n${config.bucket} · ${config.prefix}',
          ),
          isThreeLine: config != null,
          trailing: const Icon(Icons.chevron_right),
          onTap: _busy ? null : _openConfig,
        ),
        ListTile(
          leading: Icon(
            Icons.cloud_upload_outlined,
            color: _configured ? colorScheme.primary : colorScheme.outline,
          ),
          title: const Text('立即上传备份'),
          subtitle: const Text('导出本机数据并上传（云端按设备隔离保存）'),
          enabled: _configured && !_busy,
          onTap: _configured && !_busy ? _upload : null,
        ),
        ListTile(
          leading: Icon(
            Icons.cloud_download_outlined,
            color: _configured ? colorScheme.primary : colorScheme.outline,
          ),
          title: const Text('从云端恢复'),
          subtitle: const Text('选择任一设备的备份覆盖本机数据'),
          enabled: _configured && !_busy,
          onTap: _configured && !_busy ? _restore : null,
        ),
        ListTile(
          leading: Icon(Icons.schedule_outlined, color: colorScheme.outline),
          title: const Text('上次成功同步'),
          subtitle: Text(
            _state.lastSuccessAt == null
                ? '尚未同步'
                : _formatTime(_state.lastSuccessAt),
          ),
        ),
        if (!_configured)
          ListTile(
            leading: Icon(Icons.info_outline, color: colorScheme.outline),
            title: const Text('尚未完成配置'),
            subtitle: const Text('填写端点、存储桶与访问凭据后即可使用'),
            onTap: _busy ? null : _openConfig,
          ),
        if (config != null && !config.useSsl)
          ListTile(
            leading: Icon(
              Icons.warning_amber_rounded,
              color: colorScheme.error,
            ),
            title: Text(
              '当前使用 HTTP 明文连接',
              style: TextStyle(color: colorScheme.error),
            ),
            subtitle: const Text('移动端系统默认会拦截明文请求，请改用 HTTPS 端点'),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Text(
            '当前版本提供「设备隔离快照」备份：每次上传都会保留历史版本，'
            '任何设备都不会覆盖其它设备的云端备份。\n'
            '记录级自动合并（词书/笔记/错题跨设备增量同步）将在后续版本接入，'
            '详见 docs/cloud-sync-spec.md。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

/// 云端设备选择底部弹层。
class _DevicePickerSheet extends StatelessWidget {
  final List<CloudDeviceSummary> devices;
  final String Function(DateTime?) formatTime;

  const _DevicePickerSheet({required this.devices, required this.formatTime});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 8),
            Center(
              child: Container(
                width: 32,
                height: 4,
                decoration: BoxDecoration(
                  color: colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
              child: Text(
                '选择要恢复的备份',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: devices.length,
                separatorBuilder: (context, index) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final device = devices[index];
                  final manifest = device.manifest;
                  final latest = device.latest;
                  return ListTile(
                    leading: Icon(
                      device.isCurrentDevice
                          ? Icons.smartphone
                          : Icons.devices_other,
                      color: colorScheme.primary,
                    ),
                    title: Row(
                      children: [
                        Flexible(
                          child: Text(
                            manifest.deviceName,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (device.isCurrentDevice) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '本机',
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                          ),
                        ],
                      ],
                    ),
                    subtitle: Text(
                      '备份时间：${formatTime(latest?.createdAt)}\n'
                      '大小：${CloudSyncUtils.formatBytes(latest?.size ?? 0)}'
                      ' · 含 API Key：'
                      '${(latest?.containsApiKeys ?? false) ? '是' : '否'}',
                    ),
                    isThreeLine: true,
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.pop(context, device),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
