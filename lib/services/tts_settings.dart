import 'package:shared_preferences/shared_preferences.dart';

/// TTS 服务商
enum TtsProvider { system, edge }

/// TTS 设置（持久化到 SharedPreferences）
class TtsSettings {
  static const _keyEnabled = 'tts_enabled';
  static const _keyProvider = 'tts_provider';
  static const _keyVolume = 'tts_volume';
  static const _keyRate = 'tts_rate';
  static const _keyPitch = 'tts_pitch';
  static const _keyVoice = 'tts_voice';
  static const _keyAutoReadBrowse = 'tts_auto_read_browse';
  static const _keyAutoReadRecall = 'tts_auto_read_recall';

  final bool enabled;
  final TtsProvider provider;
  final double volume;
  final double rate;
  final double pitch;
  final String? voiceName;
  final bool autoReadBrowse;
  final bool autoReadRecall;

  const TtsSettings({
    this.enabled = true,
    this.provider = TtsProvider.system,
    this.volume = 1.0,
    this.rate = 1.0,
    this.pitch = 1.0,
    this.voiceName,
    this.autoReadBrowse = false,
    this.autoReadRecall = false,
  });

  TtsSettings copyWith({
    bool? enabled,
    TtsProvider? provider,
    double? volume,
    double? rate,
    double? pitch,
    String? voiceName,
    bool? autoReadBrowse,
    bool? autoReadRecall,
  }) {
    return TtsSettings(
      enabled: enabled ?? this.enabled,
      provider: provider ?? this.provider,
      volume: volume ?? this.volume,
      rate: rate ?? this.rate,
      pitch: pitch ?? this.pitch,
      voiceName: voiceName ?? this.voiceName,
      autoReadBrowse: autoReadBrowse ?? this.autoReadBrowse,
      autoReadRecall: autoReadRecall ?? this.autoReadRecall,
    );
  }

  static Future<TtsSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return TtsSettings(
      enabled: prefs.getBool(_keyEnabled) ?? true,
      provider: TtsProvider.values[prefs.getInt(_keyProvider) ?? 0],
      volume: prefs.getDouble(_keyVolume) ?? 1.0,
      rate: prefs.getDouble(_keyRate) ?? 1.0,
      pitch: prefs.getDouble(_keyPitch) ?? 1.0,
      voiceName: prefs.getString(_keyVoice),
      autoReadBrowse: prefs.getBool(_keyAutoReadBrowse) ?? false,
      autoReadRecall: prefs.getBool(_keyAutoReadRecall) ?? false,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyEnabled, enabled);
    await prefs.setInt(_keyProvider, provider.index);
    await prefs.setDouble(_keyVolume, volume);
    await prefs.setDouble(_keyRate, rate);
    await prefs.setDouble(_keyPitch, pitch);
    if (voiceName != null) {
      await prefs.setString(_keyVoice, voiceName!);
    } else {
      await prefs.remove(_keyVoice);
    }
    await prefs.setBool(_keyAutoReadBrowse, autoReadBrowse);
    await prefs.setBool(_keyAutoReadRecall, autoReadRecall);
  }
}
