import 'package:flutter_edge_tts/flutter_edge_tts.dart';
import 'package:audioplayers/audioplayers.dart';
import 'tts_engine.dart';
import 'log_service.dart';

/// 基于 flutter_edge_tts 的在线 TTS 引擎
class EdgeTtsEngine implements TtsEngine {
  FlutterEdgeTts? _tts;
  AudioPlayer? _player;
  String _currentVoice = 'en-US-AriaNeural';
  final EdgeTtsOutputFormat _outputFormat =
      EdgeTtsOutputFormat.audio24Khz96KbitrateMonoMp3;

  // 当前设置（prosody 参数）
  double _volume = 1.0;
  double _rate = 1.0;
  double _pitch = 1.0;

  @override
  Future<bool> speak(String text) async {
    await _ensureInitialized();
    await _ensureAudioPlayer();

    // 停止当前播放
    await _player?.stop();

    // 转换参数为 Edge TTS 格式
    final rate = _rate.toStringAsFixed(2);
    // pitch: 0.5~2.0 → -50Hz~+50Hz 映射
    final pitchStr = _pitchToString(_pitch);
    // volume: 0.0~1.0 → 0~100 映射
    final volumeStr = (_volume * 100).round().toString();

    try {
      final result = await _tts!.synthesize(
        text,
        prosody: EdgeTtsProsody(rate: rate, pitch: pitchStr, volume: volumeStr),
      );

      // 使用 audioplayers 播放音频字节
      await _player!.play(BytesSource(result.audioBytes));
      return true;
    } catch (e) {
      // 合成失败（如无网络）：返回失败状态，由调用方决定降级或提示
      logError('EdgeTtsEngine', 'speak 失败: $e');
      return false;
    }
  }

  @override
  Future<void> stop() async {
    await _player?.stop();
  }

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    await _player?.setVolume(_volume);
  }

  @override
  Future<void> setRate(double rate) async {
    _rate = rate.clamp(0.5, 2.0);
  }

  @override
  Future<void> setPitch(double pitch) async {
    _pitch = pitch.clamp(0.5, 2.0);
  }

  @override
  Future<List<String>> getVoices() async {
    await _ensureInitialized();
    try {
      final voices = await _tts!.getVoices();
      return voices.map((v) => v.shortName).toList();
    } catch (e) {
      return [_currentVoice];
    }
  }

  @override
  Future<void> setVoice(String name) async {
    _currentVoice = name;
    // 更新 FlutterEdgeTts 的配置
    _tts?.updateConfig(_tts!.config.copyWith(voice: name));
  }

  @override
  Future<void> dispose() async {
    await _player?.dispose();
    _player = null;
    await _tts?.close();
    _tts = null;
  }

  Future<void> _ensureInitialized() async {
    if (_tts != null) return;
    _tts = FlutterEdgeTts(voice: _currentVoice, outputFormat: _outputFormat);
  }

  Future<void> _ensureAudioPlayer() async {
    if (_player != null) return;
    _player = AudioPlayer();
    await _player!.setVolume(_volume);
  }

  /// 将 pitch (0.5~2.0) 转换为 Edge TTS 格式
  /// 1.0 是默认值，对应 +0Hz
  /// 范围：-50Hz ~ +50Hz
  String _pitchToString(double pitch) {
    if (pitch == 1.0) return '+0Hz';
    // 线性映射：0.5 → -50Hz, 1.0 → +0Hz, 2.0 → +50Hz
    final hz = ((pitch - 1.0) * 100).round();
    if (hz >= 0) return '+${hz}Hz';
    return '${hz}Hz';
  }
}
