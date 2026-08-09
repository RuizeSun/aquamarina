import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../../services/backup_service.dart';
import '../settings_section_header.dart';

/// 数据管理分区（导出 / 导入）
class DataManagementSection extends StatelessWidget {
  const DataManagementSection({super.key});

  static const XTypeGroup _zipTypeGroup = XTypeGroup(
    label: 'ZIP 备份',
    extensions: ['zip'],
  );

  /// 生成备份文件名时间戳，如 `20260101_1430`
  String _backupTimeStamp() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}'
        '_${two(now.hour)}${two(now.minute)}';
  }

  void _showResultSnackBar(
    BuildContext context,
    String message, {
    required bool isSuccess,
  }) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isSuccess ? Colors.green : Colors.red,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// 导出数据备份
  Future<void> _exportData(BuildContext context) async {
    // 1. 询问是否包含 API Keys
    final includeKeys = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导出数据'),
        content: const Text(
          '将导出词书、学习记录、句子练习与所有设置。\n\n'
          '是否同时包含 AI 服务的 API Key？\n'
          '（API Key 为敏感信息，请妥善保管备份文件）',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('不包含'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('包含'),
          ),
        ],
      ),
    );
    if (includeKeys == null || !context.mounted) return;

    // 2. 生成备份数据
    final Uint8List bytes;
    try {
      bytes = await BackupService.exportBackup(includeApiKeys: includeKeys);
    } catch (e) {
      if (context.mounted) {
        _showResultSnackBar(context, '导出失败：$e', isSuccess: false);
      }
      return;
    }

    final fileName = 'aquamarina_backup_${_backupTimeStamp()}.zip';

    // 3. 保存文件
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      // 手机端：保存到临时目录后调用系统分享面板，
      // 让用户自由选择保存到 Downloads、发送到邮件/云盘等
      final tmpDir = await getTemporaryDirectory();
      final tmpPath = p.join(tmpDir.path, fileName);
      final tmpFile = await File(tmpPath).writeAsBytes(bytes, flush: true);
      if (!context.mounted) return;

      try {
        final result = await SharePlus.instance.share(
          ShareParams(files: [XFile(tmpPath)], subject: fileName),
        );
        if (!context.mounted) return;

        if (result.status == ShareResultStatus.success ||
            result.status == ShareResultStatus.dismissed) {
          _showResultSnackBar(context, '导出完成', isSuccess: true);
        }
      } finally {
        // 清理临时文件
        if (await tmpFile.exists()) {
          await tmpFile.delete();
        }
      }
    } else {
      // 桌面端：使用系统文件保存对话框
      FileSaveLocation? saveLocation;
      try {
        saveLocation = await getSaveLocation(
          suggestedName: fileName,
          acceptedTypeGroups: const [_zipTypeGroup],
        );
      } catch (_) {
        // 平台不支持文件保存对话框时回退到应用文档目录
        try {
          final docsDir = await getApplicationDocumentsDirectory();
          final fallbackPath = p.join(docsDir.path, fileName);
          await File(fallbackPath).writeAsBytes(bytes, flush: true);
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('导出成功，已保存到：\n$fallbackPath'),
                behavior: SnackBarBehavior.floating,
                duration: const Duration(seconds: 6),
              ),
            );
          }
        } catch (e) {
          if (context.mounted) {
            _showResultSnackBar(context, '保存失败：$e', isSuccess: false);
          }
        }
        return;
      }
      if (saveLocation == null) return; // 用户取消

      try {
        await File(saveLocation.path).writeAsBytes(bytes, flush: true);
      } catch (e) {
        if (context.mounted) {
          _showResultSnackBar(context, '保存失败：$e', isSuccess: false);
        }
        return;
      }
      if (context.mounted) {
        _showResultSnackBar(
          context,
          '导出成功：${p.basename(saveLocation.path)}',
          isSuccess: true,
        );
      }
    }
  }

  /// 从备份文件导入数据（覆盖式）
  Future<void> _importData(BuildContext context) async {
    final XFile? file;
    try {
      file = await openFile(acceptedTypeGroups: const [_zipTypeGroup]);
    } catch (_) {
      if (context.mounted) {
        _showResultSnackBar(context, '无法打开文件选择器', isSuccess: false);
      }
      return;
    }
    if (file == null) return; // 用户取消

    final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (e) {
      if (context.mounted) {
        _showResultSnackBar(context, '读取文件失败：$e', isSuccess: false);
      }
      return;
    }
    if (!context.mounted) return;

    // 确认覆盖；选择否则退出导入
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导入数据'),
        content: const Text(
          '导入将覆盖当前所有数据（词书、学习记录、句子练习、设置等），'
          '且无法撤销。\n\n确定要继续吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('覆盖并导入'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    try {
      final result = await BackupService.importBackup(bytes);
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.check_circle, color: Colors.green),
          title: const Text('导入成功'),
          content: Text(
            '数据库与设置已恢复。\n'
            '${result.restoredApiKeys ? '' : '备份中不包含 API Key，如有需要请重新填写。\n'}'
            '\n为避免异常，请重启应用后再使用。',
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
      if (context.mounted) {
        _showResultSnackBar(context, '导入失败：$e', isSuccess: false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsSectionHeader(title: '数据管理'),
        ListTile(
          leading: Icon(Icons.upload_outlined, color: colorScheme.primary),
          title: const Text('导出数据'),
          subtitle: const Text('备份词书、学习记录与设置到 ZIP 文件'),
          onTap: () => _exportData(context),
        ),
        ListTile(
          leading: Icon(Icons.download_outlined, color: colorScheme.primary),
          title: const Text('导入数据'),
          subtitle: const Text('从 ZIP 备份恢复数据（覆盖当前数据）'),
          onTap: () => _importData(context),
        ),
      ],
    );
  }
}
