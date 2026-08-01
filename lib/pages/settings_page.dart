import 'dart:async';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/ai_profile.dart';
import '../services/ai_profile_service.dart';
import '../models/ai_sentence.dart';
import '../services/ai_sentence_service.dart';
import '../services/tts_settings.dart';
import '../services/tts_service.dart';
import '../services/theme_mode_service.dart';
import 'ai_profile_edit_page.dart';

/// 隐私政策 SharedPreferences 键前缀（与 ai_practice_page.dart 保持一致）
const String _privacyPolicyKeyPrefix = 'privacy_policy_accepted_';
const String _aquamarinaOfficialHost = 'aquamarina.78go.work';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  int _reviewLimit = 10;
  int _learningLimit = 10;
  bool _reviewAskBook = true;

  // AI 配置管理
  final AiProfileService _profileService = AiProfileService();

  static const String _reviewLimitKey = 'review_limit';
  static const String _learningLimitKey = 'learning_limit';
  static const String _reviewAskBookKey = 'review_ask_book';

  /// 预设主题色（用于设置页色板）
  static const List<Color> _presetSeedColors = [
    Color(0xFF00BFA5), // 青绿（默认）
    Color(0xFF2196F3), // 蓝
    Color(0xFF3F51B5), // 靛蓝
    Color(0xFF7E57C2), // 紫
    Color(0xFFEC407A), // 粉
    Color(0xFFE53935), // 红
    Color(0xFFFF7043), // 橙
    Color(0xFFFFB300), // 琥珀
    Color(0xFF43A047), // 绿
    Color(0xFF00ACC1), // 青
  ];

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
      _reviewAskBook = prefs.getBool(_reviewAskBookKey) ?? true;
    });
    await prefs.setInt(_reviewLimitKey, _reviewLimit);
    await prefs.setInt(_learningLimitKey, _learningLimit);
    await prefs.setBool(_reviewAskBookKey, _reviewAskBook);

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

  Future<void> _setReviewAskBook(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_reviewAskBookKey, value);
    setState(() => _reviewAskBook = value);
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

  // ===== 主题色设置 =====

  void _showThemeColorPicker() {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final currentSeed = ThemeModeService.instance.seedColor.value;
            final outlineVariant = Theme.of(context).colorScheme.outlineVariant;
            return SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 16, 16, 12),
                    child: Text(
                      '选择主题色',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      alignment: WrapAlignment.center,
                      children: [
                        ..._presetSeedColors.map((color) {
                          final isSelected = color == currentSeed;
                          return GestureDetector(
                            onTap: () {
                              ThemeModeService.instance.setSeedColor(color);
                              setSheetState(() {});
                            },
                            child: Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: color,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: isSelected
                                      ? Theme.of(context).colorScheme.primary
                                      : outlineVariant,
                                  width: isSelected ? 3 : 1,
                                ),
                              ),
                              child: isSelected
                                  ? const Icon(
                                      Icons.check,
                                      color: Colors.white,
                                      size: 20,
                                    )
                                  : null,
                            ),
                          );
                        }),
                        // 自定义颜色入口
                        GestureDetector(
                          onTap: () {
                            Navigator.of(context).pop();
                            _showCustomColorPicker();
                          },
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white.withValues(alpha: 0.1),
                              border: Border.all(
                                color: Theme.of(context).colorScheme.primary,
                                width: 2,
                              ),
                            ),
                            child: const Icon(Icons.colorize, size: 20),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showCustomColorPicker() {
    var hsv = HSVColor.fromColor(ThemeModeService.instance.seedColor.value);
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('自定义主题色'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 颜色预览
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: hsv.toColor(),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  // 色相
                  Row(
                    children: [
                      const Icon(Icons.color_lens, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Slider(
                          value: hsv.hue,
                          min: 0,
                          max: 360,
                          onChanged: (value) {
                            setDialogState(() => hsv = hsv.withHue(value));
                          },
                        ),
                      ),
                    ],
                  ),
                  // 饱和度
                  Row(
                    children: [
                      const Icon(Icons.opacity, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Slider(
                          value: hsv.saturation,
                          min: 0,
                          max: 1,
                          onChanged: (value) {
                            setDialogState(
                              () => hsv = hsv.withSaturation(value),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                  // 明度
                  Row(
                    children: [
                      const Icon(Icons.brightness_6, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Slider(
                          value: hsv.value,
                          min: 0,
                          max: 1,
                          onChanged: (value) {
                            setDialogState(() => hsv = hsv.withValue(value));
                          },
                        ),
                      ),
                    ],
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
                    ThemeModeService.instance.setSeedColor(hsv.toColor());
                    Navigator.of(context).pop();
                  },
                  child: const Text('应用'),
                ),
              ],
            );
          },
        );
      },
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

          // ---- 外观设置 ----
          _SectionHeader(title: '外观设置'),
          ValueListenableBuilder<ThemeMode>(
            valueListenable: ThemeModeService.instance.mode,
            builder: (context, themeMode, _) {
              return ListTile(
                leading: Icon(
                  themeMode == ThemeMode.dark
                      ? Icons.dark_mode
                      : themeMode == ThemeMode.light
                      ? Icons.light_mode
                      : Icons.brightness_auto,
                  color: colorScheme.primary,
                ),
                title: const Text('深色模式'),
                subtitle: Text(
                  themeMode == ThemeMode.dark
                      ? '深色模式'
                      : themeMode == ThemeMode.light
                      ? '亮色模式'
                      : '跟随系统',
                ),
                trailing: SegmentedButton<ThemeMode>(
                  segments: const [
                    ButtonSegment(
                      value: ThemeMode.light,
                      label: Text('亮色'),
                      icon: Icon(Icons.light_mode, size: 16),
                    ),
                    ButtonSegment(
                      value: ThemeMode.system,
                      label: Text('系统'),
                      icon: Icon(Icons.brightness_auto, size: 16),
                    ),
                    ButtonSegment(
                      value: ThemeMode.dark,
                      label: Text('深色'),
                      icon: Icon(Icons.dark_mode, size: 16),
                    ),
                  ],
                  selected: {themeMode},
                  onSelectionChanged: (selected) {
                    ThemeModeService.instance.setMode(selected.first);
                  },
                  style: ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              );
            },
          ),
          ValueListenableBuilder<Color>(
            valueListenable: ThemeModeService.instance.seedColor,
            builder: (context, seedColor, _) {
              return ListTile(
                leading: const Icon(Icons.palette_outlined),
                title: const Text('主题色'),
                subtitle: Text(
                  '当前主题色',
                  style: TextStyle(color: colorScheme.primary),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: seedColor,
                        shape: BoxShape.circle,
                        border: Border.all(color: colorScheme.outlineVariant),
                      ),
                    ),
                    const Icon(Icons.chevron_right),
                  ],
                ),
                onTap: _showThemeColorPicker,
              );
            },
          ),
          const Divider(),

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
          SwitchListTile(
            secondary: Icon(Icons.question_answer, color: colorScheme.primary),
            title: const Text('复习前询问词书'),
            subtitle: const Text('多本词书有待复习时，选择先复习哪个词书'),
            value: _reviewAskBook,
            onChanged: _setReviewAskBook,
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

          // ---- 语音设置 ----
          _SectionHeader(title: '语音设置 (TTS)'),
          _TtsSettingsTile(),
          const SizedBox(height: 8),

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

          // ---- AI 句子练习设置 ----
          _SectionHeader(title: 'AI 句子练习设置'),
          _AiSentenceSettingsTile(),
          const SizedBox(height: 8),

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

/// AI 句子练习设置区块
class _AiSentenceSettingsTile extends StatefulWidget {
  @override
  State<_AiSentenceSettingsTile> createState() =>
      _AiSentenceSettingsTileState();
}

class _AiSentenceSettingsTileState extends State<_AiSentenceSettingsTile> {
  final AiSentenceService _sentenceService = AiSentenceService();
  int _sentenceLimit = 10;
  int _extraWordCount = 3;
  PracticeMode _practiceMode = PracticeMode.beginner;
  bool _isLoading = true;

  // 错题本设置
  int _wrongScoreThreshold = 8;
  bool _skipRepeated = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final limit = await _sentenceService.getSentenceLimit();
    final extra = await _sentenceService.getExtraWordCount();
    final mode = await _sentenceService.getPracticeMode();
    final threshold = await _sentenceService.getWrongScoreThreshold();
    final skip = await _sentenceService.getSkipRepeated();
    if (mounted) {
      setState(() {
        _sentenceLimit = limit;
        _extraWordCount = extra;
        _practiceMode = mode;
        _wrongScoreThreshold = threshold;
        _skipRepeated = skip;
        _isLoading = false;
      });
    }
  }

  void _showSentenceLimitPicker() {
    int temp = _sentenceLimit;
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('单次练习句数'),
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
                              ? () => setDialogState(() => temp -= 5)
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
                          onPressed: temp < 50
                              ? () => setDialogState(() => temp += 5)
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
                    _sentenceService.setSentenceLimit(temp);
                    setState(() => _sentenceLimit = temp);
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

  void _showExtraWordCountPicker() {
    int temp = _extraWordCount;
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('入门版多余词数量'),
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
                          onPressed: temp < 5
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
                    _sentenceService.setExtraWordCount(temp);
                    setState(() => _extraWordCount = temp);
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

  void _showWrongScoreThresholdPicker() {
    int temp = _wrongScoreThreshold;
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('错题本阈值'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('得分 ≤ 该值的句子自动加入错题本'),
                  const SizedBox(height: 16),
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
                          onPressed: temp < 10
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
                    _sentenceService.setWrongScoreThreshold(temp);
                    setState(() => _wrongScoreThreshold = temp);
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

    if (_isLoading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    return Column(
      children: [
        // 练习模式
        ListTile(
          leading: Icon(Icons.tune, color: colorScheme.primary),
          title: const Text('练习模式'),
          subtitle: Text(
            _practiceMode == PracticeMode.beginner
                ? '入门版（选择词块组句）'
                : '高阶版（自由输入句子）',
          ),
          trailing: SegmentedButton<PracticeMode>(
            segments: const [
              ButtonSegment(value: PracticeMode.beginner, label: Text('入门')),
              ButtonSegment(value: PracticeMode.advanced, label: Text('高阶')),
            ],
            selected: {_practiceMode},
            onSelectionChanged: (selected) {
              final mode = selected.first;
              _sentenceService.setPracticeMode(mode);
              setState(() => _practiceMode = mode);
            },
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ),
        ListTile(
          leading: Icon(Icons.repeat, color: colorScheme.primary),
          title: const Text('单次练习句数'),
          subtitle: Text('每次练习 $_sentenceLimit 句'),
          trailing: Text(
            '$_sentenceLimit',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: colorScheme.primary,
            ),
          ),
          onTap: _showSentenceLimitPicker,
        ),
        if (_practiceMode == PracticeMode.beginner)
          ListTile(
            leading: Icon(Icons.layers, color: colorScheme.primary),
            title: const Text('入门版多余词数量'),
            subtitle: Text('$_extraWordCount 个干扰词'),
            trailing: Text(
              '$_extraWordCount',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: colorScheme.primary,
              ),
            ),
            onTap: _showExtraWordCountPicker,
          ),
        const Divider(),
        // 错题本设置
        ListTile(
          leading: Icon(Icons.error_outline, color: colorScheme.primary),
          title: const Text('错题本阈值'),
          subtitle: Text('得分 ≤ $_wrongScoreThreshold 分时加入错题本'),
          trailing: Text(
            '$_wrongScoreThreshold',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: colorScheme.primary,
            ),
          ),
          onTap: _showWrongScoreThresholdPicker,
        ),
        SwitchListTile(
          secondary: Icon(
            Icons.replay_circle_filled,
            color: colorScheme.primary,
          ),
          title: const Text('不重复练习'),
          subtitle: const Text('已练习正确的句子不再出现'),
          value: _skipRepeated,
          onChanged: (value) {
            _sentenceService.setSkipRepeated(value);
            setState(() => _skipRepeated = value);
          },
        ),
      ],
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

/// TTS 语音设置区块
class _TtsSettingsTile extends StatefulWidget {
  @override
  State<_TtsSettingsTile> createState() => _TtsSettingsTileState();
}

class _TtsSettingsTileState extends State<_TtsSettingsTile> {
  TtsSettings _settings = const TtsSettings();
  bool _isLoading = true;
  List<String> _voices = [];

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    _settings = await TtsSettings.load();
    if (!mounted) return;
    setState(() => _isLoading = false);
    // 异步加载音色列表
    _loadVoices();
  }

  Future<void> _loadVoices() async {
    try {
      final voices = await TtsService.instance.getVoices();
      if (mounted) setState(() => _voices = voices);
    } catch (_) {
      // 静默处理
    }
  }

  Future<void> _updateSettings(TtsSettings newSettings) async {
    await TtsService.instance.updateSettings(newSettings);
    if (mounted) {
      setState(() => _settings = newSettings);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    if (_isLoading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    return Column(
      children: [
        // TTS 启用开关
        SwitchListTile(
          secondary: Icon(Icons.volume_up, color: colorScheme.primary),
          title: const Text('启用 TTS'),
          subtitle: const Text('朗读单词发音'),
          value: _settings.enabled,
          onChanged: (value) {
            _updateSettings(_settings.copyWith(enabled: value));
          },
        ),

        if (_settings.enabled) ...[
          // 服务商切换
          ListTile(
            leading: Icon(Icons.cloud, color: colorScheme.primary),
            title: const Text('TTS 服务商'),
            trailing: SegmentedButton<TtsProvider>(
              segments: const [
                ButtonSegment(
                  value: TtsProvider.system,
                  label: Text('系统'),
                  icon: Icon(Icons.phone_android, size: 18),
                ),
                ButtonSegment(
                  value: TtsProvider.edge,
                  label: Text('Edge'),
                  icon: Icon(Icons.language, size: 18),
                ),
              ],
              selected: {_settings.provider},
              onSelectionChanged: (selected) {
                _updateSettings(_settings.copyWith(provider: selected.first));
              },
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ),

          // 音量
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Icon(Icons.volume_mute, size: 20, color: colorScheme.primary),
                Expanded(
                  child: Slider(
                    value: _settings.volume,
                    min: 0.0,
                    max: 1.0,
                    divisions: 20,
                    label: '${(_settings.volume * 100).round()}%',
                    onChanged: (value) {
                      setState(
                        () => _settings = _settings.copyWith(volume: value),
                      );
                    },
                    onChangeEnd: (value) {
                      _updateSettings(_settings.copyWith(volume: value));
                    },
                  ),
                ),
                Icon(Icons.volume_up, size: 20, color: colorScheme.primary),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 72, top: 0, bottom: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '音量: ${(_settings.volume * 100).round()}%',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),

          // 语速
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Icon(Icons.speed, size: 20, color: colorScheme.primary),
                Expanded(
                  child: Slider(
                    value: _settings.rate,
                    min: 0.5,
                    max: 2.0,
                    divisions: 15,
                    label: '${_settings.rate.toStringAsFixed(1)}x',
                    onChanged: (value) {
                      setState(
                        () => _settings = _settings.copyWith(rate: value),
                      );
                    },
                    onChangeEnd: (value) {
                      _updateSettings(_settings.copyWith(rate: value));
                    },
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 72, top: 0, bottom: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '语速: ${_settings.rate.toStringAsFixed(1)}x',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),

          // 音调
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Icon(Icons.tune, size: 20, color: colorScheme.primary),
                Expanded(
                  child: Slider(
                    value: _settings.pitch,
                    min: 0.5,
                    max: 2.0,
                    divisions: 15,
                    label: '${_settings.pitch.toStringAsFixed(1)}x',
                    onChanged: (value) {
                      setState(
                        () => _settings = _settings.copyWith(pitch: value),
                      );
                    },
                    onChangeEnd: (value) {
                      _updateSettings(_settings.copyWith(pitch: value));
                    },
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 72, top: 0, bottom: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '音调: ${_settings.pitch.toStringAsFixed(1)}x',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),

          // 音色选择（Edge TTS 显示）
          if (_settings.provider == TtsProvider.edge) ...[
            ListTile(
              leading: Icon(
                Icons.record_voice_over,
                color: colorScheme.primary,
              ),
              title: const Text('音色'),
              subtitle: Text(_settings.voiceName ?? '默认音色'),
              trailing: _voices.isNotEmpty
                  ? PopupMenuButton<String>(
                      onSelected: (voice) {
                        _updateSettings(_settings.copyWith(voiceName: voice));
                      },
                      itemBuilder: (context) => _voices.map((voice) {
                        return PopupMenuItem(value: voice, child: Text(voice));
                      }).toList(),
                      icon: const Icon(Icons.arrow_drop_down),
                    )
                  : const Icon(Icons.arrow_drop_down),
              onTap: () {
                if (_voices.isNotEmpty) {
                  showModalBottomSheet(
                    context: context,
                    builder: (context) {
                      return SafeArea(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Padding(
                              padding: EdgeInsets.all(16),
                              child: Text(
                                '选择音色',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            const Divider(height: 1),
                            SizedBox(
                              height: 300,
                              child: ListView.separated(
                                itemCount: _voices.length,
                                separatorBuilder: (_, _) =>
                                    const Divider(height: 1),
                                itemBuilder: (context, index) {
                                  final voice = _voices[index];
                                  final isSelected =
                                      voice == _settings.voiceName;
                                  return ListTile(
                                    selected: isSelected,
                                    selectedTileColor: colorScheme
                                        .primaryContainer
                                        .withValues(alpha: 0.3),
                                    title: Text(voice),
                                    trailing: isSelected
                                        ? Icon(
                                            Icons.check,
                                            color: colorScheme.primary,
                                          )
                                        : null,
                                    onTap: () {
                                      Navigator.of(context).pop();
                                      _updateSettings(
                                        _settings.copyWith(voiceName: voice),
                                      );
                                    },
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  );
                }
              },
            ),
          ],

          const Divider(),

          // 自动朗读设置
          SwitchListTile(
            secondary: Icon(Icons.visibility, color: colorScheme.primary),
            title: const Text('浏览阶段自动朗读'),
            subtitle: const Text('在学习/复习的浏览阶段自动朗读单词'),
            value: _settings.autoReadBrowse,
            onChanged: (value) {
              _updateSettings(_settings.copyWith(autoReadBrowse: value));
            },
          ),
          SwitchListTile(
            secondary: Icon(Icons.psychology, color: colorScheme.primary),
            title: const Text('回忆阶段自动朗读'),
            subtitle: const Text('在回忆阶段自动朗读单词'),
            value: _settings.autoReadRecall,
            onChanged: (value) {
              _updateSettings(_settings.copyWith(autoReadRecall: value));
            },
          ),
        ],
      ],
    );
  }
}
