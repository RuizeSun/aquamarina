import 'package:flutter/material.dart';
import '../../../services/log_service.dart';
import '../log_viewer_page.dart';

/// 日志设置分区
class LoggingSection extends StatelessWidget {
  const LoggingSection({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            '日志设置',
            style: theme.textTheme.labelLarge?.copyWith(
              color: colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        ValueListenableBuilder<LogLevel>(
          valueListenable: LogService.instance.minLevel,
          builder: (context, currentLevel, _) {
            return ListTile(
              leading: Icon(Icons.tune, color: colorScheme.primary),
              title: const Text('最低日志等级'),
              subtitle: Text(
                '当前: ${currentLevel.label}',
                style: TextStyle(color: colorScheme.primary),
              ),
              trailing: SegmentedButton<LogLevel>(
                segments: const [
                  ButtonSegment(
                    value: LogLevel.debug,
                    label: Text('DEBUG', style: TextStyle(fontSize: 11)),
                  ),
                  ButtonSegment(
                    value: LogLevel.info,
                    label: Text('INFO', style: TextStyle(fontSize: 11)),
                  ),
                  ButtonSegment(
                    value: LogLevel.warning,
                    label: Text('WARN', style: TextStyle(fontSize: 11)),
                  ),
                  ButtonSegment(
                    value: LogLevel.error,
                    label: Text('ERROR', style: TextStyle(fontSize: 11)),
                  ),
                ],
                selected: {currentLevel},
                onSelectionChanged: (selected) {
                  LogService.instance.setMinLevel(selected.first);
                },
                showSelectedIcon: false,
                style: ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            );
          },
        ),
        ListTile(
          leading: Icon(Icons.article_outlined, color: colorScheme.primary),
          title: const Text('查看日志'),
          subtitle: ValueListenableBuilder<int>(
            valueListenable: LogService.instance.logCount,
            builder: (context, count, _) => Text('共 $count 条日志'),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const LogViewerPage()),
            );
          },
        ),
        ListTile(
          leading: Icon(Icons.share_outlined, color: colorScheme.primary),
          title: const Text('导出日志'),
          subtitle: const Text('将日志保存为文本文件'),
          onTap: () async {
            final messenger = ScaffoldMessenger.of(context);
            final success = await LogService.instance.exportAndShare();
            if (!context.mounted) return;
            messenger.showSnackBar(
              SnackBar(
                content: Text(success ? '日志导出成功' : '暂无日志可导出'),
                behavior: SnackBarBehavior.floating,
              ),
            );
          },
        ),
        ListTile(
          leading: Icon(Icons.delete_outline, color: colorScheme.error),
          title: const Text('清空日志'),
          subtitle: const Text('清除内存中所有日志记录'),
          onTap: () async {
            final confirmed = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('清空日志'),
                content: const Text('确定要清空所有日志记录吗？'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('清空'),
                  ),
                ],
              ),
            );
            if (confirmed == true) {
              LogService.instance.clear();
            }
          },
        ),
      ],
    );
  }
}

