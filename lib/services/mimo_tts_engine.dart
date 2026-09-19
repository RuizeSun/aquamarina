import 'dart:convert';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:dio/dio.dart';

import 'log_service.dart';
import 'mimo_tts_credentials.dart';
import 'tts_engine.dart';
import 'tts_settings.dart';

/// MiMo 预置音色（用于设置页分组展示）
class MimoVoice {
  /// API `audio.voice` 字段取值，同时也是音色名
  final String id;

  /// 分组名（默认 / 中文 / 英文）
  final String language;

  /// 性别 / 说明
  final String hint;

  const MimoVoice(this.id, this.language, this.hint);
}

/// 基于小米 MiMo TTS（OpenAI 兼容 `chat/completions`）的在线语音合成引擎
///
/// 接口约定（官方文档《语音合成（MiMo-TTS 系列）》）：
/// - 端点：`POST {baseUrl}/chat/completions`
/// - 鉴权：`Authorization: Bearer <MIMO_API_KEY>`
/// - 待合成文本**必须**放在 `role: assistant` 的消息中；
///   可选的 `role: user` 消息用于自然语言风格控制（语速、情绪、方言、角色扮演等）。
/// - 音频以 base64 返回在 `choices[0].message.audio.data`
///
/// 注意：该接口没有音调（pitch）参数，[setPitch] 仅记录数值不生效；
/// 语速通过播放器倍速近似实现，更精细的语速可用风格指令或音频标签表达。
class MimoTtsEngine implements TtsEngine {
  MimoTtsEngine({
    required String baseUrl,
    required String model,
    required String voice,
    String instruction = '',
    String styleTag = '',
    Dio? dio,
  }) : _baseUrl = baseUrl,
       _model = model,
       _voice = voice,
       _instruction = instruction,
       _styleTag = styleTag,
       _dio = dio ?? Dio();

  /// 官方默认接口地址（与设置中的默认值保持单一数据源）
  static const String defaultBaseUrl = TtsSettings.defaultMimoBaseUrl;

  /// 当前适配的模型 ID
  static const String defaultModel = TtsSettings.defaultMimoModel;

  /// 默认音色（中国集群为「冰糖」，其他集群为 Mia）
  static const String defaultVoice = TtsSettings.defaultMimoVoice;

  /// `mimo-v2.5-tts` 支持的预置音色
  static const List<MimoVoice> presetVoices = [
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

  /// 输出音频格式：mp3 体积小且 audioplayers 可直接播放
  static const String _outputFormat = 'mp3';
  static const String _mp3MimeType = 'audio/mpeg';

  String _baseUrl;
  String _model;
  String _voice;
  String _instruction;
  String _styleTag;

  final Dio _dio;
  AudioPlayer? _player;

  // 当前设置
  double _volume = 1.0;
  double _rate = 1.0;
  double _pitch = 1.0;

  /// 请求地址：Base URL 若已包含接口路径则直接使用
  String get _endpoint {
    final base = _baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (base.isEmpty) return '$defaultBaseUrl/chat/completions';
    if (base.endsWith('/chat/completions')) return base;
    return '$base/chat/completions';
  }

  /// 更新 MiMo 专属配置（Base URL / 模型 / 风格指令 / 音频标签前缀）
  void updateConfig({
    String? baseUrl,
    String? model,
    String? instruction,
    String? styleTag,
  }) {
    if (baseUrl != null) _baseUrl = baseUrl;
    if (model != null) _model = model;
    if (instruction != null) _instruction = instruction;
    if (styleTag != null) _styleTag = styleTag;
  }

  @override
  Future<bool> speak(String text) async {
    if (text.isEmpty) return false;

    final apiKey = await MimoTtsCredentials.read();
    if (apiKey.isEmpty) {
      logWarning('MimoTtsEngine', '未配置 API Key，跳过朗读');
      return false;
    }

    final player = await _ensureAudioPlayer();
    // 停止之前的朗读
    await player.stop();

    try {
      final response = await _dio.post<dynamic>(
        _endpoint,
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $apiKey',
          },
          sendTimeout: const Duration(seconds: 30),
          receiveTimeout: const Duration(seconds: 60),
        ),
        data: buildRequestBody(
          model: _model,
          text: text,
          voice: _voice,
          instruction: _instruction,
          styleTag: _styleTag,
        ),
      );

      final audioBytes = extractAudioBytes(response.data);
      if (audioBytes == null || audioBytes.isEmpty) {
        logError('MimoTtsEngine', '响应中未包含音频数据');
        return false;
      }

      await _applyPlaybackParams(player);
      await player.play(BytesSource(audioBytes, mimeType: _mp3MimeType));
      return true;
    } on DioException catch (e) {
      logError('MimoTtsEngine', 'speak 失败: ${_mapDioError(e)}');
      return false;
    } catch (e) {
      logError('MimoTtsEngine', 'speak 失败: $e');
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
    await _player?.setPlaybackRate(_rate);
  }

  @override
  Future<void> setPitch(double pitch) async {
    // MiMo TTS 接口不支持音调参数，仅记录数值（设置页会提示不支持）
    _pitch = pitch.clamp(0.5, 2.0);
  }

  /// 当前记录的音调值（MiMo 不支持，仅供调试查看）
  double get pitch => _pitch;

  @override
  Future<List<String>> getVoices() async =>
      presetVoices.map((v) => v.id).toList();

  @override
  Future<void> setVoice(String name) async {
    final trimmed = name.trim();
    _voice = trimmed.isEmpty ? defaultVoice : trimmed;
  }

  @override
  Future<void> dispose() async {
    await _player?.dispose();
    _player = null;
  }

  // ─── 纯函数（便于单元测试）─────────────────────

  /// 构建请求体。
  ///
  /// 待合成文本放在 `assistant` 消息；`user` 消息为可选的风格指令。
  static Map<String, dynamic> buildRequestBody({
    required String model,
    required String text,
    required String voice,
    String instruction = '',
    String styleTag = '',
  }) {
    final messages = <Map<String, String>>[];
    final prompt = instruction.trim();
    if (prompt.isNotEmpty) {
      messages.add({'role': 'user', 'content': prompt});
    }
    messages.add({
      'role': 'assistant',
      'content': applyStyleTag(text, styleTag),
    });

    final modelId = model.trim().isEmpty ? defaultModel : model.trim();
    final voiceId = voice.trim().isEmpty ? defaultVoice : voice.trim();

    return {
      'model': modelId,
      'messages': messages,
      'audio': {'format': _outputFormat, 'voice': voiceId},
    };
  }

  /// 将音频标签前缀拼接到待合成文本最前面，如 `(东北话)你好`。
  ///
  /// 标签未自带括号时自动补圆括号（官方支持 `()` / `（）` / `[]`）。
  static String applyStyleTag(String text, String styleTag) {
    var tag = styleTag.trim();
    if (tag.isEmpty) return text;
    final hasBracket =
        tag.startsWith('(') || tag.startsWith('（') || tag.startsWith('[');
    if (!hasBracket) tag = '($tag)';
    return '$tag$text';
  }

  /// 从响应中提取音频字节（base64 → bytes），无音频时返回 `null`
  static Uint8List? extractAudioBytes(dynamic responseData) {
    if (responseData is! Map) return null;

    final choices = responseData['choices'];
    if (choices is! List || choices.isEmpty) return null;

    final first = choices.first;
    if (first is! Map) return null;

    final message = first['message'];
    if (message is! Map) return null;

    final audio = message['audio'];
    if (audio is! Map) return null;

    final data = audio['data'];
    if (data is! String || data.isEmpty) return null;

    try {
      return base64Decode(data);
    } catch (e) {
      logError('MimoTtsEngine', '音频 base64 解码失败: $e');
      return null;
    }
  }

  // ─── 内部方法 ─────────────────────────────────

  Future<AudioPlayer> _ensureAudioPlayer() async {
    if (_player != null) return _player!;
    final player = AudioPlayer();
    await player.setVolume(_volume);
    await player.setPlaybackRate(_rate);
    _player = player;
    return player;
  }

  Future<void> _applyPlaybackParams(AudioPlayer player) async {
    await player.setVolume(_volume);
    await player.setPlaybackRate(_rate);
  }

  /// 将 Dio 异常转换为可读提示（与 AiService 的错误映射保持一致）
  String _mapDioError(DioException e) {
    final statusCode = e.response?.statusCode;
    if (statusCode == null) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.connectionError) {
        return '连接超时或失败，请检查网络或 Base URL';
      }
      return '网络连接失败：${e.message}';
    }

    final detail = _extractErrorMessage(e.response?.data);
    switch (statusCode) {
      case 401:
      case 403:
        return 'API Key 无效，请检查后重试';
      case 429:
        return '请求过于频繁，请稍后重试';
      case 404:
        return '接口地址不存在，请检查 Base URL';
      case >= 500:
        return '服务端错误（HTTP $statusCode）';
      default:
        return '请求失败（HTTP $statusCode${detail != null ? '：$detail' : ''}）';
    }
  }

  String? _extractErrorMessage(dynamic data) {
    if (data is! Map) return null;
    final error = data['error'];
    if (error is String) return error;
    if (error is Map) {
      final message = error['message'];
      if (message is String) return message;
    }
    return null;
  }
}
