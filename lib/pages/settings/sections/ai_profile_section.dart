import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../models/ai_profile.dart';
import '../../../services/ai_profile_service.dart';
import '../../ai_profile_edit_page.dart';

/// 隐私政策 SharedPreferences 键前缀（与 ai_practice_page.dart 保持一致）
const String _privacyPolicyKeyPrefix = 'privacy_policy_accepted_';
const String _aquamarinaOfficialHost = 'aquamarina.78go.work';

/// AI 服务配置分区（配置文件增删改查、测试连接、隐私撤销）
class AiProfileSection extends StatefulWidget {
  const AiProfileSection({super.key});

  @override
  State<AiProfileSection> createState() => _AiProfileSectionState();
}

class _AiProfileSectionState extends State<AiProfileSection> {
  // AI 配置管理
  final AiProfileService _profileService = AiProfileService();

  @override
  void initState() {
    super.initState();
    _profileService.addListener(_onProfilesChanged);
    _profileService.load();
  }

  @override
  void dispose() {
    _profileService.removeListener(_onProfilesChanged);
    super.dispose();
  }

  void _onProfilesChanged() {
    if (mounted) setState(() {});
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
                leading: const Icon(Icons.water_drop, color: Colors.teal),
                title: const Text('Aquamarina 官方'),
                subtitle: const Text('默认 · aquamarina.78go.work'),
                onTap: () => Navigator.of(
                  context,
                ).pop(AiProfileTemplate.aquamarinaOfficial),
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

  Future<void> _revokePrivacyPolicy(AiProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_privacyPolicyKeyPrefix${profile.id}';
    await prefs.remove(key);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已撤销隐私政策授权'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final profiles = _profileService.profiles;
    final defaultProfile = _profileService.defaultProfile;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          )
        else
          ...profiles.map(
            (profile) =>
                _buildProfileTile(profile, defaultProfile, theme, colorScheme),
          ),

        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: OutlinedButton.icon(
            onPressed: _addNewProfile,
            icon: const Icon(Icons.add),
            label: const Text('添加配置'),
          ),
        ),
      ],
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
                    case 'revokePrivacy':
                      await _revokePrivacyPolicy(profile);
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
                  // Aquamarina 官方配置：撤销隐私政策授权
                  if (profile.isAquamarina &&
                      profile.baseUrl.contains(_aquamarinaOfficialHost))
                    PopupMenuItem(
                      value: 'revokePrivacy',
                      child: const ListTile(
                        leading: Icon(Icons.privacy_tip_outlined),
                        title: Text('撤销隐私政策授权'),
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
}
