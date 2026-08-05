import 'package:flutter/material.dart';
import 'sections/about_section.dart';
import 'sections/appearance_section.dart';
import 'sections/ai_profile_section.dart';
import 'sections/ai_sentence_section.dart';
import 'sections/data_management_section.dart';
import 'sections/tts_section.dart';
import 'sections/vocabulary_section.dart';
import 'settings_section_header.dart';

/// 设置分类元数据
class SettingsCategory {
  final String title;
  final IconData icon;
  final Widget Function() builder;

  const SettingsCategory({
    required this.title,
    required this.icon,
    required this.builder,
  });
}

/// 自适应主从布局设置页
///
/// - 大屏设备（宽度 ≥ 600dp）：双窗格布局，左侧分类列表 + 右侧设置内容。
/// - 小屏设备（宽度 < 600dp）：单窗格布局，分类列表 + 点击跳转。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static const double _twoPaneBreakpoint = 600;

  /// 大屏布局下当前选中的分类
  int _selectedIndex = 0;

  List<SettingsCategory> get _categories => [
    SettingsCategory(
      title: '外观设置',
      icon: Icons.palette_outlined,
      builder: () {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SettingsSectionHeader(title: '外观设置'),
            const AppearanceSection(),
          ],
        );
      },
    ),
    SettingsCategory(
      title: '背单词设置',
      icon: Icons.auto_stories_outlined,
      builder: () {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SettingsSectionHeader(title: '背单词设置'),
            const VocabularySection(),
          ],
        );
      },
    ),
    SettingsCategory(
      title: '语音设置',
      icon: Icons.volume_up_outlined,
      builder: () {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SettingsSectionHeader(title: '语音设置 (TTS)'),
            const TtsSettingsSection(),
            const SizedBox(height: 8),
          ],
        );
      },
    ),
    SettingsCategory(
      title: 'AI 服务配置',
      icon: Icons.smart_toy_outlined,
      builder: () {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SettingsSectionHeader(title: 'AI 服务配置'),
            const AiProfileSection(),
          ],
        );
      },
    ),
    SettingsCategory(
      title: 'AI 句子练习',
      icon: Icons.forum_outlined,
      builder: () {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SettingsSectionHeader(title: 'AI 句子练习设置'),
            const AiSentenceSettingsSection(),
            const SizedBox(height: 8),
          ],
        );
      },
    ),
    SettingsCategory(
      title: '数据管理',
      icon: Icons.storage_outlined,
      builder: () => const DataManagementSection(),
    ),
    SettingsCategory(
      title: '关于',
      icon: Icons.info_outline,
      builder: () {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SettingsSectionHeader(title: '关于'),
            const AboutSection(),
          ],
        );
      },
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= _twoPaneBreakpoint;
        return Scaffold(
          appBar: AppBar(title: const Text('设置'), centerTitle: false),
          body: isWide ? _buildTwoPane(context) : _buildSinglePane(context),
        );
      },
    );
  }

  /// 宽屏：双窗格主从布局
  Widget _buildTwoPane(BuildContext context) {
    final categories = _categories;
    final selected = categories[_selectedIndex];

    return Row(
      children: [
        // 左侧：分类列表（Master）
        SizedBox(
          width: 280,
          child: Material(
            color: Theme.of(
              context,
            ).colorScheme.surfaceContainerLow.withValues(alpha: 0.5),
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: categories.length,
              itemBuilder: (context, index) {
                final category = categories[index];
                final isSelected = index == _selectedIndex;
                return ListTile(
                  selected: isSelected,
                  selectedTileColor: Theme.of(
                    context,
                  ).colorScheme.primaryContainer.withValues(alpha: 0.4),
                  leading: Icon(category.icon),
                  title: Text(category.title),
                  onTap: () {
                    setState(() => _selectedIndex = index);
                  },
                );
              },
            ),
          ),
        ),
        // 垂直分隔线
        VerticalDivider(
          width: 1,
          thickness: 1,
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
        // 右侧：选中分类的设置内容
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [selected.builder()],
          ),
        ),
      ],
    );
  }

  /// 窄屏：单窗格分类列表
  Widget _buildSinglePane(BuildContext context) {
    final categories = _categories;

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        for (final category in categories)
          ListTile(
            leading: Icon(category.icon),
            title: Text(category.title),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) =>
                      SettingsCategoryPage(category: category),
                ),
              );
            },
          ),
      ],
    );
  }
}

/// 小屏布局下单个分类的设置子页面
class SettingsCategoryPage extends StatelessWidget {
  final SettingsCategory category;

  const SettingsCategoryPage({super.key, required this.category});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(category.title), centerTitle: false),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [category.builder()],
      ),
    );
  }
}
