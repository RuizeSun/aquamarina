import 'dart:async';

import 'package:flutter/material.dart';

import '../../../models/cloud_sync_manifest.dart';
import '../../../services/cloud_sync_auto_sync_service.dart';
import '../../../services/cloud_sync_bootstrap_service.dart';
import '../../../services/cloud_sync_engine.dart';
import '../../../services/cloud_sync_service.dart';
import '../../../services/cloud_sync_settings.dart';
import '../../../services/sync_capture_service.dart';
import '../cloud_sync_config_page.dart';
import '../cloud_sync_conflict_page.dart';
import '../cloud_sync_devices_page.dart';
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
  bool _captureEnabled = false;
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
    var captureEnabled = false;
    if (CloudSyncSettings.isCompleteConfiguration(config, credentials)) {
      try {
        captureEnabled = await SyncCaptureService.isCaptureEnabled();
      } catch (_) {
        // 数据库尚未就绪时不影响设置页展示
      }
    }
    if (!mounted) return;
    setState(() {
      _config = config;
      _hasCredentials = credentials?.isComplete ?? false;
      _captureEnabled = captureEnabled;
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

  /// 恢复完成后校正捕获状态，并尝试立即重建设备身份与水位。
  ///
  /// 恢复会重建 `sync_meta`，捕获开关可能回到 0；这里再做一次兜底，
  /// 即使 BackupService 的自动开启失败，也不会让新学习记录静默丢失。
  Future<bool> _finalizeRestore() async {
    var enabled = false;
    try {
      if (await CloudSyncSettings.hasCompleteConfiguration()) {
        await SyncCaptureService.setCaptureEnabled(enabled: true);
      }
      enabled = await SyncCaptureService.isCaptureEnabled();
    } catch (_) {
      enabled = false;
    }
    if (enabled) {
      // 不阻塞恢复结果弹窗；失败会由前台轮询 / 学习结束事件重试。
      unawaited(CloudSyncAutoSyncService.maybeSync(force: true));
    }
    return enabled;
  }

  Future<void> _enableCapture() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await SyncCaptureService.setCaptureEnabled(enabled: true);
      await _load();
      _showSnack('已开启变更捕获');
    } catch (e) {
      _showSnack('开启变更捕获失败：$e', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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

  /// 从云端最新检查点引导（不限首次配置，可随时灾备恢复）。
  Future<void> _bootstrapFromCloud() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final candidate = await CloudSyncBootstrapService.findLatestSnapshot();
      if (candidate == null) {
        _showSnack('云端还没有可用快照');
        return;
      }
      if (!mounted) return;
      final summary = candidate.summary;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('从最新检查点引导'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '将使用设备「${summary.manifest.deviceName}」在 '
                '${_formatTime(summary.latest!.createdAt)} 的快照覆盖本机数据。\n\n'
                '备份大小：'
                '${CloudSyncUtils.formatBytes(summary.latest!.size)}\n\n'
                '恢复前会自动保留本机数据库副本，但当前数据会被覆盖。',
              ),
              if (summary.latest!.size < 64 * 1024) ...[
                const SizedBox(height: 10),
                Text(
                  '注意：该快照体积很小，可能不包含完整学习数据。'
                  '如果本机已有数据，请不要用它覆盖。',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('覆盖并恢复'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      await runWithProgressDialog<CloudRestoreOutcome>(
        context,
        title: '从云端引导',
        task: (update) async {
          update('正在下载并校验最新检查点…');
          return candidate.service.restoreSnapshot(summary);
        },
      );
      final captureEnabled = await _finalizeRestore();
      await _load();
      _showSnack(
        captureEnabled
            ? '已从云端最新检查点恢复，变更捕获已开启；建议重启应用'
            : '已从云端最新检查点恢复；请重启后先执行一次增量同步再学习',
      );
    } catch (e) {
      _showSnack('引导失败：$e', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 增量同步：拉取其它设备的变更并上传本机 oplog。
  Future<void> _incrementalSync() async {
    if (_busy) return;
    final engine = await _createEngineSafely();
    if (engine == null) return;
    if (!mounted) return;

    setState(() => _busy = true);
    try {
      final result = await runWithProgressDialog<CloudSyncRunResult>(
        context,
        title: '增量同步',
        task: (update) async {
          update('正在同步词书、学习记录、笔记与错题…');
          return engine.run(
            onProgress: (phase, done, total) {
              if (phase == CloudSyncRunPhase.pull) {
                update('已拉取 $done/$total 个变更包…');
              } else {
                update('已上传 $done 个变更包…');
              }
            },
          );
        },
      );
      await _load();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          icon: Icon(
            result.hasErrors
                ? Icons.warning_amber_rounded
                : Icons.cloud_done_outlined,
            color: result.hasErrors ? Colors.orange : Colors.green,
          ),
          title: Text(result.hasErrors ? '同步完成（有告警）' : '同步完成'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '拉取：${result.pulledChunks} 个变更包 / '
                  '${result.pulledOps} 条操作\n'
                  '上传：${result.pushedChunks} 个变更包 / '
                  '${result.pushedOps} 条操作\n'
                  '冲突：${result.conflicts} 条（已保留较新数据）\n'
                  '本机待上传：${result.remainingLocalOps} 条',
                ),
                if (result.budgetExhausted)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '已达到单次同步时间预算，剩余变更将在下次同步继续。',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                if (result.errors.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    '告警（前 ${result.errors.length > 3 ? 3 : result.errors.length} 条）：',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  for (final error in result.errors.take(3))
                    Text(
                      '• $error',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
                if (result.conflictDetails.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    '冲突明细（前 ${result.conflictDetails.length > 3 ? 3 : result.conflictDetails.length} 条）：',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  for (final detail in result.conflictDetails.take(3))
                    Text(
                      '• $detail',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ],
            ),
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
      _showSnack('同步失败：$e', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<CloudSyncEngine?> _createEngineSafely() async {
    try {
      return await CloudSyncEngine.create();
    } catch (e) {
      _showSnack('$e', isError: true);
      return null;
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
      final captureEnabled = await _finalizeRestore();
      await _load();
      if (!mounted) return;
      await _showRestoreResult(
        outcome,
        snapshot,
        captureEnabled: captureEnabled,
      );
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
            if ((snapshot?.size ?? 0) < 64 * 1024) ...[
              const SizedBox(height: 10),
              Text(
                '注意：该快照仅 ${CloudSyncUtils.formatBytes(snapshot?.size ?? 0)}，'
                '可能不包含完整学习数据。请确认来源设备，'
                '避免用空快照覆盖本机已有数据。',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
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
    CloudSnapshotInfo snapshot, {
    required bool captureEnabled,
  }) async {
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
            Text(
              captureEnabled
                  ? '变更捕获已自动开启；建议重启应用后立即执行一次「增量同步」。'
                  : '警告：变更捕获未开启。请重启应用后先执行一次「增量同步」，'
                        '再开始学习，否则新记录不会上传。',
              style: captureEnabled
                  ? null
                  : TextStyle(color: Theme.of(context).colorScheme.error),
            ),
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
        if (_configured && !_captureEnabled)
          ListTile(
            leading: Icon(
              Icons.warning_amber_rounded,
              color: colorScheme.error,
            ),
            title: Text(
              '同步变更捕获未开启',
              style: TextStyle(color: colorScheme.error),
            ),
            subtitle: const Text('新学习记录可能无法上传；点击立即修复'),
            enabled: !_busy,
            onTap: _busy ? null : _enableCapture,
          ),
        ListTile(
          leading: Icon(
            Icons.sync_outlined,
            color: _configured ? colorScheme.primary : colorScheme.outline,
          ),
          title: const Text('增量同步'),
          subtitle: const Text('只传输变更：词书、单词记录、笔记、错题与学习统计'),
          enabled: _configured && !_busy,
          onTap: _configured && !_busy ? _incrementalSync : null,
        ),
        ListTile(
          leading: Icon(
            Icons.merge_type,
            color: _configured ? colorScheme.primary : colorScheme.outline,
          ),
          title: const Text('同步冲突'),
          subtitle: const Text('查看并处理合并冲突'),
          enabled: _configured,
          onTap: _configured
              ? () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => const CloudSyncConflictPage(),
                  ),
                )
              : null,
        ),
        ListTile(
          leading: Icon(
            Icons.devices_other,
            color: _configured ? colorScheme.primary : colorScheme.outline,
          ),
          title: const Text('云端设备'),
          subtitle: const Text('查看设备列表、删除旧设备数据'),
          enabled: _configured,
          onTap: _configured
              ? () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => const CloudSyncDevicesPage(),
                  ),
                )
              : null,
        ),
        ListTile(
          leading: Icon(
            Icons.auto_awesome_outlined,
            color: _configured ? colorScheme.primary : colorScheme.outline,
          ),
          title: const Text('从最新检查点引导'),
          subtitle: const Text('自动选择最新快照覆盖恢复（随时可用）'),
          enabled: _configured && !_busy,
          onTap: _configured && !_busy ? _bootstrapFromCloud : null,
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
            '「增量同步」按设备 oplog 只传输变更，支持词书、单词记录、笔记、'
            '错题与学习统计的跨设备合并；删除通过墓碑同步，重复应用幂等。\n'
            '「立即上传备份」提供设备隔离的完整快照（含历史版本），'
            '用于灾备与新设备引导；自动检查点每 7 天或 5000 条变更生成。\n'
            '恢复仍是覆盖式：快照适合灾备 / 引导，日常跨设备合并请使用增量同步。\n'
            '冲突记录可逐条选择保留本地、采用远端或保留双方。',
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
