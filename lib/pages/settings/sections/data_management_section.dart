import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../../services/backup_service.dart';
import '../../../services/log_service.dart';
import '../settings_section_header.dart';

/// 数据管理分区（导出 / 导入 / 清除）
class DataManagementSection extends StatefulWidget {
  const DataManagementSection({super.key});

  @override
  State<DataManagementSection> createState() => _DataManagementSectionState();
}

class _DataManagementSectionState extends State<DataManagementSection> {
  static const XTypeGroup _zipTypeGroup = XTypeGroup(
    label: 'ZIP 备份',
    extensions: ['zip'],
  );

  bool _isClearing = false;

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
      logInfo('DataManagement', '开始导出数据备份 includeApiKeys=$includeKeys');
      bytes = await BackupService.exportBackup(includeApiKeys: includeKeys);
    } catch (e) {
      logError('DataManagement', '导出数据备份失败: $e');
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

    logInfo('DataManagement', '开始导入数据备份: ${file.name}');
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
      logInfo('DataManagement', '数据导入成功');
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
      logError('DataManagement', '数据导入失败: $e');
      if (context.mounted) {
        _showResultSnackBar(context, '导入失败：$e', isSuccess: false);
      }
    }
  }

  /// 清除全部数据 — 三步确认流程
  Future<void> _clearAllData(BuildContext context) async {
    // ── 第1步：警告对话框 ──
    final step1 = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(
          Icons.warning_amber_rounded,
          color: Theme.of(context).colorScheme.error,
          size: 40,
        ),
        title: const Text('清除全部数据'),
        content: const Text(
          '此操作将永久删除以下所有数据，且无法恢复：\n\n'
          '• 所有词书及单词记录\n'
          '• 学习记录与复习计划\n'
          '• 句子练习记录与错题本\n'
          '• 单词收藏与笔记\n'
          '• 学习时长统计\n'
          '• 所有设置（包括 API Key）\n\n'
          '建议在清除前先导出一份备份。',
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
            child: const Text('下一步'),
          ),
        ],
      ),
    );
    if (step1 != true || !context.mounted) return;

    // ── 第2步：等待 5 秒后才能点击确认 ──
    final step2 = await showDialog<bool>(
      context: context,
      builder: (context) => _CountdownConfirmDialog(),
    );
    if (step2 != true || !context.mounted) return;

    // ── 第3步：输入"确认清除全部数据" ──
    final step3 = await showDialog<bool>(
      context: context,
      builder: (context) => _TypeToConfirmDialog(),
    );
    if (step3 != true || !context.mounted) return;

    // ── 执行清除 ──
    setState(() => _isClearing = true);
    try {
      await BackupService.clearAllData();
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.check_circle, color: Colors.green),
          title: const Text('数据已清除'),
          content: const Text('所有数据已成功清除。\n\n为避免异常，请重启应用后再使用。'),
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
        _showResultSnackBar(context, '清除失败：$e', isSuccess: false);
      }
    } finally {
      if (mounted) {
        setState(() => _isClearing = false);
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
        ListTile(
          leading: _isClearing
              ? SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: colorScheme.error,
                  ),
                )
              : Icon(Icons.delete_forever_outlined, color: colorScheme.error),
          title: Text('清除全部数据', style: TextStyle(color: colorScheme.error)),
          subtitle: const Text('永久删除所有词书、学习记录与设置'),
          onTap: _isClearing ? null : () => _clearAllData(context),
        ),
      ],
    );
  }
}

/// 第2步：带 5 秒倒计时的确认对话框
class _CountdownConfirmDialog extends StatefulWidget {
  @override
  State<_CountdownConfirmDialog> createState() =>
      _CountdownConfirmDialogState();
}

class _CountdownConfirmDialogState extends State<_CountdownConfirmDialog> {
  int _secondsLeft = 5;

  @override
  void initState() {
    super.initState();
    _startCountdown();
  }

  void _startCountdown() async {
    for (var i = 5; i > 0; i--) {
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted) return;
      setState(() => _secondsLeft = i - 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canProceed = _secondsLeft <= 0;

    return AlertDialog(
      title: const Text('再次确认'),
      content: const Text(
        '此操作不可撤销，所有数据将被永久删除。\n\n'
        '如果还没有备份，请先取消并导出一份备份。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: canProceed ? () => Navigator.pop(context, true) : null,
          style: canProceed
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                )
              : null,
          child: Text(canProceed ? '我已了解，继续' : '请等待 ${_secondsLeft}s'),
        ),
      ],
    );
  }
}

/// 第3步：输入"确认清除全部数据"对话框
class _TypeToConfirmDialog extends StatefulWidget {
  @override
  State<_TypeToConfirmDialog> createState() => _TypeToConfirmDialogState();
}

class _TypeToConfirmDialogState extends State<_TypeToConfirmDialog> {
  static const String _confirmPhrase = '确认清除全部数据';
  final TextEditingController _controller = TextEditingController();
  bool _isMatch = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('最终确认'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '请在下方输入框中输入 $_confirmPhrase 以完成操作：',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: InputDecoration(
              hintText: _confirmPhrase,
              border: const OutlineInputBorder(),
            ),
            onChanged: (value) {
              setState(() => _isMatch = value == _confirmPhrase);
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _isMatch ? () => Navigator.pop(context, true) : null,
          style: _isMatch
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                )
              : null,
          child: const Text('清除'),
        ),
      ],
    );
  }
}
