/// MiMo TTS 预置音色目录。
///
/// 抽到独立文件是为了让「合成引擎」与「设置 / 音色校验」共用同一份数据，
/// 避免两处各自维护音色列表而出现不一致。
class MimoVoice {
  /// API `audio.voice` 字段取值，同时也是音色名
  final String id;

  /// 分组名（默认 / 中文 / 英文）
  final String language;

  /// 性别 / 说明
  final String hint;

  const MimoVoice(this.id, this.language, this.hint);
}

/// `mimo-v2.5-tts` 支持的预置音色
const List<MimoVoice> mimoPresetVoices = [
  MimoVoice('mimo_default', '默认', '因集群而异，中国集群为「冰糖」'),
  MimoVoice('冰糖', '中文', '女性'),
  MimoVoice('茉莉', '中文', '女性'),
  MimoVoice('苏打', '中文', '男性'),
  MimoVoice('白桦', '中文', '男性'),
  MimoVoice('Mia', '英文', '女性'),
  MimoVoice('Chloe', '英文', '女性'),
  MimoVoice('Milo', '英文', '男性'),
  MimoVoice('Dean', '英文', '男性'),
];
