import 'package:aquamarina/services/ai/ai_context_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

AiContextBuilder _builder({
  String version = '1.4.5',
  String build = '28',
  int schema = 21,
  DateTime? now,
}) {
  final fixed = now ?? DateTime(2026, 11, 15, 20, 50);
  return AiContextBuilder(
    packageInfoLoader: () async => PackageInfo(
      appName: 'Aquamarina',
      packageName: 'app.aquamarina',
      version: version,
      buildNumber: build,
    ),
    schemaVersionLoader: () => schema,
    clock: () => fixed,
  );
}

void main() {
  group('时间上下文', () {
    test('格式包含年月日时分、时区与星期', () {
      final builder = _builder(now: DateTime(2026, 11, 15, 20, 50));
      final text = builder.buildTimeContext();
      expect(text, contains('2026-11-15'));
      expect(text, contains('20:50'));
      expect(text, contains('周日'));
      expect(text, contains('UTC'));
    });

    test('分钟与小时补零', () {
      final text = _builder(now: DateTime(2026, 1, 5, 9, 7)).buildTimeContext();
      expect(text, contains('2026-01-05'));
      expect(text, contains('09:07'));
      expect(text, contains('周一'));
    });

    test('weekdayOf 覆盖一周七天', () {
      expect(AiContextBuilder.weekdayOf(DateTime(2026, 11, 16)), '周一');
      expect(AiContextBuilder.weekdayOf(DateTime(2026, 11, 22)), '周日');
    });
  });

  group('运行环境上下文', () {
    test('包含版本、schema 与平台', () async {
      final text = await _builder().buildRuntimeContext();
      expect(text, contains('1.4.5+28'));
      expect(text, contains('v21'));
      expect(text, contains('平台'));
    });

    test('缺少 build 号时只显示版本', () async {
      final text = await _builder(build: '').buildRuntimeContext();
      expect(text, contains('版本: 1.4.5'));
      expect(text, isNot(contains('1.4.5+')));
    });

    test('版本读取失败降级为未知，不抛异常', () async {
      final builder = AiContextBuilder(
        packageInfoLoader: () async => throw StateError('boom'),
        schemaVersionLoader: () => 21,
        clock: DateTime.now,
      );
      final text = await builder.buildRuntimeContext();
      expect(text, contains('未知'));
      expect(text, contains('v21'));
    });
  });

  group('组合', () {
    test('默认同时注入 runtime 与 time，并带标签', () async {
      final text = await _builder().build();
      expect(text, contains('<runtime-context>'));
      expect(text, contains('</runtime-context>'));
      expect(text, contains('<time-context>'));
      expect(text, contains('</time-context>'));
    });

    test('可单独关闭运行环境注入', () async {
      final text = await _builder().build(includeRuntime: false);
      expect(text, isNot(contains('<runtime-context>')));
      expect(text, contains('<time-context>'));
    });

    test('可单独关闭时间注入', () async {
      final text = await _builder().build(includeTime: false);
      expect(text, contains('<runtime-context>'));
      // 注意：'runtime-context' 本身含有子串 'time-context'，必须比对完整标签
      expect(text, isNot(contains('<time-context>')));
    });

    test('全部关闭时返回空串', () async {
      final text = await _builder().build(
        includeRuntime: false,
        includeTime: false,
      );
      expect(text.trim(), isEmpty);
    });

    test('每轮取当前时间，不会用缓存值', () async {
      var now = DateTime(2026, 11, 15, 20, 50);
      final builder = AiContextBuilder(
        packageInfoLoader: () async => PackageInfo(
          appName: 'a',
          packageName: 'a',
          version: '1.0.0',
          buildNumber: '1',
        ),
        schemaVersionLoader: () => 21,
        clock: () => now,
      );
      final first = await builder.build(includeRuntime: false);
      now = DateTime(2026, 11, 15, 21, 30);
      final second = await builder.build(includeRuntime: false);
      expect(first, contains('20:50'));
      expect(second, contains('21:30'));
      expect(second, isNot(contains('20:50')));
    });
  });
}
