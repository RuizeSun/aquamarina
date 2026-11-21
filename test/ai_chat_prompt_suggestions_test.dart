import 'dart:math';

import 'package:aquamarina/services/ai/ai_chat_prompt_suggestions.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('内置建议不少于 150 条且互不重复', () {
    expect(AiChatPromptSuggestions.all.length, greaterThanOrEqualTo(150));
    expect(AiChatPromptSuggestions.all.toSet().length,
        AiChatPromptSuggestions.all.length);
    for (final prompt in AiChatPromptSuggestions.all) {
      expect(prompt.trim(), isNotEmpty);
    }
  });

  test('pick 返回指定数量且互不重复', () {
    final random = Random(20241121);
    final picked = AiChatPromptSuggestions.pick(count: 3, random: random);
    expect(picked.length, 3);
    expect(picked.toSet().length, 3);
    for (final prompt in picked) {
      expect(AiChatPromptSuggestions.all, contains(prompt));
    }
  });

  test('pick 在多次抽取间会轮换', () {
    final random = Random(1);
    final batches = {
      for (var i = 0; i < 20; i++)
        AiChatPromptSuggestions.pick(count: 3, random: random).join('|'),
    };
    expect(batches.length, greaterThan(1));
  });

  test('count 超过池大小时返回整个池', () {
    final picked = AiChatPromptSuggestions.pick(count: 1000);
    expect(picked.length, AiChatPromptSuggestions.all.length);
  });

  test('count 为 0 返回空列表', () {
    expect(AiChatPromptSuggestions.pick(count: 0), isEmpty);
  });
}
