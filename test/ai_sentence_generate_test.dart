import 'dart:convert';

import 'package:aquamarina/models/ai_profile.dart';
import 'package:aquamarina/models/sentence_difficulty.dart';
import 'package:aquamarina/services/ai_profile_service.dart';
import 'package:aquamarina/services/ai_sentence_generate_service.dart';
import 'package:aquamarina/services/ai_token_estimator.dart';
import 'package:aquamarina/services/ai_usage_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// 用可注入的假配置服务替代真实实现，避免在单测里触碰安全存储与网络。
class _FakeProfileService extends AiProfileService {
  final AiProfile? profile;

  _FakeProfileService(this.profile);

  @override
  Future<void> load() async {}

  @override
  AiProfile? get defaultProfile => profile;
}

AiProfile _openAiProfile({
  String apiKey = 'sk-test',
  int maxTokens = 2048,
  AiUsagePricing? pricing,
}) {
  return AiProfile(
    id: 'p1',
    name: '测试配置',
    type: AiProfileType.openai,
    apiKey: apiKey,
    model: 'gpt-4o-mini',
    maxTokens: maxTokens,
    pricing: pricing,
  );
}

AiProfile _deepSeekProfile({
  bool thinking = false,
  String? effort,
  int maxTokens = 8192,
  AiUsagePricing? pricing,
}) {
  return AiProfile(
    id: 'p2',
    name: 'DeepSeek',
    type: AiProfileType.deepseek,
    apiKey: 'sk-ds',
    model: 'deepseek-chat',
    maxTokens: maxTokens,
    enableThinking: thinking,
    reasoningEffort: effort,
    pricing: pricing,
  );
}

AiProfile _aquamarinaProfile() => AiProfile(
  id: 'p3',
  name: 'Aquamarina 官方',
  type: AiProfileType.aquamarina,
  apiKey: 'aquamarinapublicapi',
  model: 'default',
  maxTokens: 4096,
);

List<WordPromptEntry> _entries(int count) => List.generate(
  count,
  (i) => WordPromptEntry(word: 'word$i', gloss: '释义$i'),
);

void main() {
  group('SentenceDifficulty', () {
    test('六档难度与 CEFR 等级一一对应', () {
      expect(SentenceDifficulty.values.length, 6);
      expect(SentenceDifficulty.starter.cefr, 'A1');
      expect(SentenceDifficulty.basic.cefr, 'A2');
      expect(SentenceDifficulty.intermediate.cefr, 'B1');
      expect(SentenceDifficulty.upperIntermediate.cefr, 'B2');
      expect(SentenceDifficulty.advanced.cefr, 'C1');
      expect(SentenceDifficulty.mastery.cefr, 'C2');
      expect(SentenceDifficulty.starter.label, '入门');
      expect(SentenceDifficulty.mastery.label, '自由运用');
      expect(SentenceDifficulty.mastery.displayName, '自由运用（C2）');
    });

    test('难度越高，单句输出 token 估算越大', () {
      for (var i = 1; i < SentenceDifficulty.values.length; i++) {
        expect(
          SentenceDifficulty.values[i].tokensPerSentence,
          greaterThan(SentenceDifficulty.values[i - 1].tokensPerSentence),
        );
      }
    });

    test('fromName 未知值回退到入门', () {
      expect(SentenceDifficulty.fromName('advanced'), SentenceDifficulty.advanced);
      expect(SentenceDifficulty.fromName('nope'), SentenceDifficulty.starter);
      expect(SentenceDifficulty.fromName(null), SentenceDifficulty.starter);
    });
  });

  group('AiTokenEstimator', () {
    test('空文本为 0', () {
      expect(AiTokenEstimator.estimate(''), 0);
    });

    test('英文按约 4 字符 1 token 估算', () {
      expect(AiTokenEstimator.estimate('abcd'), 1);
      expect(AiTokenEstimator.estimate('abcde'), 2);
    });

    test('中文按约 1 字 1 token 估算', () {
      expect(AiTokenEstimator.estimate('你好世界'), 4);
    });

    test('中英混排分别计数后相加', () {
      // 4 个汉字 + 4 个英文字符
      expect(AiTokenEstimator.estimate('你好世界abcd'), 5);
    });

    test('messages 估算包含每条消息的模板开销', () {
      final single = AiTokenEstimator.estimateMessages([
        {'role': 'user', 'content': 'abcd'},
      ]);
      final double = AiTokenEstimator.estimateMessages([
        {'role': 'user', 'content': 'abcd'},
        {'role': 'assistant', 'content': 'abcd'},
      ]);
      expect(single, greaterThan(1));
      expect(double, greaterThan(single));
    });
  });

  group('AiSentenceGenerator.resolveProfile', () {
    test('未配置任何 AI 配置时抛 notConfigured', () async {
      final generator = AiSentenceGenerator(
        profileService: _FakeProfileService(null),
      );
      await expectLater(
        generator.resolveProfile(),
        throwsA(
          isA<AiSentenceGenerateException>().having(
            (e) => e.code,
            'code',
            AiSentenceGenerateError.notConfigured,
          ),
        ),
      );
    });

    test('Aquamarina 官方配置被拒绝', () async {
      final generator = AiSentenceGenerator(
        profileService: _FakeProfileService(_aquamarinaProfile()),
      );
      await expectLater(
        generator.resolveProfile(),
        throwsA(
          isA<AiSentenceGenerateException>()
              .having((e) => e.code, 'code', AiSentenceGenerateError.aquamarina)
              .having((e) => e.message, 'message', contains('不支持')),
        ),
      );
    });

    test('缺少 API Key 时抛 missingApiKey', () async {
      final generator = AiSentenceGenerator(
        profileService: _FakeProfileService(_openAiProfile(apiKey: '')),
      );
      await expectLater(
        generator.resolveProfile(),
        throwsA(
          isA<AiSentenceGenerateException>().having(
            (e) => e.code,
            'code',
            AiSentenceGenerateError.missingApiKey,
          ),
        ),
      );
    });

    test('OpenAI 兼容配置可用', () async {
      final profile = _openAiProfile();
      final generator = AiSentenceGenerator(
        profileService: _FakeProfileService(profile),
      );
      expect(await generator.resolveProfile(), same(profile));
    });
  });

  group('AiSentenceGenerator 规模推导', () {
    test('max_tokens 充足时每次请求覆盖 12 个单词', () {
      final profile = _openAiProfile(maxTokens: 8192);
      expect(
        AiSentenceGenerator.wordsPerRequestFor(
          profile: profile,
          difficulty: SentenceDifficulty.starter,
          sentencesPerWord: 1,
        ),
        12,
      );
    });

    test('每词句数增加时每次请求覆盖的单词数按比例减少', () {
      final profile = _openAiProfile(maxTokens: 8192);
      expect(
        AiSentenceGenerator.wordsPerRequestFor(
          profile: profile,
          difficulty: SentenceDifficulty.starter,
          sentencesPerWord: 2,
        ),
        6,
      );
      expect(
        AiSentenceGenerator.wordsPerRequestFor(
          profile: profile,
          difficulty: SentenceDifficulty.starter,
          sentencesPerWord: 3,
        ),
        4,
      );
    });

    test('max_tokens 很小时批量随之收缩，避免 JSON 被截断', () {
      final profile = _openAiProfile(maxTokens: 100);
      expect(
        AiSentenceGenerator.sentencesPerRequestFor(
          profile: profile,
          difficulty: SentenceDifficulty.starter,
        ),
        2,
      );
      expect(
        AiSentenceGenerator.wordsPerRequestFor(
          profile: profile,
          difficulty: SentenceDifficulty.starter,
          sentencesPerWord: 1,
        ),
        2,
      );
    });

    test('每词句数会被夹在 1~3 之间', () {
      final profile = _openAiProfile(maxTokens: 8192);
      expect(
        AiSentenceGenerator.wordsPerRequestFor(
          profile: profile,
          difficulty: SentenceDifficulty.starter,
          sentencesPerWord: 0,
        ),
        12,
      );
      expect(
        AiSentenceGenerator.wordsPerRequestFor(
          profile: profile,
          difficulty: SentenceDifficulty.starter,
          sentencesPerWord: 9,
        ),
        4,
      );
    });
  });

  group('AiSentenceGenerator.estimate', () {
    final generator = AiSentenceGenerator(
      profileService: _FakeProfileService(null),
    );

    test('请求次数与句子总数符合预期', () {
      final estimate = generator.estimate(
        profile: _openAiProfile(maxTokens: 8192),
        entries: _entries(25),
        difficulty: SentenceDifficulty.starter,
        sentencesPerWord: 1,
      );
      expect(estimate.requestCount, 3); // ceil(25 / 12)
      expect(estimate.wordsPerRequest, 12);
      expect(estimate.totalSentences, 25);
      expect(estimate.promptTokens, greaterThan(0));
      expect(estimate.completionTokens, greaterThan(0));
      expect(estimate.totalTokens, estimate.promptTokens + estimate.completionTokens);
    });

    test('未配置价格时无法给出费用', () {
      final estimate = generator.estimate(
        profile: _openAiProfile(),
        entries: _entries(3),
        difficulty: SentenceDifficulty.basic,
        sentencesPerWord: 1,
      );
      expect(estimate.pricingConfigured, isFalse);
      expect(estimate.cost, isNull);
      expect(estimate.formatCost(), isNull);
    });

    test('按 token 计费时费用等于单价换算（输入按未命中缓存估算）', () {
      final pricing = AiUsagePricing(
        unit: AiPriceUnit.perMillion,
        cacheHitPrice: 0.5,
        cacheMissPrice: 2,
        outputPrice: 8,
      );
      final estimate = generator.estimate(
        profile: _openAiProfile(pricing: pricing),
        entries: _entries(3),
        difficulty: SentenceDifficulty.starter,
        sentencesPerWord: 1,
      );
      final expected =
          estimate.promptTokens * 2 / 1000000 +
          estimate.completionTokens * 8 / 1000000;
      expect(estimate.pricingConfigured, isTrue);
      expect(estimate.cost, closeTo(expected, 1e-12));
      expect(estimate.formatCost(), startsWith('¥'));
    });

    test('按请求计费时费用为固定价 × 请求次数', () {
      final pricing = AiUsagePricing(
        mode: AiPricingMode.perRequest,
        requestPrice: 0.02,
      );
      final estimate = generator.estimate(
        profile: _openAiProfile(maxTokens: 8192, pricing: pricing),
        entries: _entries(25),
        difficulty: SentenceDifficulty.starter,
        sentencesPerWord: 1,
      );
      expect(estimate.isPerRequest, isTrue);
      expect(estimate.requestCount, 3);
      expect(estimate.cost, closeTo(0.06, 1e-12));
    });

    test('开启思考模式会显著抬高输出 token 预估', () {
      final entries = _entries(5);
      final plain = generator.estimate(
        profile: _deepSeekProfile(thinking: false),
        entries: entries,
        difficulty: SentenceDifficulty.intermediate,
        sentencesPerWord: 1,
      );
      final thinking = generator.estimate(
        profile: _deepSeekProfile(thinking: true, effort: 'high'),
        entries: entries,
        difficulty: SentenceDifficulty.intermediate,
        sentencesPerWord: 1,
      );
      expect(thinking.thinkingEnabled, isTrue);
      expect(thinking.thinkingMultiplier, 2.0);
      expect(plain.thinkingEnabled, isFalse);
      // 输入提示词相同，仅输出被放大
      expect(thinking.promptTokens, plain.promptTokens);
      expect(thinking.completionTokens, plain.completionTokens * 2);
    });

    test('思考强度越高放大系数越大', () {
      expect(AiSentenceGenerator.thinkingOutputMultiplier('high'), 2.0);
      expect(AiSentenceGenerator.thinkingOutputMultiplier('max'), 3.0);
      expect(AiSentenceGenerator.thinkingOutputMultiplier(null), 1.6);
    });

    test('难度越高单句输出预估越大', () {
      final entries = _entries(5);
      final easy = generator.estimate(
        profile: _openAiProfile(maxTokens: 8192),
        entries: entries,
        difficulty: SentenceDifficulty.starter,
        sentencesPerWord: 1,
      );
      final hard = generator.estimate(
        profile: _openAiProfile(maxTokens: 8192),
        entries: entries,
        difficulty: SentenceDifficulty.mastery,
        sentencesPerWord: 1,
      );
      // 每批句子数一致，只有单句输出估算随难度上升
      expect(hard.requestCount, easy.requestCount);
      expect(hard.completionTokens, greaterThan(easy.completionTokens));
    });

    test('单词越多请求次数越多', () {
      final profile = _openAiProfile(maxTokens: 8192);
      final few = generator.estimate(
        profile: profile,
        entries: _entries(5),
        difficulty: SentenceDifficulty.starter,
        sentencesPerWord: 1,
      );
      final many = generator.estimate(
        profile: profile,
        entries: _entries(120),
        difficulty: SentenceDifficulty.starter,
        sentencesPerWord: 1,
      );
      expect(few.requestCount, 1);
      expect(many.requestCount, 10);
    });
  });

  group('AiSentenceGenerator 缓存命中预估（DeepSeek）', () {
    final generator = AiSentenceGenerator(
      profileService: _FakeProfileService(null),
    );

    // DeepSeek 官方定价风格：缓存命中单价远低于未命中
    const pricing = AiUsagePricing(
      unit: AiPriceUnit.perMillion,
      cacheHitPrice: 0.5,
      cacheMissPrice: 4,
      outputPrice: 12,
    );

    test('多批请求时第 2 批起共享的系统提示词前缀计入缓存命中', () {
      final estimate = generator.estimate(
        profile: _deepSeekProfile(maxTokens: 8192, pricing: pricing),
        entries: _entries(25),
        difficulty: SentenceDifficulty.starter,
        sentencesPerWord: 1,
      );

      expect(estimate.requestCount, 3);
      expect(estimate.cacheDiscountApplied, isTrue);
      expect(estimate.cacheHitTokens, greaterThan(0));
      // 最小缓存单元为 64 tokens，估算值应为其整数倍
      expect(
        estimate.cacheHitTokens % AiSentenceGenerator.deepSeekCacheBlockSize,
        0,
      );
      expect(
        estimate.cacheMissTokens,
        estimate.promptTokens - estimate.cacheHitTokens,
      );
      // 命中缓存必然比全部按未命中计费更便宜
      final withoutCache = AiUsageService.computeCost(
        pricing,
        cacheHitTokens: 0,
        cacheMissTokens: estimate.promptTokens,
        completionTokens: estimate.completionTokens,
      );
      expect(estimate.cost, lessThan(withoutCache!));
    });

    test('缓存命中量随请求批数线性增长', () {
      final two = generator.estimate(
        profile: _deepSeekProfile(maxTokens: 8192, pricing: pricing),
        entries: _entries(20), // 2 批
        difficulty: SentenceDifficulty.starter,
        sentencesPerWord: 1,
      );
      final three = generator.estimate(
        profile: _deepSeekProfile(maxTokens: 8192, pricing: pricing),
        entries: _entries(30), // 3 批
        difficulty: SentenceDifficulty.starter,
        sentencesPerWord: 1,
      );
      expect(two.requestCount, 2);
      expect(three.requestCount, 3);
      // 命中量 = 单个前缀 × (批数 - 1)
      expect(three.cacheHitTokens - two.cacheHitTokens, two.cacheHitTokens);
    });

    test('未配置缓存命中单价时不折减，避免低估费用', () {
      final estimate = generator.estimate(
        profile: _deepSeekProfile(
          maxTokens: 8192,
          pricing: const AiUsagePricing(
            unit: AiPriceUnit.perMillion,
            cacheMissPrice: 4,
            outputPrice: 12,
          ),
        ),
        entries: _entries(25),
        difficulty: SentenceDifficulty.starter,
        sentencesPerWord: 1,
      );
      expect(estimate.cacheHitTokens, 0);
      expect(estimate.cacheDiscountApplied, isFalse);
    });

    test('只有一批请求时没有可复用的前缀，不会产生缓存命中', () {
      final estimate = generator.estimate(
        profile: _deepSeekProfile(maxTokens: 8192, pricing: pricing),
        entries: _entries(3),
        difficulty: SentenceDifficulty.starter,
        sentencesPerWord: 1,
      );
      expect(estimate.requestCount, 1);
      expect(estimate.cacheHitTokens, 0);
    });

    test('非 DeepSeek 配置不做缓存折减', () {
      final estimate = generator.estimate(
        profile: _openAiProfile(maxTokens: 8192, pricing: pricing),
        entries: _entries(25),
        difficulty: SentenceDifficulty.starter,
        sentencesPerWord: 1,
      );
      expect(estimate.cacheHitTokens, 0);
    });
  });

  group('StreamingSentenceParser', () {
    test('逐字到达时按句切出完整对象，无需等整批结束', () {
      const full =
          '{"sentences":['
          '{"word":"apple","english":"I eat an apple.","chinese":"我吃苹果。",'
          '"extra_words":["pear"]},'
          '{"word":"banana","english":"She likes bananas.","chinese":"她喜欢香蕉。",'
          '"extra_words":[]}'
          ']}';
      final parser = StreamingSentenceParser();
      final collected = <GeneratedSentence>[];

      for (var i = 0; i < full.length; i += 7) {
        final end = i + 7 < full.length ? i + 7 : full.length;
        parser.addChunk(full.substring(i, end));
        collected.addAll(parser.takeNewSentences());
      }

      expect(collected.map((s) => s.english), [
        'I eat an apple.',
        'She likes bananas.',
      ]);
      expect(collected.first.sourceWord, 'apple');
      expect(collected.first.extraWords, ['pear']);
    });

    test('字符串里的花括号不会被当成对象边界', () {
      final parser = StreamingSentenceParser()
        ..addChunk(
          '{"sentences":[{"english":"Use {curly} braces.","chinese":"用花括号。",'
          '"extra_words":[]}]}',
        );
      expect(parser.takeNewSentences().single.english, 'Use {curly} braces.');
    });

    test('转义引号不会破坏字符串状态', () {
      final parser = StreamingSentenceParser()
        ..addChunk(
          r'{"sentences":[{"english":"He said \"hi\".","chinese":"他说你好。",'
          r'"extra_words":[]}]}',
        );
      expect(parser.takeNewSentences().single.english, 'He said "hi".');
    });

    test('回复被截断时已闭合的句子仍会给出', () {
      final parser = StreamingSentenceParser()
        ..addChunk(
          '{"sentences":[{"english":"Complete one.","chinese":"完整的一句。"},'
          '{"english":"Incomp',
        );
      expect(parser.takeNewSentences().map((s) => s.english), ['Complete one.']);
    });

    test('takeNewSentences 只返回增量，不重复吐出同一句', () {
      final parser = StreamingSentenceParser()
        ..addChunk('{"sentences":[{"english":"First.","chinese":"第一。"}]}');
      expect(parser.takeNewSentences().length, 1);
      expect(parser.takeNewSentences(), isEmpty);
    });

    test('缺少中文的片段不会被当作句子', () {
      final parser = StreamingSentenceParser()
        ..addChunk('{"sentences":[{"english":"No chinese."}]}');
      expect(parser.takeNewSentences(), isEmpty);
    });
  });

  group('AiSentenceGenerator 提示词', () {
    test('系统提示词写入 CEFR 等级、每词句数与 JSON 格式', () {
      final prompt = AiSentenceGenerator.buildSystemPrompt(
        SentenceDifficulty.upperIntermediate,
        2,
      );
      expect(prompt, contains('B2'));
      expect(prompt, contains('中级'));
      expect(prompt, contains('各生成 2 个英文句子'));
      expect(prompt, contains('"sentences"'));
      expect(prompt, contains('extra_words'));
    });

    test('用户提示词逐行列出单词与释义', () {
      final prompt = AiSentenceGenerator.buildUserPrompt([
        const WordPromptEntry(word: 'abandon', gloss: '放弃'),
        const WordPromptEntry(word: 'ability'),
      ], 1);
      expect(prompt, contains('1. abandon —— 放弃'));
      expect(prompt, contains('2. ability'));
    });
  });

  group('AiSentenceGenerator.parseGeneratedSentences', () {
    test('解析标准 JSON 对象', () {
      final parsed = AiSentenceGenerator.parseGeneratedSentences(
        '{"sentences":[{"word":"apple","english":"I eat an apple.",'
        '"chinese":"我吃一个苹果。","extra_words":["banana","cherry"]}]}',
      );
      expect(parsed.length, 1);
      expect(parsed.first.sourceWord, 'apple');
      expect(parsed.first.english, 'I eat an apple.');
      expect(parsed.first.chinese, '我吃一个苹果。');
      expect(parsed.first.extraWords, ['banana', 'cherry']);
    });

    test('解析 Markdown 代码块包裹的 JSON', () {
      final parsed = AiSentenceGenerator.parseGeneratedSentences('''
好的，以下是结果：
```json
{"sentences":[{"english":"He runs fast.","chinese":"他跑得快。","extra_words":[]}]}
```
''');
      expect(parsed.length, 1);
      expect(parsed.first.english, 'He runs fast.');
    });

    test('兼容直接返回数组的形式', () {
      final parsed = AiSentenceGenerator.parseGeneratedSentences(
        '[{"english":"A cat sleeps.","chinese":"猫在睡觉。","extra_words":["dog"]}]',
      );
      expect(parsed.length, 1);
      expect(parsed.first.extraWords, ['dog']);
    });

    test('过滤出现在句子中的干扰词并去重、去大小写差异', () {
      final parsed = AiSentenceGenerator.parseGeneratedSentences(
        jsonEncode({
          'sentences': [
            {
              'english': 'I want to buy an apple.',
              'chinese': '我想买个苹果。',
              'extra_words': [
                'want',
                'banana',
                'banana',
                'APPLE',
                'cherry',
                'date',
                'elder',
                'fig',
              ],
            },
          ],
        }),
      );
      expect(parsed.single.extraWords, ['banana', 'cherry', 'date', 'elder', 'fig']);
    });

    test('缺少中文或英文的条目被丢弃', () {
      final parsed = AiSentenceGenerator.parseGeneratedSentences(
        '{"sentences":[{"english":"Only english."},{"chinese":"只有中文。"},'
        '{"english":"Ok.","chinese":"好的。"}]}',
      );
      expect(parsed.length, 1);
      expect(parsed.single.english, 'Ok.');
    });

    test('回复被截断时仍能救回完整对象', () {
      final parsed = AiSentenceGenerator.parseGeneratedSentences(
        '{"sentences":[{"english":"First one.","chinese":"第一句。"},'
        '{"english":"Second one.","chinese":"第二句。"},{"english":"Thi',
      );
      expect(parsed.map((s) => s.english), ['First one.', 'Second one.']);
    });

    test('无法解析时返回空列表', () {
      expect(AiSentenceGenerator.parseGeneratedSentences('抱歉，我无法完成。'), isEmpty);
      expect(AiSentenceGenerator.parseGeneratedSentences(''), isEmpty);
    });

    test('shortGloss 取首行、压缩空白并截断', () {
      expect(AiSentenceGenerator.shortGloss('n. 能力, 才能\nvt. 使能够'), 'n. 能力, 才能');
      expect(AiSentenceGenerator.shortGloss(null), '');
      expect(
        AiSentenceGenerator.shortGloss('a' * 60, maxChars: 10),
        '${'a' * 10}…',
      );
    });
  });
}
