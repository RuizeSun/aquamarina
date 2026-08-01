import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 主题模式服务：管理亮色/跟随系统/深色模式的切换与持久化
/// 同时管理主题色（种子色）的设置与持久化
class ThemeModeService {
  ThemeModeService._();

  /// 全局单例
  static final ThemeModeService instance = ThemeModeService._();

  static const String _keyThemeMode = 'theme_mode';
  static const String _keySeedColor = 'theme_seed_color';

  /// 默认主题色（青绿，与原有外观一致）
  static const Color defaultSeedColor = Color(0xFF00BFA5);

  final ValueNotifier<ThemeMode> mode = ValueNotifier<ThemeMode>(
    ThemeMode.system,
  );

  final ValueNotifier<Color> seedColor = ValueNotifier<Color>(defaultSeedColor);

  /// 从 SharedPreferences 加载主题模式（默认跟随系统）与主题色
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();

    final index = prefs.getInt(_keyThemeMode);
    if (index != null && index >= 0 && index < ThemeMode.values.length) {
      mode.value = ThemeMode.values[index];
    }

    final seed = prefs.getInt(_keySeedColor);
    if (seed != null) {
      seedColor.value = Color(seed);
    }
  }

  /// 设置主题模式并持久化
  Future<void> setMode(ThemeMode newMode) async {
    if (mode.value == newMode) return;
    mode.value = newMode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyThemeMode, newMode.index);
  }

  /// 设置主题色并持久化
  Future<void> setSeedColor(Color newColor) async {
    if (seedColor.value == newColor) return;
    seedColor.value = newColor;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keySeedColor, newColor.toARGB32());
  }
}
