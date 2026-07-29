/// TTS 引擎抽象接口
abstract class TtsEngine {
  /// 朗读文本
  Future<void> speak(String text);

  /// 停止朗读
  Future<void> stop();

  /// 设置音量 0.0~1.0
  Future<void> setVolume(double volume);

  /// 设置语速 0.5~2.0
  Future<void> setRate(double rate);

  /// 设置音调 0.5~2.0
  Future<void> setPitch(double pitch);

  /// 获取可用音色列表
  Future<List<String>> getVoices();

  /// 设置音色
  Future<void> setVoice(String name);

  /// 释放资源
  Future<void> dispose();
}
