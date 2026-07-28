import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/ai_sentence.dart';
import '../services/ai_profile_service.dart';
import '../services/ai_service.dart';

/// AI 句子评测服务
class AiSentenceService {
  static const String _prefsSentenceLimitKey = 'practice_sentence_limit';
  static const String _prefsExtraWordCountKey = 'beginner_extra_word_count';
  static const String _prefsPracticeModeKey = 'practice_mode';

  final AiProfileService _profileService;
  final AiService _aiService;

  AiSentenceService({AiProfileService? profileService, AiService? aiService})
    : _profileService = profileService ?? AiProfileService(),
      _aiService = aiService ?? AiService();

  // ===== 设置项 =====
  Future<int> getSentenceLimit() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_prefsSentenceLimitKey) ?? 10;
  }

  Future<void> setSentenceLimit(int limit) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefsSentenceLimitKey, limit.clamp(1, 50));
  }

  Future<int> getExtraWordCount() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_prefsExtraWordCountKey) ?? 3;
  }

  Future<void> setExtraWordCount(int count) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefsExtraWordCountKey, count.clamp(1, 5));
  }

  Future<PracticeMode> getPracticeMode() async {
    final prefs = await SharedPreferences.getInstance();
    final index = prefs.getInt(_prefsPracticeModeKey) ?? 0;
    return index == 0 ? PracticeMode.beginner : PracticeMode.advanced;
  }

  Future<void> setPracticeMode(PracticeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      _prefsPracticeModeKey,
      mode == PracticeMode.beginner ? 0 : 1,
    );
  }

  // ===== 评测 =====
  Future<AiSentenceResult> evaluate({
    required Sentence sentence,
    required String userAnswer,
    required PracticeMode mode,
    List<String>? shuffledWords,
    CancelToken? cancelToken,
  }) async {
    // 获取默认配置
    await _profileService.load();
    final profile = _profileService.defaultProfile;
    if (profile == null || profile.apiKey.isEmpty) {
      throw AiServiceException('请先在设置中配置 AI 服务');
    }
    _aiService.setCurrentProfile(profile);

    // 构建 messages
    final systemPrompt = _buildSystemPrompt(mode);
    final userPrompt = _buildUserPrompt(
      sentence: sentence,
      userAnswer: userAnswer,
      mode: mode,
      shuffledWords: shuffledWords,
    );

    final messages = [
      {'role': 'system', 'content': systemPrompt},
      {'role': 'user', 'content': userPrompt},
    ];

    final response = await _aiService.chat(
      messages: messages,
      cancelToken: cancelToken,
    );

    // 解析 JSON - 处理可能因推理模式带来的额外文本
    final jsonStr = _extractJson(response);
    if (jsonStr == null) {
      throw AiServiceException('AI 返回格式异常，无法解析批改结果');
    }

    try {
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      return AiSentenceResult.fromJson(data);
    } catch (e) {
      throw AiServiceException('AI 返回数据格式错误：$e');
    }
  }

  /// 从 AI 回复中提取 JSON 对象
  String? _extractJson(String response) {
    // 尝试直接解析
    final trimmed = response.trim();
    if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
      return trimmed;
    }

    // 尝试用正则提取 {...}
    final regex = RegExp(r'\{[^{}]*\}', dotAll: true);
    final matches = regex.allMatches(trimmed);
    for (final match in matches) {
      final candidate = match.group(0)!;
      try {
        final parsed = jsonDecode(candidate);
        if (parsed is Map<String, dynamic> &&
            parsed.containsKey('score') &&
            parsed.containsKey('markup') &&
            parsed.containsKey('comment')) {
          return candidate;
        }
      } catch (_) {
        continue;
      }
    }

    // 尝试提取 ```json ... ``` 代码块
    final codeBlockRegex = RegExp(r'```(?:json)?\s*([\s\S]*?)```');
    final codeMatch = codeBlockRegex.firstMatch(trimmed);
    if (codeMatch != null) {
      final code = codeMatch.group(1)?.trim();
      if (code != null && code.startsWith('{')) {
        return code;
      }
    }

    return null;
  }

  String _buildSystemPrompt(PracticeMode mode) {
    return '''你是一个英语句子批改助手。用户正在进行英文句子写作练习。

请根据用户回答与正确答案的对比，返回**纯 JSON 对象**，不要包含任何其他文字、推理过程或 Markdown 代码块标记。

JSON 格式：
{
  "score": 整数(0-10),
  "markup": "字符串(带HTML标签的原文，或空字符串)",
  "comment": "字符串(约100个中文字符)"
}

=== 评分细则（10分制，精确到整数） ===
- 10分：完全正确。拼写、语法、标点、大小写、专有名词格式、语序、用词地道性均无可挑剔。
- 9分：存在以下任一轻微问题，且仅有一处：标点符号使用不当；大小写错误；专有名词拼写偏差；非关键拼写错误；表达符合语法但不符合英语惯用法（中式英语直译）。
- 8分：有两处以内（含两处）的语法或词汇错误，但不妨碍整体理解。例如时态混用、主谓不一致、介词搭配错误。
- 7分：存在三处及以上错误，或有一处结构性错误（如从句连接词缺失），导致部分句意模糊，但核心意思仍可推测。
- 6分：句子结构有严重缺陷，如关键成分缺失（缺主语或谓语）、语序完全混乱，但尚能看出与中文对应的若干词汇。
- 5分：用户进行了翻译尝试，但错误过半，只有不到一半的内容正确，整体意思难以连贯理解。
- 4分：仅有少数单词正确（如一两个关键词），其余完全无关或错误。
- 3分：回答与中文意思基本无关，或仅写了零散单词无结构。
- 2分：仅重复中文或无效字符（如数字、符号）。
- 1分：完全空白或"不知道"等无意义内容。
- 0分：AI 无法解析回答（如乱码）。

=== 批改（markup）规则 ===
- 基于用户原始回答的字符串，逐词/标点进行标注。
- 默认所有内容为正确，无需显式标记。
- 若存在错误，使用以下标签：
  - <red>严重错误：核心语法错误（时态、语态、主谓一致根本性错误）；完全用错词汇；关键结构缺失或多余。
  - <yellow>轻微错误：大小写、标点、冠词误用；介词搭配欠妥；非关键词拼写错误。
- 标注顺序应与原回答中的单词顺序一致。
- 若回答完全正确，markup 返回空字符串。

=== 批注（comment）要求 ===
- 长度控制在100个中文字符左右（允许±20字）。
- 内容需包含：指出错误所在；分析可能原因；给出具体修改建议；解释修改原因。
- 若全对，则为表扬性语句。''';
  }

  String _buildUserPrompt({
    required Sentence sentence,
    required String userAnswer,
    required PracticeMode mode,
    List<String>? shuffledWords,
  }) {
    final buffer = StringBuffer();
    buffer.writeln('模式：${mode == PracticeMode.beginner ? "入门版" : "高阶版"}');
    buffer.writeln('中文翻译：${sentence.chinese}');
    buffer.writeln('正确答案：${sentence.english}');

    if (mode == PracticeMode.beginner && shuffledWords != null) {
      buffer.writeln('给出的词块列表：${shuffledWords.join(" ")}');
    }

    buffer.writeln('---');
    buffer.writeln('用户回答：$userAnswer');
    buffer.writeln('---');
    buffer.writeln('请根据以上信息给出评分、批改和批注。');

    return buffer.toString();
  }
}
