import 'dart:async';

import 'package:flutter/material.dart';

import '../../../models/cloud_sync_manifest.dart';
import '../../../services/cloud_sync_auto_sync_service.dart';
import '../../../services/cloud_sync_bootstrap_service.dart';
import '../../../services/cloud_sync_checkpoint_service.dart';
import '../../../services/cloud_sync_engine.dart';
import '../../../services/cloud_sync_introduction_service.dart';
import '../../../services/cloud_sync_merge_service.dart';
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
  CloudSyncIntroState? _intro;
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
    CloudSyncIntroState? intro;
    if (CloudSyncSettings.isCompleteConfiguration(config, credentials)) {
      try {
        captureEnabled = await SyncCaptureService.isCaptureEnabled();
      } catch (_) {
        // 数据库尚未就绪时不影响设置页展示
      }
      try {
        intro = await CloudSyncIntroductionService.inspect();
      } catch (_) {
        intro = null;
      }
    }
    if (!mounted) return;
    setState(() {
      _config = config;
      _hasCredentials = credentials?.isComplete ?? false;
      _captureEnabled = captureEnabled;
      _state = state;
      _intro = intro;
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
      if (!await _prepareForRestore()) return;
      if (!mounted) return;
      final outcome = await runWithProgressDialog<CloudRestoreOutcome>(
        context,
        title: '从云端引导',
        task: (update) async {
          update('正在下载并校验最新检查点…');
          return candidate.service.restoreSnapshot(summary);
        },
      );
      if (outcome == null) {
        if (!mounted) return;
        _showSnack('已取消恢复');
        return;
      }
      await CloudSyncSettings.saveIntroDecision(
        summary.manifest.deviceId,
        CloudSyncIntroAction.useCloud.storageValue,
      );
      final captureEnabled = await _finalizeRestore();
      await _load();
      _showSnack(
        captureEnabled
            ? '已从云端最新检查点恢复，变更捕获已开启；建议重启应用'
            : '已从云端最新检查点恢复；请重启后先执行一次同步再学习',
      );
    } catch (e) {
      _showSnack('引导失败：$e', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 首次接入确认。返回 true 表示可以继续执行普通同步；
  /// 返回 false 表示用户取消，或选择已经执行完毕（合并/覆盖/以本机为准）。
  Future<bool> _ensureIntroduction() async {
    final intro = await CloudSyncIntroductionService.inspect();
    if (!intro.needsDecision) return true;
    if (!mounted) return false;

    final action = await showDialog<CloudSyncIntroAction>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.merge_type),
        title: const Text('首次接入'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '云端已经有一份数据，本机也已有历史数据。\n'
              '请选择本次如何处理，之后所有设备都会保持同一份数据。',
            ),
            const SizedBox(height: 12),
            _IntroOption(
              icon: Icons.call_merge,
              title: '合并两端数据（推荐）',
              subtitle: '保留本机和云端的历史，自动处理重复与冲突',
              onTap: () => Navigator.pop(context, CloudSyncIntroAction.merge),
            ),
            _IntroOption(
              icon: Icons.smartphone,
              title: '以本机为准',
              subtitle: '用本机数据替换云端，其它设备会重新确认',
              onTap: () =>
                  Navigator.pop(context, CloudSyncIntroAction.keepLocal),
            ),
            _IntroOption(
              icon: Icons.cloud_outlined,
              title: '以云端为准',
              subtitle: '用云端数据覆盖本机，本机旧数据不保留',
              onTap: () =>
                  Navigator.pop(context, CloudSyncIntroAction.useCloud),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('稍后决定'),
          ),
        ],
      ),
    );
    if (action == null || !mounted) return false;

    if (action == CloudSyncIntroAction.keepLocal ||
        action == CloudSyncIntroAction.useCloud) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('确认覆盖'),
          content: Text(
            action == CloudSyncIntroAction.keepLocal
                ? '本机数据将成为云端唯一数据，云端旧数据会被替换；'
                      '其它设备下次同步时需要重新确认。确定继续吗？'
                : '本机旧数据将被云端数据覆盖。系统会自动保留一份本机副本，'
                      '但应用内的当前数据会变成云端版本。确定继续吗？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认覆盖'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return false;
    }

    CloudSyncMergeResult? result;
    try {
      result = await runWithProgressDialog<CloudSyncMergeResult?>(
        context,
        title: '首次接入',
        task: (update) async {
          update('正在准备…');
          return CloudSyncIntroductionService.apply(
            action,
            onProgress: update,
            onMergeProgress: (done, total) {
              if (total > 0) {
                update('正在合并数据 $done/$total…');
              } else {
                update('正在合并数据…');
              }
            },
          );
        },
      );
    } catch (e) {
      await _load();
      if (mounted) _showSnack('首次接入失败：$e', isError: true);
      return false;
    }
    await _load();
    if (!mounted) return false;
    if (result == null && action == CloudSyncIntroAction.merge) {
      _showSnack('已取消合并');
      return false;
    }
    final message = switch (action) {
      CloudSyncIntroAction.merge => '已合并两端数据，之后会自动保持同步',
      CloudSyncIntroAction.keepLocal => '已用本机数据建立云端基线，其它设备会重新确认',
      CloudSyncIntroAction.useCloud => '已使用云端数据覆盖本机',
    };
    _showSnack(message);
    return false;
  }

  /// 增量同步：拉取其它设备的变更并上传本机 oplog。
  Future<void> _incrementalSync() async {
    if (!await _ensureIntroduction()) return;
    if (_busy) return;
    final engine = await _createEngineSafely();
    if (engine == null) return;
    if (!mounted) return;

    setState(() => _busy = true);
    try {
      final cancelToken = ProgressCancelToken();
      final result = await runWithProgressDialog<CloudSyncRunResult>(
        context,
        title: '同步',
        cancelToken: cancelToken,
        task: (update) async {
          update('正在同步词书、学习记录、笔记与错题…');
          final run = await engine.run(
            isCancelled: () => cancelToken.isCancelled,
            onProgress: (phase, done, total) {
              if (phase == CloudSyncRunPhase.pull) {
                update('已拉取 $done/$total 个变更包…');
              } else {
                update('已上传 $done 个变更包…');
              }
            },
          );
          if (!run.hasErrors && !run.cancelled && !run.blockedByVersion) {
            update('正在检查云端基线…');
            await CloudSyncCheckpointService.maybeCreate();
          }
          return run;
        },
      );
      await _load();
      if (!mounted) return;
      if (result == null) {
        _showSnack('同步已取消；未完成的变更包会在下次同步继续');
        return;
      }
      if (result.blockedByVersion) {
        _showSnack('云同步已暂停：${result.blockReason ?? '版本不兼容'}', isError: true);
        return;
      }
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
    if (!await _ensureIntroduction()) return;
    if (!mounted) return;
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
                  '云端只保留一份统一数据；本次会用本机数据替换它，\n'
                  '其它设备下次同步时需要重新确认。',
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
      final cancelToken = ProgressCancelToken();
      final snapshot = await runWithProgressDialog<CloudSnapshotInfo>(
        context,
        title: '上传备份',
        cancelToken: cancelToken,
        task: (update) async {
          update('正在生成数据库一致性快照…');
          final info = await service.uploadSnapshot(
            includeApiKeys: includeApiKeys,
            startNewDataset: true,
            resetContributors: true,
            isCancelled: () => cancelToken.isCancelled,
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
      if (!mounted) return;
      if (snapshot == null) {
        await _load();
        if (!mounted) return;
        _showSnack('上传已取消');
        return;
      }
      // 手动上传会用本机数据替换云端统一数据，datasetId 已变化；
      // 本机记为已完成选择，避免下次加载又弹首次接入向导。
      final updated = await service.fetchDatasetManifest();
      await CloudSyncSettings.saveIntroDecision(
        updated?.deviceId ?? '',
        CloudSyncIntroAction.keepLocal.storageValue,
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
            '其它设备下次同步时会重新确认是否使用这份云端数据。',
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

  /// 恢复前检查本机未上传变更。
  ///
  /// 返回 false 表示用户取消、或“先上传”没有完成，调用方必须放弃恢复。
  Future<bool> _prepareForRestore() async {
    var pending = 0;
    try {
      pending = await SyncCaptureService.pendingCount();
    } catch (_) {
      return true;
    }
    if (pending <= 0) return true;
    if (!mounted) return false;

    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.sync_problem_outlined, color: Colors.orange),
        title: const Text('本机有未同步变更'),
        content: Text(
          '检测到 $pending 条本机变更尚未上传。\n\n'
          '恢复会用云端快照覆盖本机数据库，这些变更将无法从本机恢复。'
          '建议先上传，再执行恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'cancel'),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'overwrite'),
            child: const Text('仍然恢复'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'push'),
            child: const Text('先上传再恢复'),
          ),
        ],
      ),
    );
    if (choice == null || choice == 'cancel') return false;
    if (choice == 'overwrite') return true;
    if (!mounted) return false;

    final engine = await _createEngineSafely();
    if (engine == null) return false;
    if (!mounted) return false;
    final cancelToken = ProgressCancelToken();
    try {
      final result = await runWithProgressDialog<CloudSyncRunResult>(
        context,
        title: '上传本机变更',
        cancelToken: cancelToken,
        task: (update) async {
          update('正在上传本机未同步变更…');
          return engine.run(
            pull: false,
            push: true,
            maxPushBatches: 100,
            maxDuration: const Duration(minutes: 2),
            isCancelled: () => cancelToken.isCancelled,
            onProgress: (phase, done, total) {
              update('已上传 $done 个变更包…');
            },
          );
        },
      );
      if (result == null) {
        if (mounted) _showSnack('已取消上传，未执行恢复');
        return false;
      }
      if (result.hasErrors || result.remainingLocalOps > 0) {
        if (mounted) {
          _showSnack(
            '本机变更尚未全部上传（剩余 ${result.remainingLocalOps} 条），已取消恢复',
            isError: true,
          );
        }
        return false;
      }
      if (mounted) _showSnack('本机变更已上传');
      return true;
    } catch (e) {
      if (mounted) _showSnack('上传本机变更失败，已取消恢复：$e', isError: true);
      return false;
    }
  }

  Future<void> _restore() async {
    if (_busy) return;
    final service = await _createServiceSafely();
    if (service == null) return;
    if (!mounted) return;

    setState(() => _busy = true);
    try {
      final manifest = await service.fetchDatasetManifest();
      final snapshot = manifest?.latest;
      if (!mounted) return;
      if (manifest == null || snapshot == null) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('云端还没有可用数据'),
            content: const Text('请先在任意一台设备上执行一次同步或上传。'),
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

      final selected = CloudDeviceSummary(
        manifest: manifest,
        isCurrentDevice: true,
      );
      final confirmed = await _confirmRestore(selected);
      if (confirmed != true || !mounted) return;
      if (!await _prepareForRestore()) return;
      if (!mounted) return;

      final outcome = await runWithProgressDialog<CloudRestoreOutcome>(
        context,
        title: '从云端恢复',
        task: (update) async {
          update('正在下载并校验云端数据…');
          final result = await service.restoreLatestDatasetSnapshot(
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
      if (outcome == null) {
        if (!mounted) return;
        _showSnack('已取消恢复');
        return;
      }
      await CloudSyncSettings.saveIntroDecision(
        selected.manifest.deviceId,
        CloudSyncIntroAction.useCloud.storageValue,
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
              '数据时间：${_formatTime(snapshot?.createdAt)}\n'
              '数据大小：${CloudSyncUtils.formatBytes(snapshot?.size ?? 0)}\n'
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
              '数据时间：${_formatTime(snapshot.createdAt)}\n'
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
                  ? '变更捕获已自动开启；建议重启应用后立即执行一次「同步」。'
                  : '警告：变更捕获未开启。请重启应用后先执行一次「同步」，'
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
        if (_intro?.needsDecision == true)
          ListTile(
            leading: Icon(Icons.merge_type, color: colorScheme.tertiary),
            title: const Text('云端数据需要确认'),
            subtitle: const Text('选择合并、以本机为准或以云端为准；确认前不会拉取云端历史'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _busy ? null : _ensureIntroduction,
          ),
        if (_state.versionBlockSignature != null)
          ListTile(
            leading: Icon(Icons.sync_problem_rounded, color: colorScheme.error),
            title: Text('云同步已暂停', style: TextStyle(color: colorScheme.error)),
            subtitle: Text(
              '${_state.versionBlockReason ?? '版本不兼容'}\n'
              '本机新记录仍会保存在本地，升级后自动继续同步。',
            ),
            isThreeLine: true,
            trailing: const Icon(Icons.chevron_right),
            onTap: _busy
                ? null
                : () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => const CloudSyncDevicesPage(),
                    ),
                  ),
          )
        else if (_state.versionWarningSignature != null)
          ListTile(
            leading: Icon(Icons.devices_rounded, color: colorScheme.tertiary),
            title: const Text('设备版本不一致'),
            subtitle: Text(
              _state.versionWarningMessage ?? 'App 版本不同，但数据格式兼容，同步将继续。',
            ),
            isThreeLine: true,
            trailing: const Icon(Icons.chevron_right),
            onTap: _busy
                ? null
                : () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => const CloudSyncDevicesPage(),
                    ),
                  ),
          ),
        ListTile(
          leading: Icon(
            Icons.sync_outlined,
            color: _configured ? colorScheme.primary : colorScheme.outline,
          ),
          title: const Text('同步'),
          subtitle: const Text('自动上传本机变更，并拉取云端最新数据'),
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
          title: const Text('已连接设备'),
          subtitle: const Text('查看哪些设备在使用这份云端数据'),
          enabled: _configured,
          onTap: _configured
              ? () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => const CloudSyncDevicesPage(),
                  ),
                )
              : null,
        ),
        ExpansionTile(
          leading: Icon(
            Icons.settings_backup_restore,
            color: _configured ? colorScheme.primary : colorScheme.outline,
          ),
          title: const Text('高级 / 灾备'),
          subtitle: const Text('手动上传、覆盖恢复；日常同步不需要使用'),
          children: [
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
              subtitle: const Text('把本机数据更新为云端统一数据'),
              enabled: _configured && !_busy,
              onTap: _configured && !_busy ? _upload : null,
            ),
            ListTile(
              leading: Icon(
                Icons.cloud_download_outlined,
                color: _configured ? colorScheme.primary : colorScheme.outline,
              ),
              title: const Text('从云端数据恢复'),
              subtitle: const Text('用云端统一数据覆盖本机（灾备）'),
              enabled: _configured && !_busy,
              onTap: _configured && !_busy ? _restore : null,
            ),
          ],
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
            '云端只保存一份统一数据；所有设备都同步这一份数据。\n'
            '首次把已有本地数据的设备接入时，只会询问一次：合并两端、以本机为准或以云端为准。\n'
            '「同步」负责日常增量上传/拉取；「立即上传备份」会把本机数据更新为云端统一数据。\n'
            '覆盖恢复仅用于灾备，恢复前会自动保留本机安全副本。',
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
class _IntroOption extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _IntroOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}
