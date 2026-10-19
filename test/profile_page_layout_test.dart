import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aquamarina/pages/profile_page.dart';

/// 个人页宽屏下应采用「左学习进度 / 右功能入口」双栏布局，
/// 窄屏下保持单栏，避免卡片与列表项被无限拉伸。
void main() {
  Future<void> pumpProfile(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: ProfilePage()));
    await tester.pump();
  }

  testWidgets('宽屏下内容宽度受限并水平居中', (tester) async {
    await pumpProfile(tester, const Size(1250, 900));

    final header = find.byKey(const ValueKey('profile-header'));
    expect(header, findsOneWidget);

    final rect = tester.getRect(header);
    expect(rect.width, 1120);
    expect(rect.left, (1250 - 1120) / 2);
  });

  testWidgets('宽屏下学习进度在左、功能入口在右', (tester) async {
    await pumpProfile(tester, const Size(1250, 900));

    final progress = tester.getRect(
      find.byKey(const ValueKey('profile-progress-column')),
    );
    final options = tester.getRect(
      find.byKey(const ValueKey('profile-options-column')),
    );

    expect(progress.right, lessThan(options.left));
    expect(progress.top, options.top);
    // 两栏位于内容区左右内边距之内
    expect(progress.left, (1250 - 1120) / 2 + 16);
    expect(options.right, 1250 - (1250 - 1120) / 2 - 16);
  });

  testWidgets('窄屏下内容保持铺满且不使用双栏', (tester) async {
    await pumpProfile(tester, const Size(400, 900));

    final rect = tester.getRect(find.byKey(const ValueKey('profile-header')));
    expect(rect.width, 400);
    expect(rect.left, 0);
    expect(find.byKey(const ValueKey('profile-progress-column')), findsNothing);
    expect(find.byKey(const ValueKey('profile-options-column')), findsNothing);
  });

  testWidgets('宽屏断点边界（900px）切换双栏且不溢出', (tester) async {
    await pumpProfile(tester, const Size(900, 900));

    expect(
      find.byKey(const ValueKey('profile-progress-column')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('profile-options-column')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
