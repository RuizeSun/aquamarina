import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';

import '../data/database_service.dart';
import '../system/log_service.dart';

/// 运行期上下文的分块构造器。
///
/// 思路参照 DeepSeek Harness：把**变动极少、但模型几乎总会需要**的事实
/// （App 版本、数据库 schema、当前时间等）在每一轮请求前直接注入到系统提示词，
/// 而不是让模型先发一次工具调用再拿到。工具保留，但只用于「需要重新确认」的场景。
class AiContextBuilder {
  AiContextBuilder({
    Future<PackageInfo> Function()? packageInfoLoader,
    int Function()? schemaVersionLoader,
    DateTime Function()? clock,
  }) : _loadPackageInfo = packageInfoLoader ?? (() => PackageInfo.fromPlatform()),
       _loadSchemaVersion = schemaVersionLoader ?? (() => DatabaseService.schemaVersion),
       _now = clock ?? DateTime.now;

  final Future<PackageInfo> Function() _loadPackageInfo;
  final int Function() _loadSchemaVersion;
  final DateTime Function() _now;

  /// 上下文中显示的时间格式：2026-11-15 20:50 (Asia/Shanghai)。
  static String formatTime(DateTime time) {
    String two(int v) => v.toString().padLeft(2, '0');
    final offset = time.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final hours = offset.inHours.abs().toString().padLeft(2, '0');
    final minutes = (offset.inMinutes.abs() % 60).toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)} '
        '(${time.timeZoneName}, UTC$sign$hours:$minutes)';
  }

  /// 星期几（中文），便于回答「今天」「这周」类问题。
  static String weekdayOf(DateTime time) {
    const names = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return names[time.weekday - 1];
  }

  /// 时间上下文。
  String buildTimeContext({DateTime? now}) {
    final time = now ?? _now();
    return '${formatTime(time)} ${weekdayOf(time)}';
  }

  /// 运行环境上下文：App 版本、schema、平台。
  Future<String> buildRuntimeContext() async {
    var version = '未知';
    var build = '';
    try {
      final info = await _loadPackageInfo();
      version = info.version;
      build = info.buildNumber;
    } catch (e) {
      logWarning('AiContextBuilder', '读取版本信息失败: $e');
    }
    var schema = 0;
    try {
      schema = _loadSchemaVersion();
    } catch (_) {
      // 忽略：测试或平台不支持
    }

    final lines = <String>[
      'App: Aquamarina（英语学习助手）',
      '版本: $version${build.isEmpty ? '' : '+$build'}',
      if (schema > 0) '数据库 schema: v$schema',
      '平台: ${Platform.operatingSystem}',
    ];
    return lines.join('\n');
  }

  /// 组装完整的注入文本（各块之间空行分隔，便于模型分段阅读）。
  Future<String> build({
    bool includeRuntime = true,
    bool includeTime = true,
    DateTime? now,
  }) async {
    final blocks = <String>[];
    if (includeRuntime) {
      final runtime = await buildRuntimeContext();
      if (runtime.trim().isNotEmpty) {
        blocks.add(_wrap('runtime-context', runtime));
      }
    }
    if (includeTime) {
      blocks.add(_wrap('time-context', buildTimeContext(now: now)));
    }
    // 注意：两个开关都关时不返回空标签串，交给调用方判断是否注入
    return blocks.join('\n\n');
  }

  static String _wrap(String tag, String body) =>
      '<$tag>\n${body.trim()}\n</$tag>';
}
