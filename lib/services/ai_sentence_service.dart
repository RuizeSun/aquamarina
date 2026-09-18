import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import '../models/ai_sentence.dart';
import '../services/ai_profile_service.dart';
import '../services/ai_service.dart';
import 'database_service.dart';
import 'log_service.dart';
import 'sentence_eval_cache_service.dart';

/// AI 句子评测服务
class AiSentenceService {
  static const String _prefsSentenceLimitKey = 'practice_sentence_limit';
  static const String _prefsExtraWordCountKey = 'beginner_extra_word_count';
  static const String _prefsPracticeModeKey = 'practice_mode';

  // 错题本相关（SQLite，这些 key 只作为默认值）
  static const String _prefsWrongScoreThresholdKey = 'wrong_score_threshold';
  static const String _prefsSkipRepeatedKey = 'skip_repeated_sentences';

  final AiProfileService _profileService;
  final AiService _aiService;
  final SentenceEvalCacheService _cacheService;

  /// 数据库访问入口（生产环境为业务数据库，测试可注入 sqflite ffi 内存库）
  final Future<Database> Function() _openDatabase;

  AiSentenceService({
    AiProfileService? profileService,
    AiService? aiService,
    SentenceEvalCacheService? cacheService,
    @visibleForTesting Future<Database> Function()? openDatabase,
  }) : _profileService = profileService ?? AiProfileService(),
       _aiService = aiService ?? AiService(),
       _cacheService = cacheService ?? SentenceEvalCacheService.instance,
       _openDatabase = openDatabase ?? (() => DatabaseService.database);

  /// 业务数据库访问入口（错题本 / 已练习标记等本地数据）
  Future<Database> get _db => _openDatabase();

  // ===== 设置项（SharedPreferences 保留） =====
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

  // ===== 错题本设置 =====

  /// 错题本阈值：得分 <= 该值的句子加入错题本（默认 8）
  Future<int> getWrongScoreThreshold() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_prefsWrongScoreThresholdKey) ?? 8;
  }

  Future<void> setWrongScoreThreshold(int threshold) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefsWrongScoreThresholdKey, threshold.clamp(1, 10));
  }

  /// 是否不再练习重复句子（默认 true）
  Future<bool> getSkipRepeated() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_prefsSkipRepeatedKey) ?? true;
  }

  Future<void> setSkipRepeated(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsSkipRepeatedKey, value);
  }

  // ===== 已练习句子追踪（SQLite） =====

  /// 获取某个句式集中已练习过的句子 ID 列表
  Future<Set<String>> getPracticedSentenceIds(String setId) async {
    final db = await _db;
    final maps = await db.query(
      'practiced_sentence_ids',
      columns: ['sentence_id'],
      where: 'set_id = ?',
      whereArgs: [setId],
    );
    return maps.map((m) => m['sentence_id'] as String).toSet();
  }

  /// 标记某个句子为已练习
  Future<void> markSentencePracticed(String setId, String sentenceId) async {
    final db = await _db;
    await db.insert('practiced_sentence_ids', {
      'set_id': setId,
      'sentence_id': sentenceId,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  // ===== 错题本 CRUD（SQLite） =====

  /// 错题记录的业务主键：优先使用句子 ID；无 ID（临时构造的句子）时
  /// 回退到英文原文生成稳定 key（与句子收藏/笔记的约定保持一致），
  /// 避免不同句子共用空键而被误合并或误删除。
  static String wrongSentenceKey({
    required String? sentenceId,
    required String english,
  }) {
    final id = sentenceId ?? '';
    return id.isNotEmpty ? id : 'bytext:$english';
  }

  /// 获取所有错题（按最近一次答错时间倒序）
  Future<List<WrongSentenceRecord>> getWrongSentences() async {
    final db = await _db;
    final maps = await db.query(
      'wrong_sentences',
      orderBy: 'COALESCE(last_wrong_at, created_at) DESC, created_at DESC',
    );
    return maps.map((m) => _rowToWrongSentence(m)).toList();
  }

  /// 获取错题数量（同一句子只计一条）
  Future<int> getWrongSentenceCount() async {
    final db = await _db;
    final count =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM wrong_sentences'),
        ) ??
        0;
    return count;
  }

  /// 加入错题本（同一句子自动合并为一条记录）
  ///
  /// - 首次答错：插入新记录，`wrong_count = 1`
  /// - 再次答错：合并到已有记录，累计 `wrong_count`，得分 / 回答 / 模式 /
  ///   答错时间更新为最近一次，首次收录时间（`created_at`）保持不变
  Future<void> addWrongSentence(WrongSentenceRecord record) async {
    final db = await _db;
    final key = wrongSentenceKey(
      sentenceId: record.sentenceId,
      english: record.english,
    );
    final row = _wrongSentenceToRow(record)..['sentence_id'] = key;

    final existing = await db.query(
      'wrong_sentences',
      columns: ['id', 'created_at', 'wrong_count'],
      where: 'sentence_id = ?',
      whereArgs: [key],
      orderBy: 'created_at DESC',
      limit: 1,
    );

    if (existing.isEmpty) {
      await db.insert(
        'wrong_sentences',
        row,
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      return;
    }

    await db.update(
      'wrong_sentences',
      {
        'set_id': row['set_id'],
        'english': row['english'],
        'chinese': row['chinese'],
        'score': row['score'],
        'user_answer': row['user_answer'],
        'mode': row['mode'],
        'wrong_count':
            ((existing.first['wrong_count'] as num?)?.toInt() ?? 1) + 1,
        'last_wrong_at': row['last_wrong_at'],
      },
      where: 'id = ?',
      whereArgs: [existing.first['id']],
    );
  }

  /// 从错题本中移除（[sentenceId] 为 [wrongSentenceKey] 生成的主键）
  Future<void> removeWrongSentence(String sentenceId) async {
    final db = await _db;
    await db.delete(
      'wrong_sentences',
      where: 'sentence_id = ?',
      whereArgs: [sentenceId],
    );
  }

  /// 清空错题本
  Future<void> clearWrongSentences() async {
    final db = await _db;
    await db.delete('wrong_sentences');
  }

  // ===== 批改结果缓存（SQLite） =====
  //
  // 命中规则：相同句子（中文 + 英文）+ 相同用户回答 + 相同练习模式。
  // 具体实现见 SentenceEvalCacheService。

  /// 查询本地缓存的批改结果；未命中返回 null（调用方继续走 AI 批改）
  Future<AiSentenceResult?> lookupCachedResult({
    required Sentence sentence,
    required String userAnswer,
    required PracticeMode mode,
  }) {
    return _cacheService.lookup(
      sentence: sentence,
      userAnswer: userAnswer,
      mode: mode,
    );
  }

  /// 写入批改结果缓存（缓存关闭或写入失败时静默跳过）
  Future<void> storeCachedResult({
    required Sentence sentence,
    required String userAnswer,
    required PracticeMode mode,
    required AiSentenceResult result,
    String? profileName,
    String? model,
  }) {
    // 未显式传入时，用已加载的默认配置补齐元信息（不触发额外 I/O）
    if (profileName == null && model == null && _profileService.loaded) {
      final profile = _profileService.defaultProfile;
      profileName = profile?.name;
      model = profile?.model;
    }
    return _cacheService.store(
      sentence: sentence,
      userAnswer: userAnswer,
      mode: mode,
      result: result,
      profileName: profileName,
      model: model,
    );
  }

  /// 删除某条缓存（用于「重新批改」时强制走一次 AI）
  Future<void> removeCachedResult({
    required Sentence sentence,
    required String userAnswer,
    required PracticeMode mode,
  }) {
    return _cacheService.remove(
      sentence: sentence,
      userAnswer: userAnswer,
      mode: mode,
    );
  }

  // ===== 内部方法 =====

  static WrongSentenceRecord _rowToWrongSentence(Map<String, dynamic> row) {
    return WrongSentenceRecord(
      id: row['id'] as String,
      sentenceId: row['sentence_id'] as String,
      setId: row['set_id'] as String,
      english: row['english'] as String,
      chinese: row['chinese'] as String,
      score: (row['score'] as num).toInt(),
      userAnswer: row['user_answer'] as String,
      mode: (row['mode'] as int) == 0
          ? PracticeMode.beginner
          : PracticeMode.advanced,
      createdAt: DateTime.parse(row['created_at'] as String),
      wrongCount: (row['wrong_count'] as num?)?.toInt() ?? 1,
      lastWrongAt: row['last_wrong_at'] != null
          ? DateTime.tryParse(row['last_wrong_at'] as String)
          : null,
    );
  }

  static Map<String, dynamic> _wrongSentenceToRow(WrongSentenceRecord r) {
    return {
      'id': r.id,
      'sentence_id': r.sentenceId,
      'set_id': r.setId,
      'english': r.english,
      'chinese': r.chinese,
      'score': r.score,
      'user_answer': r.userAnswer,
      'mode': r.mode == PracticeMode.beginner ? 0 : 1,
      'created_at': r.createdAt.toIso8601String(),
      'wrong_count': r.wrongCount,
      'last_wrong_at': r.latestWrongAt.toIso8601String(),
    };
  }

  // ===== 评测 =====

  /// 构建评测所需的 messages 列表（OpenAI 兼容协议）
  List<Map<String, String>> _buildEvaluateMessages({
    required Sentence sentence,
    required String userAnswer,
    required PracticeMode mode,
    List<String>? shuffledWords,
  }) {
    final systemPrompt = _buildSystemPrompt(mode);
    final userPrompt = _buildUserPrompt(
      sentence: sentence,
      userAnswer: userAnswer,
      mode: mode,
      shuffledWords: shuffledWords,
    );
    return [
      {'role': 'system', 'content': systemPrompt},
      {'role': 'user', 'content': userPrompt},
    ];
  }

  /// 流式评测：边接收边返回 AI 批改内容片段
  ///
  /// - Aquamarina 官方 API：不支持流式，内部仍走非流式端点，
  ///   返回包含完整响应的单元素流。
  /// - OpenAI / DeepSeek：使用 [AiService.chatStream]，
  ///   过滤思维链内容，仅暴露正式回答的增量片段。
  ///
  /// [cancelToken] 传入后可在页面退出时取消未完成的请求。
  Stream<String> evaluateStream({
    required Sentence sentence,
    required String userAnswer,
    required PracticeMode mode,
    List<String>? shuffledWords,
    CancelToken? cancelToken,
  }) async* {
    await _profileService.load();
    final profile = _profileService.defaultProfile;
    if (profile == null) {
      throw AiServiceException('请先在设置中配置 AI 服务');
    }
    _aiService.setCurrentProfile(profile);

    if (profile.isAquamarina) {
      // Aquamarina 官方 API 不支持流式，一次性返回完整内容
      final modeStr = mode == PracticeMode.beginner ? 'beginner' : 'high_level';
      final response = await _aiService.callAquamarinaSentence(
        mode: modeStr,
        sentence: {'chinese': sentence.chinese, 'english': sentence.english},
        userAnswer: userAnswer,
        shuffledWords: shuffledWords,
        baseUrl: profile.baseUrl,
        cancelToken: cancelToken,
      );
      yield response;
      return;
    }

    if (profile.apiKey.isEmpty) {
      throw AiServiceException('请先在设置中配置 API Key');
    }

    final messages = _buildEvaluateMessages(
      sentence: sentence,
      userAnswer: userAnswer,
      mode: mode,
      shuffledWords: shuffledWords,
    );

    yield* _aiService.chatStream(
      messages: messages,
      includeReasoningContent: false,
      cancelToken: cancelToken,
    );
  }

  Future<AiSentenceResult> evaluate({
    required Sentence sentence,
    required String userAnswer,
    required PracticeMode mode,
    List<String>? shuffledWords,
    CancelToken? cancelToken,
    bool useCache = true,
  }) async {
    // 先查缓存：相同句子 + 相同回答 + 相同模式时直接复用，不再调用 AI
    if (useCache) {
      final cached = await lookupCachedResult(
        sentence: sentence,
        userAnswer: userAnswer,
        mode: mode,
      );
      if (cached != null) return cached;
    }

    logInfo('AiSentenceService', '评测句子 mode=${mode.name}');
    // 获取默认配置
    await _profileService.load();
    final profile = _profileService.defaultProfile;
    if (profile == null) {
      throw AiServiceException('请先在设置中配置 AI 服务');
    }
    _aiService.setCurrentProfile(profile);

    String response;

    try {
      if (profile.isAquamarina) {
        // Aquamarina 官方 API：使用专用端点
        final modeStr = mode == PracticeMode.beginner
            ? 'beginner'
            : 'high_level';
        response = await _aiService.callAquamarinaSentence(
          mode: modeStr,
          sentence: {'chinese': sentence.chinese, 'english': sentence.english},
          userAnswer: userAnswer,
          shuffledWords: shuffledWords,
          baseUrl: profile.baseUrl,
          cancelToken: cancelToken,
        );
      } else {
        // 标准 OpenAI 兼容协议（OpenAI / DeepSeek）
        if (profile.apiKey.isEmpty) {
          throw AiServiceException('请先在设置中配置 API Key');
        }

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

        response = await _aiService.chat(
          messages: messages,
          cancelToken: cancelToken,
        );
      }
    } on AiServiceException catch (e) {
      if (e.isRateLimit) {
        if (profile.isAquamarina) {
          throw AiServiceException(
            'Aquamarina 服务器有每分钟请求数和每天请求数的限制，请稍后再试。',
            type: 'rateLimit',
          );
        } else {
          throw AiServiceException(
            '请求过于频繁，请稍后重试（此为 API 服务端的限制，并非软件问题）。',
            type: 'rateLimit',
          );
        }
      }
      rethrow;
    }

    // 解析 JSON - 处理可能因推理模式带来的额外文本
    final jsonStr = extractJson(response);
    if (jsonStr == null) {
      throw AiServiceException('AI 返回格式异常，无法解析批改结果');
    }

    try {
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      final result = AiSentenceResult.fromJson(data);
      // 写入缓存，供相同句子与相同回答复用（失败不影响本次结果）
      await storeCachedResult(
        sentence: sentence,
        userAnswer: userAnswer,
        mode: mode,
        result: result,
        profileName: profile.name,
        model: profile.model,
      );
      return result;
    } catch (e) {
      throw AiServiceException('AI 返回数据格式错误：$e');
    }
  }

  /// 从 AI 回复中提取 JSON 对象
  /// 供流式评测场景在累积完整文本后调用
  static String? extractJson(String response) {
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
