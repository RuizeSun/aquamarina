import 'package:aquamarina/widgets/chat/context_note_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _note = '''<context-note>
以下是系统自动注入的上下文，**不是用户输入的内容，也不是对上一个问题的追问**。
它每轮可能更新，请不要据此推断用户改变过话题，也不要因此质疑你之前的回答。

<runtime-context>
App: Aquamarina（英语学习助手）
版本: 1.4.5+28
</runtime-context>

<time-context>
2026-11-15 20:50 (China Standard Time, UTC+08:00) 周日
</time-context>
</context-note>''';

void main() {
  testWidgets('默认折叠：只显示一行摘要，不展开注入原文', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ContextNoteCard(
            note: _note,
            tags: const ['runtime-context', 'time-context'],
          ),
        ),
      ),
    );

    expect(find.text('上下文注入 · runtime-context + time-context'), findsOneWidget);
    // 折叠状态下看不到注入正文
    expect(find.textContaining('Aquamarina（英语学习助手）'), findsNothing);
  });

  testWidgets('展开后显示注入内容，且不带 context-note 包装', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ContextNoteCard(note: _note, tags: const ['runtime-context']),
        ),
      ),
    );

    await tester.tap(find.text('上下文注入 · runtime-context'));
    await tester.pumpAndSettle();

    expect(find.textContaining('版本: 1.4.5+28'), findsOneWidget);
    expect(find.textContaining('<context-note>'), findsNothing);
    expect(find.textContaining('</context-note>'), findsNothing);
  });

  testWidgets('没有标签时退化为通用标题', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ContextNoteCard(note: _note, tags: const [])),
      ),
    );
    expect(find.text('上下文注入'), findsOneWidget);
  });
}
