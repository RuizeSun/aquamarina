import 'package:shared_preferences/shared_preferences.dart';

/// TTS 服务商
///
/// 注意：枚举值以 `index` 形式持久化到 SharedPreferences，
/// 新增服务商必须**追加在末尾**，避免破坏既有用户设置。
enum TtsProvider {
  system('系统'),
  edge('Edge'),
  mimo('MiMo');

  /// UI 展示名
  final String label;

  const TtsProvider(this.label);
}

/// TTS 设置（持久化到 SharedPreferences）
class TtsSettings {
  static const _keyEnabled = 'tts_enabled';
  static const _keyProvider = 'tts_provider';
  static const _keyVolume = 'tts_volume';
  static const _keyRate = 'tts_rate';
  static const _keyPitch = 'tts_pitch';

  /// 系统 / Edge 音色（历史 key，保持向后兼容）
  static const _keyVoice = 'tts_voice';

  /// MiMo 音色（voice ID）单独存储，避免与 Edge 音色互相污染
  static const _keyVoiceMimo = 'tts_voice_mimo';
  static const _keyAutoReadBrowse = 'tts_auto_read_browse';
  static const _keyAutoReadRecall = 'tts_auto_read_recall';
  static const _keyMimoBaseUrl = 'tts_mimo_base_url';
  static const _keyMimoModel = 'tts_mimo_model';
  static const _keyMimoInstruction = 'tts_mimo_instruction';
  static const _keyMimoStyleTag = 'tts_mimo_style_tag';

  /// MiMo TTS 默认接口地址（可在设置中改为兼容的中转地址）
  static const String defaultMimoBaseUrl = 'https://api.xiaomimimo.com/v1';

  /// MiMo TTS 默认模型（目前仅适配该模型）
  static const String defaultMimoModel = 'mimo-v2.5-tts';

  /// MiMo TTS 默认音色（中国集群为「冰糖」，其他集群为 Mia）
  static const String defaultMimoVoice = 'mimo_default';

  final bool enabled;
  final TtsProvider provider;
  final double volume;
  final double rate;
  final double pitch;
  final String? voiceName;
  final bool autoReadBrowse;
  final bool autoReadRecall;

  /// MiMo TTS 接口地址
  final String mimoBaseUrl;

  /// MiMo TTS 模型 ID
  final String mimoModel;

  /// MiMo TTS 风格指令（作为 `user` 消息，用自然语言控制语速 / 情绪 / 方言等）
  final String mimoInstruction;

  /// MiMo TTS 音频标签前缀（拼接在待合成文本最前，如 `(东北话)`；留空则不添加）
  final String mimoStyleTag;

  const TtsSettings({
    this.enabled = true,
    this.provider = TtsProvider.edge,
    this.volume = 1.0,
    this.rate = 1.0,
    this.pitch = 1.0,
    this.voiceName,
    this.autoReadBrowse = true,
    this.autoReadRecall = true,
    this.mimoBaseUrl = defaultMimoBaseUrl,
    this.mimoModel = defaultMimoModel,
    this.mimoInstruction = '',
    this.mimoStyleTag = '',
  });

  /// 当前服务商实际使用的音色（未设置时返回该服务商的默认音色）
  String? get effectiveVoiceName {
    if (voiceName != null && voiceName!.isNotEmpty) return voiceName;
    return provider == TtsProvider.mimo ? defaultMimoVoice : null;
  }

  TtsSettings copyWith({
    bool? enabled,
    TtsProvider? provider,
    double? volume,
    double? rate,
    double? pitch,
    String? voiceName,
    bool? autoReadBrowse,
    bool? autoReadRecall,
    String? mimoBaseUrl,
    String? mimoModel,
    String? mimoInstruction,
    String? mimoStyleTag,
    bool clearVoiceName = false,
  }) {
    return TtsSettings(
      enabled: enabled ?? this.enabled,
      provider: provider ?? this.provider,
      volume: volume ?? this.volume,
      rate: rate ?? this.rate,
      pitch: pitch ?? this.pitch,
      voiceName: clearVoiceName ? null : (voiceName ?? this.voiceName),
      autoReadBrowse: autoReadBrowse ?? this.autoReadBrowse,
      autoReadRecall: autoReadRecall ?? this.autoReadRecall,
      mimoBaseUrl: mimoBaseUrl ?? this.mimoBaseUrl,
      mimoModel: mimoModel ?? this.mimoModel,
      mimoInstruction: mimoInstruction ?? this.mimoInstruction,
      mimoStyleTag: mimoStyleTag ?? this.mimoStyleTag,
    );
  }

  /// 从持久化的 index 安全解析服务商（脏数据 / 越界时回退到 Edge）
  static TtsProvider providerFromIndex(int? index) {
    if (index == null || index < 0 || index >= TtsProvider.values.length) {
      return TtsProvider.edge;
    }
    return TtsProvider.values[index];
  }

  /// 从持久化中读取指定服务商已保存的音色（无则返回 `null`）。
  ///
  /// 切换服务商时使用：避免把旧服务商的音色（如 Edge 的 `en-US-AriaNeural`）
  /// 写入新服务商的音色配置。
  static Future<String?> loadVoiceFor(TtsProvider provider) async {
    final prefs = await SharedPreferences.getInstance();
    return provider == TtsProvider.mimo
        ? prefs.getString(_keyVoiceMimo)
        : prefs.getString(_keyVoice);
  }

  static Future<TtsSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final provider = providerFromIndex(prefs.getInt(_keyProvider));
    return TtsSettings(
      enabled: prefs.getBool(_keyEnabled) ?? true,
      provider: provider,
      volume: prefs.getDouble(_keyVolume) ?? 1.0,
      rate: prefs.getDouble(_keyRate) ?? 1.0,
      pitch: prefs.getDouble(_keyPitch) ?? 1.0,
      // 音色按服务商分别读取
      voiceName: provider == TtsProvider.mimo
          ? prefs.getString(_keyVoiceMimo)
          : prefs.getString(_keyVoice),
      autoReadBrowse: prefs.getBool(_keyAutoReadBrowse) ?? true,
      autoReadRecall: prefs.getBool(_keyAutoReadRecall) ?? true,
      mimoBaseUrl: prefs.getString(_keyMimoBaseUrl) ?? defaultMimoBaseUrl,
      mimoModel: prefs.getString(_keyMimoModel) ?? defaultMimoModel,
      mimoInstruction: prefs.getString(_keyMimoInstruction) ?? '',
      mimoStyleTag: prefs.getString(_keyMimoStyleTag) ?? '',
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyEnabled, enabled);
    await prefs.setInt(_keyProvider, provider.index);
    await prefs.setDouble(_keyVolume, volume);
    await prefs.setDouble(_keyRate, rate);
    await prefs.setDouble(_keyPitch, pitch);
    // 音色按服务商分别写入，切换服务商时各留各的
    final voiceKey = provider == TtsProvider.mimo ? _keyVoiceMimo : _keyVoice;
    if (voiceName != null && voiceName!.isNotEmpty) {
      await prefs.setString(voiceKey, voiceName!);
    } else {
      await prefs.remove(voiceKey);
    }
    await prefs.setBool(_keyAutoReadBrowse, autoReadBrowse);
    await prefs.setBool(_keyAutoReadRecall, autoReadRecall);
    await prefs.setString(_keyMimoBaseUrl, mimoBaseUrl);
    await prefs.setString(_keyMimoModel, mimoModel);
    await prefs.setString(_keyMimoInstruction, mimoInstruction);
    await prefs.setString(_keyMimoStyleTag, mimoStyleTag);
  }
}
