import 'package:flutter/material.dart';
import 'package:aquamarina/pages/vocabulary/shared/word_book_word_list.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// 把词表列表放进最小可用的滚动页面中，结构与编辑词书页一致：
  /// Scaffold → 透明 Material（墨迹层）→ CustomScrollView。
  Future<void> pumpWordList(
    WidgetTester tester,
    List<String> words, {
    ValueChanged<String>? onTapWord,
    ValueChanged<String>? onRemoveWord,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Material(
            type: MaterialType.transparency,
            child: CustomScrollView(
              slivers: [
                WordBookWordList(
                  words: words,
                  onTapWord: onTapWord ?? (_) {},
                  onRemoveWord: onRemoveWord ?? (_) {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('词表懒加载：上千词也只构建可视区域附近的行', (tester) async {
    final words = List.generate(2000, (i) => 'word$i');
    await pumpWordList(tester, words);

    // 首屏的行被正常构建
    expect(find.text('word0'), findsOneWidget);
    // 末尾的词尚未构建，说明没有一次性构建整张词表
    expect(find.text('word1999'), findsNothing);
    // 已构建的行数远小于总词数（默认视口下约 20 行）
    expect(tester.widgetList(find.byType(InkWell)).length, lessThan(60));
  });

  testWidgets('滚动后可以构建并显示后面的单词', (tester) async {
    final words = List.generate(200, (i) => 'word$i');
    await pumpWordList(tester, words);

    await tester.scrollUntilVisible(find.text('word199'), 1000);
    expect(find.text('word199'), findsOneWidget);
  });

  testWidgets('点击行与点击移除按钮分别触发对应回调', (tester) async {
    final tapped = <String>[];
    final removed = <String>[];
    await pumpWordList(
      tester,
      ['apple', 'banana'],
      onTapWord: tapped.add,
      onRemoveWord: removed.add,
    );

    await tester.tap(find.text('apple'));
    await tester.pump();
    expect(tapped, ['apple']);

    await tester.tap(find.byIcon(Icons.remove_circle_outline).first);
    await tester.pump();
    expect(removed, ['apple']);
  });
}
