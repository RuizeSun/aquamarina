import 'package:flutter/material.dart';

import '../../services/cloud/cloud_sync_bootstrap_service.dart';
import '../../services/cloud/cloud_sync_introduction_service.dart';
import '../../services/cloud/cloud_sync_service.dart';
import '../../services/cloud/cloud_sync_settings.dart';
import 'cloud_sync_progress.dart';

/// 新设备首次配置后的引导：本机没有业务数据且云端已有快照时，询问是否立即引导。
///
/// 对象存储配置页保存成功后、二维码扫码导入成功后都会走这里，保证两条入口
/// 的引导行为完全一致（文案、跳过条件、进度弹窗与错误提示）。
///
/// 返回 true 表示确实执行了一次引导。
Future<bool> maybeBootstrapFromCloud(
  BuildContext context, {
  required void Function(String message, {bool isError}) showMessage,
}) async {
  try {
    if (await CloudSyncBootstrapService.hasLocalData()) return false;
    final candidate = await CloudSyncBootstrapService.findLatestSnapshot();
    if (candidate == null || !context.mounted) return false;
    final summary = candidate.summary;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('发现云端数据'),
        content: Text(
          '本机还没有学习数据，云端已有一份统一数据'
          '（${summary.latest!.createdAt.toLocal()}）。\n\n'
          '是否立即用云端数据初始化本机？当前空库不会丢失任何学习记录。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('稍后手动恢复'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('立即引导'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return false;
    await runWithProgressDialog<CloudRestoreOutcome>(
      context,
      title: '从云端引导',
      task: (update) async {
        update('正在下载并校验云端数据…');
        return candidate.service.restoreSnapshot(summary);
      },
    );
    await CloudSyncSettings.saveIntroDecision(
      summary.manifest.deviceId,
      CloudSyncIntroAction.useCloud.storageValue,
    );
    if (context.mounted) {
      showMessage('已从云端引导，建议重启应用', isError: false);
    }
    return true;
  } catch (e) {
    if (context.mounted) {
      showMessage('自动引导失败：$e', isError: true);
    }
    return false;
  }
}

/// 扫描 / 导入成功后，按导入结果给出下一步提示所需的文案。
String shareImportResultMessage({
  required bool hasCredentials,
  required bool backendChanged,
  required bool credentialsCleared,
}) {
  if (credentialsCleared) {
    return '已导入云端配置，并清除了原本保存的访问密钥。请补填 Access Key / Secret Key。';
  }
  if (!hasCredentials) {
    return '已导入云端配置。二维码不包含密钥，请补填 Access Key / Secret Key。';
  }
  if (backendChanged) {
    return '已导入云端配置；后端已切换，首次同步时会重新建立同步基线。';
  }
  return '已导入云端配置；配置与本机原先一致。';
}
