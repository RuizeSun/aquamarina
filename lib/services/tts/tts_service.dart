import 'tts_settings.dart';
import 'tts_engine.dart';
import 'system_tts_engine.dart';
import 'edge_tts_engine.dart';
import 'mimo_tts_engine.dart';
import '../system/log_service.dart';

/// 统一的 TTS 服务（单例）
class TtsService {
  static final TtsService instance = TtsService._();
  TtsService._();

  TtsEngine? _engine;
  TtsSettings _settings = const TtsSettings();
  bool _initialized = false;

  /// 设置版本号：用于丢弃初始化期间读到的过期快照
  int _settingsVersion = 0;

  /// 正在进行中的初始化（并发调用复用同一次初始化）
  Future<void>? _initFuture;

  /// 当前设置
  TtsSettings get settings => _settings;

  /// 是否已启用
  bool get enabled => _settings.enabled;

  /// 初始化（加载设置并创建引擎）
  ///
  /// 若初始化加载设置期间设置已被更新（例如设置页刚切换服务商），
  /// 会丢弃本次读到的旧快照，避免旧服务商的引擎/音色覆盖新设置。
  Future<void> init() => _initFuture ??= _doInit();

  Future<void> _doInit() async {
    try {
      final version = _settingsVersion;
      final settings = await TtsSettings.load();
      if (version != _settingsVersion) return;

      _settings = settings;
      await _createEngine();
      _initialized = true;
      logInfo('TtsService', '初始化完成，引擎: ${_settings.provider.name}');
    } finally {
      _initFuture = null;
    }
  }

  /// 刷新设置（从 SharedPreferences 重新加载）
  Future<void> refreshSettings() async {
    _settingsVersion++;
    _initialized = true;
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
    // 设置已就绪：让进行中的初始化丢弃它读到的旧快照
    _settingsVersion++;
    _initialized = true;
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

  /// 获取音色列表。
  ///
  /// [provider] 指定要查询的服务商，默认使用当前服务商。
  /// 列表始终按指定服务商获取，避免切换服务商时把上一家的音色
  /// （例如 MiMo 预置音色）显示在 Edge 下。
  Future<List<String>> getVoices({TtsProvider? provider}) async {
    final target = provider ?? _settings.provider;
    switch (target) {
      case TtsProvider.system:
        return const [];
      case TtsProvider.mimo:
        // MiMo 音色是固定预置列表，无需构造引擎
        return [for (final voice in MimoTtsEngine.presetVoices) voice.id];
      case TtsProvider.edge:
        if (_settings.provider == TtsProvider.edge) {
          await _ensureEngine();
          // 初始化可能按持久化设置改写了服务商，只有确实为 Edge 时才复用引擎
          if (_settings.provider == TtsProvider.edge) {
            return _engine?.getVoices() ?? const [];
          }
        }
        // 当前引擎属于其他服务商：临时创建 Edge 引擎查询，避免串用音色列表
        final engine = EdgeTtsEngine();
        try {
          return await engine.getVoices();
        } finally {
          await engine.dispose();
        }
    }
  }

  /// 释放资源
  Future<void> dispose() async {
    await _disposeEngine();
    _initialized = false;
  }

  // ─── 内部方法 ─────────────────────────────────

  Future<void> _ensureEngine() async {
    if (!_initialized) await init();
    // 引擎与服务商不一致时（例如上一轮初始化残留）按当前设置重建
    if (_engine == null || !_engineMatchesProvider) await _createEngine();
  }

  /// 当前引擎类型是否与设置的服务商一致
  bool get _engineMatchesProvider {
    final engine = _engine;
    return switch (_settings.provider) {
      TtsProvider.system => engine is SystemTtsEngine,
      TtsProvider.edge => engine is EdgeTtsEngine,
      TtsProvider.mimo => engine is MimoTtsEngine,
    };
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
