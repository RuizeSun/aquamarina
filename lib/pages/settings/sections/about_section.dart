import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../../../services/update_service.dart';

/// 关于分区
class AboutSection extends StatefulWidget {
  const AboutSection({super.key});

  @override
  State<AboutSection> createState() => _AboutSectionState();
}

class _AboutSectionState extends State<AboutSection> {
  UpdateChannel _channel = UpdateChannel.latest;

  @override
  void initState() {
    super.initState();
    _loadChannel();
  }

  Future<void> _loadChannel() async {
    final channel = await UpdateService.getUpdateChannel();
    if (mounted) setState(() => _channel = channel);
  }

  Future<void> _setChannel(UpdateChannel channel) async {
    await UpdateService.setUpdateChannel(channel);
    if (mounted) setState(() => _channel = channel);
  }

  Future<void> _showAbout(BuildContext context) async {
    final platform = Theme.of(context).platform == TargetPlatform.android
        ? 'Android'
        : Theme.of(context).platform == TargetPlatform.iOS
        ? 'iOS'
        : 'Windows';
    final info = await PackageInfo.fromPlatform();
    final version = 'v${info.version}';
    if (!context.mounted) return;
    showAboutDialog(
      context: context,
      applicationName: info.appName,
      applicationVersion: version,
      applicationLegalese: '当前平台: $platform',
    );
  }

  Future<void> _checkUpdate(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);

    // 显示加载指示
    messenger.showSnackBar(
      const SnackBar(
        content: Text('正在检查更新...'),
        duration: Duration(seconds: 2),
      ),
    );

    final updateInfo = await UpdateService.checkForUpdate(
      force: true,
      bypassChannel: true,
    );

    if (!context.mounted) return;

    if (updateInfo != null) {
      _showUpdateDialog(context, updateInfo);
    } else {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        const SnackBar(
          content: Text('当前已是最新版本'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  void _showUpdateDialog(BuildContext context, UpdateInfo updateInfo) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(
          Icons.system_update_rounded,
          color: colorScheme.primary,
          size: 36,
        ),
        title: Text('发现新版本 ${updateInfo.latestVersion}'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '当前版本: ${updateInfo.currentVersion}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '更新日志',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                updateInfo.release.body.isNotEmpty
                    ? updateInfo.release.body
                    : '暂无更新日志',
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              UpdateService.setSkippedVersion(updateInfo.latestVersion);
              Navigator.of(context).pop();
            },
            child: const Text('跳过此版本'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('稍后提醒'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              UpdateService.launchUpdate(updateInfo);
            },
            child: const Text('立即更新'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: Icon(
            Icons.system_update_outlined,
            color: colorScheme.primary,
          ),
          title: const Text('检查更新'),
          subtitle: const Text('查看是否有新版本可用'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _checkUpdate(context),
        ),
        ListTile(
          leading: Icon(
            Icons.notifications_outlined,
            color: colorScheme.primary,
          ),
          title: const Text('新版本推送'),
          subtitle: Text(
            _channel == UpdateChannel.stable
                ? '仅提示重大版本更新'
                : _channel == UpdateChannel.latest
                ? '提示所有版本更新'
                : '已关闭自动更新提醒',
          ),
          trailing: SegmentedButton<UpdateChannel>(
            segments: const [
              ButtonSegment(value: UpdateChannel.stable, label: Text('稳定')),
              ButtonSegment(value: UpdateChannel.latest, label: Text('最新')),
              ButtonSegment(value: UpdateChannel.off, label: Text('关闭')),
            ],
            selected: {_channel},
            onSelectionChanged: (selected) => _setChannel(selected.first),
            showSelectedIcon: false,
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ),
        ListTile(
          leading: Icon(Icons.info_outline, color: colorScheme.primary),
          title: const Text('关于 Aquamarina'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _showAbout(context),
        ),
      ],
    );
  }
}
