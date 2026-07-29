import 'package:flutter_tts/flutter_tts.dart';
import 'tts_engine.dart';

/// 基于 flutter_tts 的系统离线 TTS 引擎
class SystemTtsEngine implements TtsEngine {
  final FlutterTts _tts = FlutterTts();
  bool _initialized = false;

  @override
  Future<void> speak(String text) async {
    await _ensureInitialized();
    await _tts.speak(text);
  }

  @override
  Future<void> stop() async {
    await _ensureInitialized();
    await _tts.stop();
  }

  @override
  Future<void> setVolume(double volume) async {
    await _ensureInitialized();
    await _tts.setVolume(volume);
  }

  @override
  Future<void> setRate(double rate) async {
    await _ensureInitialized();
    await _tts.setSpeechRate(rate);
  }

  @override
  Future<void> setPitch(double pitch) async {
    await _ensureInitialized();
    await _tts.setPitch(pitch);
  }

  @override
  Future<List<String>> getVoices() async {
    await _ensureInitialized();
    final voices = await _tts.getVoices;
    if (voices == null) return [];
    // voices 是 List<dynamic>，每个元素是 Map，提取 name 字段
    return voices.map<String>((v) {
      if (v is Map) {
        return (v['name'] as String?) ?? v.toString();
      }
      return v.toString();
    }).toList();
  }

  @override
  Future<void> setVoice(String name) async {
    await _ensureInitialized();
    // flutter_tts 的 setVoice 接受 Map<String, String>
    // name 可能是 "name" 或 "identifier"，尝试两种方式
    await _tts.setVoice({'name': name});
  }

  @override
  Future<void> dispose() async {
    await _tts.stop();
  }

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    // FlutterTts 不需要显式初始化，直接使用即可
    _initialized = true;
  }
}
