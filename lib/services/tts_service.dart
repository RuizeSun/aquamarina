import 'tts_settings.dart';
import 'tts_engine.dart';
import 'system_tts_engine.dart';
import 'edge_tts_engine.dart';

/// 统一的 TTS 服务（单例）
class TtsService {
  static final TtsService instance = TtsService._();
  TtsService._();

  TtsEngine? _engine;
  TtsSettings _settings = const TtsSettings();
  bool _initialized = false;

  /// 当前设置
  TtsSettings get settings => _settings;

  /// 是否已启用
  bool get enabled => _settings.enabled;

  /// 初始化（加载设置并创建引擎）
  Future<void> init() async {
    _settings = await TtsSettings.load();
    await _createEngine();
    _initialized = true;
  }

  /// 刷新设置（从 SharedPreferences 重新加载）
  Future<void> refreshSettings() async {
    final newSettings = await TtsSettings.load();
    final providerChanged = newSettings.provider != _settings.provider;
    _settings = newSettings;

    if (providerChanged) {
      await _disposeEngine();
      await _createEngine();
    } else if (_engine != null) {
      await _applySettingsToEngine();
    }
  }

  /// 更新并保存设置
  Future<void> updateSettings(TtsSettings newSettings) async {
    final providerChanged = newSettings.provider != _settings.provider;
    _settings = newSettings;
    await _settings.save();

    if (providerChanged) {
      await _disposeEngine();
      await _createEngine();
    } else if (_engine != null) {
      await _applySettingsToEngine();
    }
  }

  /// 朗读文本
  Future<void> speak(String text) async {
    if (!_settings.enabled || text.isEmpty) return;
    await _ensureEngine();
    // 停止之前的朗读
    await _engine?.stop();
    await _engine?.speak(text);
  }

  /// 停止朗读
  Future<void> stop() async {
    await _engine?.stop();
  }

  /// 获取当前引擎支持的音色列表
  Future<List<String>> getVoices() async {
    await _ensureEngine();
    return _engine?.getVoices() ?? [];
  }

  /// 释放资源
  Future<void> dispose() async {
    await _disposeEngine();
    _initialized = false;
  }

  // ─── 内部方法 ─────────────────────────────────

  Future<void> _ensureEngine() async {
    if (!_initialized) await init();
    if (_engine == null) await _createEngine();
  }

  Future<void> _createEngine() async {
    await _disposeEngine();

    switch (_settings.provider) {
      case TtsProvider.system:
        _engine = SystemTtsEngine();
      case TtsProvider.edge:
        _engine = EdgeTtsEngine();
    }

    await _applySettingsToEngine();
  }

  Future<void> _applySettingsToEngine() async {
    if (_engine == null) return;
    await _engine!.setVolume(_settings.volume);
    await _engine!.setRate(_settings.rate);
    await _engine!.setPitch(_settings.pitch);
    if (_settings.voiceName != null && _settings.voiceName!.isNotEmpty) {
      await _engine!.setVoice(_settings.voiceName!);
    }
  }

  Future<void> _disposeEngine() async {
    if (_engine != null) {
      await _engine!.dispose();
      _engine = null;
    }
  }
}
