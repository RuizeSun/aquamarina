import 'package:flutter_test/flutter_test.dart';
import 'package:aquamarina/main.dart';

void main() {
  testWidgets('App should build', (WidgetTester tester) async {
    await tester.pumpWidget(const AquamarinaApp());
    expect(find.text('搜索'), findsOneWidget);
    expect(find.text('背单词'), findsOneWidget);
    expect(find.text('句型练习'), findsOneWidget);
    // 底部导航第 4 个 tab 为「个人」
    expect(find.text('个人'), findsWidgets);
  });
}
