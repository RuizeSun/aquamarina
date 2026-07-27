import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  int _reviewLimit = 5;
  int _learningLimit = 5;

  static const String _reviewLimitKey = 'review_limit';
  static const String _learningLimitKey = 'learning_limit';

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _reviewLimit = prefs.getInt(_reviewLimitKey) ?? 5;
      _learningLimit = prefs.getInt(_learningLimitKey) ?? 5;
    });
  }

  Future<void> _setReviewLimit(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_reviewLimitKey, value);
    setState(() => _reviewLimit = value);
  }

  Future<void> _setLearningLimit(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_learningLimitKey, value);
    setState(() => _learningLimit = value);
  }

  void _showReviewLimitPicker() {
    _showLimitPicker(
      title: '单次复习上限',
      current: _reviewLimit,
      onSave: _setReviewLimit,
    );
  }

  void _showLearningLimitPicker() {
    _showLimitPicker(
      title: '单次学习上限',
      current: _learningLimit,
      onSave: _setLearningLimit,
    );
  }

  void _showLimitPicker({
    required String title,
    required int current,
    required Future<void> Function(int) onSave,
  }) {
    int temp = current;
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(title),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('当前值: $temp'),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.remove_circle_outline),
                          onPressed: temp > 1
                              ? () => setDialogState(() => temp--)
                              : null,
                        ),
                        const SizedBox(width: 16),
                        Text(
                          '$temp',
                          style: Theme.of(context).textTheme.headlineMedium
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(width: 16),
                        IconButton(
                          icon: const Icon(Icons.add_circle_outline),
                          onPressed: temp < 100
                              ? () => setDialogState(() => temp++)
                              : null,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () {
                    onSave(temp);
                    Navigator.of(context).pop();
                  },
                  child: const Text('确认'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('设置'), centerTitle: false),
      body: ListView(
        children: [
          const SizedBox(height: 8),

          _SectionHeader(title: '背单词设置'),
          ListTile(
            leading: Icon(Icons.replay, color: colorScheme.primary),
            title: const Text('单次复习上限'),
            subtitle: Text('每次复习最多 $_reviewLimit 个单词'),
            trailing: Text(
              '$_reviewLimit',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: colorScheme.primary,
              ),
            ),
            onTap: _showReviewLimitPicker,
          ),
          ListTile(
            leading: Icon(Icons.auto_stories, color: colorScheme.primary),
            title: const Text('单次学习上限'),
            subtitle: Text('每次学习最多 $_learningLimit 个新词'),
            trailing: Text(
              '$_learningLimit',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: colorScheme.primary,
              ),
            ),
            onTap: _showLearningLimitPicker,
          ),

          const Divider(),

          // 开源许可证
          _SectionHeader(title: '信息'),
          ListTile(
            leading: Icon(
              Icons.description_outlined,
              color: colorScheme.primary,
            ),
            title: const Text('开源许可证'),
            subtitle: const Text('ecdict · CC-CEDICT'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showLicenses(context),
          ),

          const Divider(),

          _SectionHeader(title: '关于'),
          ListTile(
            leading: Icon(Icons.info_outline, color: colorScheme.primary),
            title: const Text('Aquamarina'),
            subtitle: const Text('v1.0.0'),
          ),
          ListTile(
            leading: Icon(Icons.code, color: colorScheme.primary),
            title: const Text('Flutter'),
            subtitle: Text(
              Theme.of(context).platform == TargetPlatform.android
                  ? 'Android'
                  : Theme.of(context).platform == TargetPlatform.iOS
                  ? 'iOS'
                  : 'Windows',
            ),
          ),
        ],
      ),
    );
  }

  void _showLicenses(BuildContext context) {
    showLicensePage(
      context: context,
      applicationName: 'Aquamarina',
      applicationVersion: 'v1.0.0',
      applicationLegalese: 'Copyright © 2026 Aquamarina',
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
