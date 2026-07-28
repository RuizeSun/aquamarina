import 'dart:async';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/ai_profile.dart';
import '../services/ai_profile_service.dart';
import 'ai_profile_edit_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  int _reviewLimit = 10;
  int _learningLimit = 10;

  // AI 配置管理
  final AiProfileService _profileService = AiProfileService();

  static const String _reviewLimitKey = 'review_limit';
  static const String _learningLimitKey = 'learning_limit';

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _profileService.addListener(_onProfilesChanged);
  }

  @override
  void dispose() {
    _profileService.removeListener(_onProfilesChanged);
    super.dispose();
  }

  void _onProfilesChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _reviewLimit = prefs.getInt(_reviewLimitKey) ?? 10;
      _learningLimit = prefs.getInt(_learningLimitKey) ?? 10;
    });
    await prefs.setInt(_reviewLimitKey, _reviewLimit);
    await prefs.setInt(_learningLimitKey, _learningLimit);

    // 加载 AI 配置
    await _profileService.load();
    if (mounted) setState(() {});
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

  // ===== AI 配置文件管理 =====

  Future<void> _addNewProfile() async {
    final result = await showModalBottomSheet<AiProfileTemplate>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  '选择配置模板',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.auto_awesome, color: Colors.green),
                title: const Text('OpenAI 官方'),
                subtitle: const Text('gpt-4o-mini · api.openai.com'),
                onTap: () =>
                    Navigator.of(context).pop(AiProfileTemplate.openaiOfficial),
              ),
              ListTile(
                leading: const Icon(Icons.auto_awesome, color: Colors.blue),
                title: const Text('DeepSeek 官方'),
                subtitle: const Text('deepseek-chat · api.deepseek.com'),
                onTap: () => Navigator.of(
                  context,
                ).pop(AiProfileTemplate.deepseekOfficial),
              ),
              ListTile(
                leading: const Icon(Icons.add_circle_outline),
                title: const Text('自定义配置'),
                subtitle: const Text('手动输入所有参数'),
                onTap: () =>
                    Navigator.of(context).pop(AiProfileTemplate.custom),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );

    if (result == null || !mounted) return;

    final profile = createProfileFromTemplate(result);
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (context) => AiProfileEditPage(
          profileService: _profileService,
          profile: profile,
          isNew: true,
        ),
      ),
    );
  }

  Future<void> _editProfile(AiProfile profile) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (context) => AiProfileEditPage(
          profileService: _profileService,
          profile: profile,
        ),
      ),
    );
  }

  Future<void> _setDefaultProfile(String id) async {
    await _profileService.setDefault(id);
  }

  Future<void> _deleteProfile(AiProfile profile) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('删除配置'),
          content: Text('确定要删除「${profile.name}」吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
              ),
              child: const Text('删除'),
            ),
          ],
        );
      },
    );

    if (confirm == true) {
      await _profileService.deleteProfile(profile.id);
    }
  }

  Future<void> _testConnection(AiProfile profile) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('正在测试连接...'),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      final result = await _profileService.testConnection(profile);
      if (!mounted) return;
      Navigator.of(context).pop();
      _showResultSnackBar(result, isSuccess: true);
    } on AiConfigException catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      _showResultSnackBar(e.toString(), isSuccess: false);
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      _showResultSnackBar('连接失败：$e', isSuccess: false);
    }
  }

  void _showResultSnackBar(String message, {required bool isSuccess}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isSuccess ? Colors.green : Colors.red,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ===== Build =====

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final profiles = _profileService.profiles;
    final defaultProfile = _profileService.defaultProfile;

    return Scaffold(
      appBar: AppBar(title: const Text('设置'), centerTitle: false),
      body: ListView(
        children: [
          const SizedBox(height: 8),

          // ---- 背单词设置 ----
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

          // ---- AI 配置文件 ----
          _SectionHeader(title: 'AI 服务配置'),
          if (profiles.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Column(
                children: [
                  Icon(
                    Icons.cloud_off,
                    size: 48,
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '暂无配置文件',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '点击下方按钮添加 AI 配置',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.7,
                      ),
                    ),
                  ),
                ],
              ),
            )
          else
            ...profiles.map(
              (profile) => _buildProfileTile(
                profile,
                defaultProfile,
                theme,
                colorScheme,
              ),
            ),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: OutlinedButton.icon(
              onPressed: _addNewProfile,
              icon: const Icon(Icons.add),
              label: const Text('添加配置'),
            ),
          ),

          const Divider(),

          // ---- 关于 ----
          ListTile(
            leading: Icon(Icons.info_outline, color: colorScheme.primary),
            title: const Text('关于 Aquamarina'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showAbout(context),
          ),
        ],
      ),
    );
  }

  Widget _buildProfileTile(
    AiProfile profile,
    AiProfile? defaultProfile,
    ThemeData theme,
    ColorScheme colorScheme,
  ) {
    final isDefault = profile.isDefault;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: InkWell(
        onTap: () => _editProfile(profile),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            children: [
              // 类型图标
              CircleAvatar(
                radius: 18,
                backgroundColor: profile.isDeepSeek
                    ? Colors.blue.withValues(alpha: 0.15)
                    : Colors.green.withValues(alpha: 0.15),
                child: Icon(
                  profile.isDeepSeek ? Icons.psychology : Icons.auto_awesome,
                  size: 20,
                  color: profile.isDeepSeek ? Colors.blue : Colors.green,
                ),
              ),
              const SizedBox(width: 12),

              // 名称和详情
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          profile.name,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (isDefault) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '默认',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: colorScheme.onPrimaryContainer,
                                fontSize: 10,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      profile.model,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      profile.baseUrl,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.7,
                        ),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),

              // 操作按钮
              PopupMenuButton<String>(
                onSelected: (value) async {
                  switch (value) {
                    case 'edit':
                      _editProfile(profile);
                    case 'test':
                      _testConnection(profile);
                    case 'setDefault':
                      _setDefaultProfile(profile.id);
                    case 'delete':
                      _deleteProfile(profile);
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'edit',
                    child: ListTile(
                      leading: Icon(Icons.edit),
                      title: Text('编辑'),
                      dense: true,
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'test',
                    child: ListTile(
                      leading: Icon(Icons.wifi_find),
                      title: Text('测试连接'),
                      dense: true,
                    ),
                  ),
                  if (!isDefault)
                    const PopupMenuItem(
                      value: 'setDefault',
                      child: ListTile(
                        leading: Icon(Icons.star),
                        title: Text('设为默认'),
                        dense: true,
                      ),
                    ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: ListTile(
                      leading: Icon(Icons.delete, color: Colors.red),
                      title: Text('删除', style: TextStyle(color: Colors.red)),
                      dense: true,
                    ),
                  ),
                ],
                icon: Icon(
                  Icons.more_vert,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showAbout(BuildContext context) async {
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
