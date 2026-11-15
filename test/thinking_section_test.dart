import 'package:aquamarina/widgets/chat/thinking_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('折叠时只显示摘要，不显示思维链正文', (tester) async {
    await tester.pumpWidget(
      _host(const ThinkingSection(reasoning: '先查词典再总结', summary: '查词典 · 已执行')),
    );

    expect(find.text('思考过程 · 查词典 · 已执行'), findsOneWidget);
    expect(find.textContaining('先查词典再总结'), findsNothing);
  });

  testWidgets('点击标题展开后显示思维链', (tester) async {
    await tester.pumpWidget(
      _host(const ThinkingSection(reasoning: '先查词典再总结', summary: '查词典')),
    );

    await tester.tap(find.text('思考过程 · 查词典'));
    await tester.pumpAndSettle();

    expect(find.textContaining('先查词典再总结'), findsOneWidget);
  });

  testWidgets('没有内容时完全不占位', (tester) async {
    await tester.pumpWidget(_host(const ThinkingSection()));
    expect(find.byType(InkWell), findsNothing);
    expect(find.textContaining('思考过程'), findsNothing);
  });

  testWidgets('状态文案显示在折叠行右侧', (tester) async {
    await tester.pumpWidget(
      _host(
        const ThinkingSection(
          reasoning: '想想',
          summary: '查词典',
          statusText: '等待你批准',
        ),
      ),
    );
    expect(find.text('等待你批准'), findsOneWidget);
  });
}
