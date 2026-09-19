import 'tts_settings.dart';
import 'tts_engine.dart';
import 'system_tts_engine.dart';
import 'edge_tts_engine.dart';
import 'mimo_tts_engine.dart';
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
  /// 在线引擎（Edge TTS / 小米 MiMo TTS）失败时会自动降级到系统 TTS。
  ///
  /// [allowFallback] 为 `false` 时不降级到系统 TTS，直接返回当前引擎的结果，
  /// 供「语音设置」中的试听自检使用（避免降级掩盖真实故障）。
  Future<bool> speak(String text, {bool allowFallback = true}) async {
    if (!_settings.enabled || text.isEmpty) return true;
    await _ensureEngine();
    if (_engine == null) return false;

    // 停止之前的朗读
    await _engine!.stop();

    final success = await _engine!.speak(text);
    if (success) return true;

    // 在线引擎失败（如无网络、API Key 无效）时降级到系统 TTS
    if (allowFallback && _settings.provider != TtsProvider.system) {
      try {
        // 临时创建系统引擎并朗读（不影响用户设置的 provider）
        logWarning(
          'TtsService',
          '${_settings.provider.label} TTS 失败，降级到系统 TTS',
        );
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
      case TtsProvider.mimo:
        _engine = MimoTtsEngine(
          baseUrl: _settings.mimoBaseUrl,
          model: _settings.mimoModel,
          voice: _settings.effectiveVoiceName ?? MimoTtsEngine.defaultVoice,
          instruction: _settings.mimoInstruction,
          styleTag: _settings.mimoStyleTag,
        );
    }

    await _applySettingsToEngine();
  }

  Future<void> _applySettingsToEngine() async {
    if (_engine == null) return;

    // MiMo 专属配置（Base URL / 模型 / 风格指令 / 音频标签前缀）
    final engine = _engine;
    if (engine is MimoTtsEngine) {
      engine.updateConfig(
        baseUrl: _settings.mimoBaseUrl,
        model: _settings.mimoModel,
        instruction: _settings.mimoInstruction,
        styleTag: _settings.mimoStyleTag,
      );
    }

    await _engine!.setVolume(_settings.volume);
    await _engine!.setRate(_settings.rate);
    await _engine!.setPitch(_settings.pitch);
    final voice = _settings.effectiveVoiceName;
    if (voice != null && voice.isNotEmpty) {
      await _engine!.setVoice(voice);
    }
  }

  Future<void> _disposeEngine() async {
    if (_engine != null) {
      await _engine!.dispose();
      _engine = null;
    }
  }
}
