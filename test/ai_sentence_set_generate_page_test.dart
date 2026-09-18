import 'dart:async';

import 'package:aquamarina/models/ai_profile.dart';
import 'package:aquamarina/models/sentence_difficulty.dart';
import 'package:aquamarina/pages/vocabulary/ai_sentence_set_generate_page.dart';
import 'package:aquamarina/services/ai_profile_service.dart';
import 'package:aquamarina/services/ai_sentence_generate_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 可注入的假配置服务，避免单测触碰安全存储与真实配置
class _FakeProfileService extends AiProfileService {
  final AiProfile? profile;

  _FakeProfileService(this.profile);

  @override
  Future<void> load() async {}

  @override
  AiProfile? get defaultProfile => profile;
}

/// 只替换词典查询（单测里没有词典资源），规模推导 / 预估 / 提示词全部走真实实现
class _FakeGenerator extends AiSentenceGenerator {
  _FakeGenerator({super.profileService});

  @override
  Future<List<WordPromptEntry>> loadWordEntries(List<String> words) async =>
      words.map((w) => WordPromptEntry(word: w, gloss: '释义')).toList();
}

/// 用受控的 Completer 模拟「AI 正在流式返回」，便于断言生成中的实时反馈
class _StreamingFakeGenerator extends _FakeGenerator {
  _StreamingFakeGenerator({super.profileService});

  final Completer<void> gate = Completer<void>();
  final List<GeneratedSentence> streamed = [];

  @override
  Future<SentenceGenerationResult> generate({
    required AiProfile profile,
    required List<WordPromptEntry> entries,
    required SentenceDifficulty difficulty,
    required int sentencesPerWord,
    bool stream = true,
    CancelToken? cancelToken,
    void Function(int completed, int total)? onProgress,
    void Function(GeneratedSentence sentence)? onSentence,
  }) async {
    onProgress?.call(0, 2);
    const samples = [
      GeneratedSentence(
        sourceWord: 'apple',
        english: 'I eat an apple every morning.',
        chinese: '我每天早上吃一个苹果。',
      ),
      GeneratedSentence(
        sourceWord: 'banana',
        english: 'She likes bananas with yogurt.',
        chinese: '她喜欢香蕉配酸奶。',
      ),
    ];
    for (final s in samples) {
      streamed.add(s);
      onSentence?.call(s);
    }
    onProgress?.call(1, 2);
    await gate.future;
    throw const AiSentenceGenerateException('测试主动结束');
  }
}

AiProfile _aquamarinaProfile() => const AiProfile(
  id: 'aq',
  name: 'Aquamarina 官方',
  type: AiProfileType.aquamarina,
  apiKey: 'aquamarinapublicapi',
  model: 'default',
  maxTokens: 4096,
);

AiProfile _openAiProfile() => const AiProfile(
  id: 'p1',
  name: '我的 OpenAI',
  type: AiProfileType.openai,
  apiKey: 'sk-test',
  model: 'gpt-4o-mini',
  maxTokens: 4096,
  pricing: AiUsagePricing(
    unit: AiPriceUnit.perMillion,
    cacheMissPrice: 2,
    outputPrice: 8,
  ),
);

Widget _wrap(AiProfile profile, {List<String> words = const ['apple', 'banana']}) {
  final service = _FakeProfileService(profile);
  return MaterialApp(
    home: AiSentenceSetGeneratePage(
      bookTitle: '测试词书',
      words: words,
      profileService: service,
      generator: _FakeGenerator(profileService: service),
    ),
  );
}

/// 页面用 ListView 承载全部内容，默认 800×600 视口会因懒加载看不到下半部分；
/// 这里放大视口，让断言不必依赖滚动位置。
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('Aquamarina 官方配置下禁用本功能并给出设置指引', (tester) async {
    _useTallViewport(tester);
    await tester.pumpWidget(_wrap(_aquamarinaProfile()));
    await tester.pumpAndSettle();

    expect(find.text('当前无法使用本功能'), findsOneWidget);
    expect(find.textContaining('Aquamarina 官方'), findsOneWidget);
    expect(find.text('前往 AI 配置'), findsOneWidget);
    // 不可用时不应出现生成入口
    expect(find.text('开始生成'), findsNothing);
  });

  testWidgets('六档难度对应 CEFR 等级，可切换并同步默认句式集名称', (tester) async {
    _useTallViewport(tester);
    await tester.pumpWidget(_wrap(_openAiProfile()));
    await tester.pumpAndSettle();

    expect(find.byType(ChoiceChip), findsNWidgets(6));
    for (final label in const [
      '入门（A1）',
      '基础（A2）',
      '进阶（B1）',
      '中级（B2）',
      '高级（C1）',
      '自由运用（C2）',
    ]) {
      expect(find.text(label), findsOneWidget);
    }

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '测试词书 · 入门句式',
    );

    await tester.tap(find.text('高级（C1）'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '测试词书 · 高级句式',
    );
    // 难度直接写入预估明细
    expect(find.textContaining('CEFR C1'), findsOneWidget);
  });

  testWidgets('展示 token 与费用预估，且开始生成前必须二次确认', (tester) async {
    _useTallViewport(tester);
    await tester.pumpWidget(_wrap(_openAiProfile()));
    await tester.pumpAndSettle();

    expect(find.text('消耗预估'), findsOneWidget);
    expect(find.text('预估费用'), findsOneWidget);
    expect(find.text('合计 tokens'), findsOneWidget);
    expect(find.text('请求次数'), findsOneWidget);
    // 2 个单词 × 1 句
    expect(find.textContaining('2 词 × 1 句 = 2 句'), findsOneWidget);
    expect(find.textContaining('已选 2 个单词'), findsOneWidget);

    // 点击开始生成 → 先弹出确认弹窗，而不是直接请求
    await tester.tap(find.text('开始生成'));
    await tester.pumpAndSettle();

    expect(find.text('确认开始生成'), findsOneWidget);
    expect(find.textContaining('预计生成 2 句'), findsOneWidget);
    expect(find.text('确认生成'), findsOneWidget);

    // 取消后回到表单，未发起生成
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('确认开始生成'), findsNothing);
    expect(find.text('开始生成'), findsOneWidget);
  });

  testWidgets('未配置价格时提示无法预估费用，但仍可继续确认', (tester) async {
    _useTallViewport(tester);
    final service = _FakeProfileService(
      const AiProfile(
        id: 'p2',
        name: '无价格配置',
        type: AiProfileType.openai,
        apiKey: 'sk-test',
        model: 'gpt-4o-mini',
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: AiSentenceSetGeneratePage(
          bookTitle: '测试词书',
          words: const ['apple'],
          profileService: service,
          generator: _FakeGenerator(profileService: service),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('无法预估（未配置价格）'), findsOneWidget);
    expect(find.textContaining('未填写完整的计费价格'), findsOneWidget);
  });

  testWidgets('超过单次单词上限时禁用生成并给出提示', (tester) async {
    _useTallViewport(tester);
    final manyWords = List.generate(
      AiSentenceGenerator.maxWordsPerGeneration + 1,
      (i) => 'word$i',
    );
    await tester.pumpWidget(_wrap(_openAiProfile(), words: manyWords));
    await tester.pumpAndSettle();

    expect(find.textContaining('单次最多生成'), findsWidgets);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '开始生成'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('确认后进入生成态，实时显示 AI 流式输出的最近几句', (tester) async {
    _useTallViewport(tester);
    final service = _FakeProfileService(_openAiProfile());
    final generator = _StreamingFakeGenerator(profileService: service);
    await tester.pumpWidget(
      MaterialApp(
        home: AiSentenceSetGeneratePage(
          bookTitle: '测试词书',
          words: const ['apple', 'banana'],
          profileService: service,
          generator: generator,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('开始生成'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认生成'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 生成中的实时反馈：进度 + 已生成句数 + 最近几句英文
    expect(find.text('AI 正在生成…'), findsOneWidget);
    expect(find.text('已完成 1 / 2 批'), findsOneWidget);
    expect(find.text('已生成 2 句'), findsOneWidget);
    expect(find.text('I eat an apple every morning.'), findsOneWidget);
    expect(find.text('She likes bananas with yogurt.'), findsOneWidget);
    // 生成中不允许再次点击
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '生成中…'))
          .onPressed,
      isNull,
    );

    // 放行并收尾，避免测试结束时仍有未完成的 Future
    generator.gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('生成失败'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
  });
}
