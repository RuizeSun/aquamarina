import 'tts_settings.dart';
import 'tts_engine.dart';
import 'system_tts_engine.dart';
import 'edge_tts_engine.dart';
import 'log_service.dart';

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
    logInfo('TtsService', '初始化完成，引擎: ${_settings.provider.name}');
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

  /// 朗读文本。
  /// 返回 `true` 表示朗读成功；`false` 表示所有可用引擎都失败（如无网络且无系统语音）。
  /// Edge TTS 失败时会自动降级到系统 TTS。
  Future<bool> speak(String text) async {
    if (!_settings.enabled || text.isEmpty) return true;
    await _ensureEngine();
    if (_engine == null) return false;

    // 停止之前的朗读
    await _engine!.stop();

    final success = await _engine!.speak(text);
    if (success) return true;

    // Edge TTS 失败（如无网络）时降级到系统 TTS
    if (_settings.provider == TtsProvider.edge) {
      try {
        // 临时创建系统引擎并朗读（不影响用户设置的 provider）
        logWarning('TtsService', 'Edge TTS 失败，降级到系统 TTS');
        final fallback = SystemTtsEngine();
        return await fallback.speak(text);
      } catch (e) {
        logError('TtsService', '系统 TTS 降级也失败: $e');
        return false;
      }
    }
    return false;
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
