import 'package:flutter/material.dart';
import '../../../services/theme_mode_service.dart';

/// 外观设置分区（深色模式、主题色）
class AppearanceSection extends StatelessWidget {
  const AppearanceSection({super.key});

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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Column(
      children: [
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
              onTap: () => _showThemeColorPicker(context),
            );
          },
        ),
      ],
    );
  }

  // ===== 主题色设置 =====

  void _showThemeColorPicker(BuildContext context) {
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
                            _showCustomColorPicker(context);
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

  void _showCustomColorPicker(BuildContext context) {
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
}
