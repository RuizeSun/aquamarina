import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aquamarina/pages/shared/dashboard_widgets.dart';

/// DashboardProgressCard 的进度填充条必须真的可见。
///
/// 回归背景：填充条只给了 widthFactor 时，外层宽松约束会让它的高度收敛为 0，
/// 表现为「进度条始终为空」（轨道可见、填充永远不可见）。
void main() {
  const double cardWidth = 320;
  // 卡片左右各 16 的 padding
  const double trackWidth = cardWidth - 16 * 2;

  Future<void> pumpCard(WidgetTester tester, double progress) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: cardWidth,
            child: DashboardProgressCard(
              icon: Icons.event_available,
              title: '今日打卡进度',
              valueText: '1 / 4',
              progress: progress,
            ),
          ),
        ),
      ),
    );
  }

  Size fillSize(WidgetTester tester) =>
      tester.getSize(find.byKey(DashboardProgressCard.fillKey));

  testWidgets('填充条有非零高度，且宽度与进度成比例', (tester) async {
    await pumpCard(tester, 0.25);
    final size = fillSize(tester);
    expect(size.height, 8);
    expect(size.width, closeTo(trackWidth * 0.25, 0.01));
  });

  testWidgets('进度为 0 时填充宽度为 0（轨道仍占满宽度）', (tester) async {
    await pumpCard(tester, 0);
    expect(fillSize(tester).width, 0);
    expect(fillSize(tester).height, 8);
  });

  testWidgets('进度为 1 时填充铺满整条', (tester) async {
    await pumpCard(tester, 1);
    expect(fillSize(tester).width, closeTo(trackWidth, 0.01));
    expect(fillSize(tester).height, 8);
  });

  testWidgets('超出 0~1 的进度被裁剪', (tester) async {
    await pumpCard(tester, 1.5);
    expect(fillSize(tester).width, closeTo(trackWidth, 0.01));
  });
}
