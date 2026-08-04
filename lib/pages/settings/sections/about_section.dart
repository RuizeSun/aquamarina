import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// 关于分区
class AboutSection extends StatelessWidget {
  const AboutSection({super.key});

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

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
