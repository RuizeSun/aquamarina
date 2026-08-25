import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 日志等级
enum LogLevel {
  debug(0, 'DEBUG'),
  info(1, 'INFO'),
  warning(2, 'WARN'),
  error(3, 'ERROR');

  final int value;
  final String label;
  const LogLevel(this.value, this.label);
}

/// 单条日志记录
class LogEntry {
  final DateTime timestamp;
  final LogLevel level;
  final String tag;
  final String message;

  const LogEntry({
    required this.timestamp,
    required this.level,
    required this.tag,
    required this.message,
  });

  /// 格式化为一行可读文本
  String format() {
    final time =
        '${timestamp.year}-${_two(timestamp.month)}-${_two(timestamp.day)} '
        '${_two(timestamp.hour)}:${_two(timestamp.minute)}:${_two(timestamp.second)}'
        '.${timestamp.millisecond.toString().padLeft(3, '0')}';
    return '$time [${level.label}] $tag: $message';
  }

  static String _two(int v) => v.toString().padLeft(2, '0');
}

/// 日志服务（单例）
///
/// - 内存环形缓冲区存储最近的日志条目
/// - 最低日志等级持久化到 SharedPreferences
/// - 同时输出到 debugPrint 以便 IDE 控制台查看
/// - 支持导出日志文件
class LogService {
  LogService._();

  /// 全局单例
  static final LogService instance = LogService._();

  static const String _prefsLevelKey = 'log_min_level';
  static const int _maxEntries = 2000;

  /// 日志缓冲区（环形）
  final List<LogEntry> _buffer = [];

  /// 当前最低日志等级
  LogLevel _minLevel = LogLevel.debug;

  /// 通知监听者有新日志写入
  final ValueNotifier<int> logCount = ValueNotifier<int>(0);

  /// 当前最低日志等级的可监听值
  final ValueNotifier<LogLevel> minLevel = ValueNotifier<LogLevel>(
    LogLevel.debug,
  );

  /// 获取当前缓冲区中所有日志的副本（按时间正序）
  List<LogEntry> get entries => List.unmodifiable(_buffer);

  // ── 初始化 ──────────────────────────────────────────

  /// 从 SharedPreferences 加载最低日志等级
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final index = prefs.getInt(_prefsLevelKey);
    if (index != null && index >= 0 && index < LogLevel.values.length) {
      _minLevel = LogLevel.values[index];
      minLevel.value = _minLevel;
    }
    info('LogService', '日志服务初始化完成，最低等级: ${_minLevel.label}');
  }

  /// 设置最低日志等级并持久化
  Future<void> setMinLevel(LogLevel level) async {
    if (_minLevel == level) return;
    _minLevel = level;
    minLevel.value = level;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefsLevelKey, level.index);
    info('LogService', '日志等级已变更为: ${level.label}');
  }

  // ── 写入日志 ────────────────────────────────────────

  void debug(String tag, String message) => _log(LogLevel.debug, tag, message);

  void info(String tag, String message) => _log(LogLevel.info, tag, message);

  void warning(String tag, String message) =>
      _log(LogLevel.warning, tag, message);

  void error(String tag, String message, [StackTrace? stackTrace]) {
    _log(LogLevel.error, tag, message);
    if (stackTrace != null) {
      _log(LogLevel.error, tag, 'StackTrace: $stackTrace');
    }
  }

  void _log(LogLevel level, String tag, String message) {
    // 低于最低等级的日志直接丢弃
    if (level.value < _minLevel.value) return;

    final entry = LogEntry(
      timestamp: DateTime.now(),
      level: level,
      tag: tag,
      message: message,
    );

    // 环形缓冲区
    if (_buffer.length >= _maxEntries) {
      _buffer.removeAt(0);
    }
    _buffer.add(entry);

    // 通知监听者
    logCount.value = _buffer.length;

    // 同时输出到 debugPrint（IDE 控制台可见）
    debugPrint(entry.format());
  }

  // ── 清空 ────────────────────────────────────────────

  /// 清空日志缓冲区
  void clear() {
    _buffer.clear();
    logCount.value = 0;
    info('LogService', '日志已清空');
  }

  /// 生成日志文本内容
  String _buildLogContent() {
    final sb = StringBuffer();
    sb.writeln('=== Aquamarina 日志导出 ===');
    sb.writeln('导出时间: ${DateTime.now()}');
    sb.writeln('日志条数: ${_buffer.length}');
    sb.writeln('最低等级: ${_minLevel.label}');
    sb.writeln('============================\n');
    for (final entry in _buffer) {
      sb.writeln(entry.format());
    }
    return sb.toString();
  }

  /// 生成日志文件名，如 `aquamarina_log_20260825_1430.txt`
  String _buildLogFileName() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'aquamarina_log_${now.year}${two(now.month)}${two(now.day)}'
        '_${two(now.hour)}${two(now.minute)}.txt';
  }

  /// 将日志内容以文件形式导出。
  ///
  /// - 移动端：保存到临时目录后调用系统分享面板
  /// - 桌面端：弹出文件保存对话框让用户选择保存位置，直接写入
  ///
  /// 返回 `true` 表示导出成功。
  Future<bool> exportAndShare() async {
    if (_buffer.isEmpty) return false;

    final content = _buildLogContent();
    final fileName = _buildLogFileName();

    try {
      if (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS) {
        // 手机端：写入临时目录后系统分享
        final dir = await getTemporaryDirectory();
        final file = File('${dir.path}/$fileName');
        await file.writeAsString(content, flush: true);

        await SharePlus.instance.share(
          ShareParams(files: [XFile(file.path)], subject: 'Aquamarina 日志'),
        );
      } else {
        // 桌面端：先弹保存对话框，再直接写入目标位置
        final tmpDir = await getTemporaryDirectory();
        final suggestedPath = '${tmpDir.path}/$fileName';
        final saveLocation = await getSaveLocation(
          suggestedName: suggestedPath,
          acceptedTypeGroups: [
            const XTypeGroup(label: '文本文件', extensions: ['txt']),
          ],
        );
        if (saveLocation == null) return true; // 用户取消
        await File(saveLocation.path).writeAsString(content, flush: true);
      }
      return true;
    } catch (e) {
      debugPrint('LogService.exportAndShare error: $e');
      return true;
    }
  }
}

/// 顶层便捷方法，可在任意位置快速记录日志
void logDebug(String tag, String message) =>
    LogService.instance.debug(tag, message);

void logInfo(String tag, String message) =>
    LogService.instance.info(tag, message);

void logWarning(String tag, String message) =>
    LogService.instance.warning(tag, message);

void logError(String tag, String message, [StackTrace? stackTrace]) =>
    LogService.instance.error(tag, message, stackTrace);
