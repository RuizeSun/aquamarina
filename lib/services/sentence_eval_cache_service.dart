import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../models/ai_sentence.dart';
import 'database_service.dart';
import 'log_service.dart';

/// 句型练习缓存概览（供设置页展示）
class SentenceEvalCacheStats {
  /// 缓存条数
  final int count;

  /// 占用空间估算（文本字节 + 每行固定开销）
  final int bytes;

  /// 累计命中次数
  final int hits;

  /// 最早 / 最新的缓存时间
  final DateTime? oldest;
  final DateTime? newest;

  const SentenceEvalCacheStats({
    required this.count,
    required this.bytes,
    required this.hits,
    this.oldest,
    this.newest,
  });

  static const SentenceEvalCacheStats empty = SentenceEvalCacheStats(
    count: 0,
    bytes: 0,
    hits: 0,
  );

  bool get isEmpty => count == 0;
}

/// 句型练习批改结果缓存服务（全局单例）
///
/// 命中规则：**相同句子（中文 + 英文）+ 相同用户回答 + 相同练习模式**。
/// 文本比较前会做归一化（去首尾空白、折叠连续空白），保留大小写，
/// 因为评分细则中大小写、标点均计入评分。
///
/// 缓存只保存批改结果，不保存 AI 请求上下文；缓存读写失败仅记日志，
/// 绝不阻断正常批改流程。
class SentenceEvalCacheService {
  SentenceEvalCacheService._(this._openDatabase);

  /// 全局单例：使用应用业务数据库
  static final SentenceEvalCacheService instance = SentenceEvalCacheService._(
    () => DatabaseService.database,
  );

  /// 测试专用：注入自定义数据库（例如 sqflite ffi 内存库）
  @visibleForTesting
  SentenceEvalCacheService.withDatabase(
    Future<Database> Function() openDatabase,
  ) : _openDatabase = openDatabase;

  /// 数据库访问入口（生产环境为业务数据库，测试可注入内存库）
  final Future<Database> Function() _openDatabase;

  static const String table = 'sentence_eval_cache';

  /// 缓存开关（SharedPreferences）
  static const String _prefsEnabledKey = 'sentence_eval_cache_enabled';

  /// 每行除文本内容外的固定开销估算（rowid / 整数列 / 页内指针等）
  static const int _rowOverheadBytes = 96;

  // ── 开关 ──────────────────────────────────────────

  /// 是否启用批改结果缓存（默认启用）
  Future<bool> isEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_prefsEnabledKey) ?? true;
    } catch (e, stackTrace) {
      logError('SentenceEvalCacheService', '读取缓存开关失败: $e', stackTrace);
      return true;
    }
  }

  Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsEnabledKey, value);
  }

  // ── 键归一化（纯函数，便于测试） ────────────────────

  /// 归一化文本：去除首尾空白，并把连续空白折叠为单个空格（保留大小写）
  static String normalize(String text) =>
      text.trim().replaceAll(RegExp(r'\s+'), ' ');

  /// 练习模式 → 数据库存储值
  static int modeValue(PracticeMode mode) =>
      mode == PracticeMode.beginner ? 0 : 1;

  /// 数据库存储值 → 练习模式
  static PracticeMode modeFromValue(int value) =>
      value == 0 ? PracticeMode.beginner : PracticeMode.advanced;

  // ── 读 ────────────────────────────────────────────

  /// 查询缓存结果；命中时刷新命中次数与最近命中时间。
  ///
  /// 未启用缓存、无命中或查询异常时返回 null（调用方继续走 AI 批改）。
  Future<AiSentenceResult?> lookup({
    required Sentence sentence,
    required String userAnswer,
    required PracticeMode mode,
  }) async {
    if (!await isEnabled()) return null;

    try {
      final db = await _openDatabase();
      final rows = await db.query(
        table,
        where:
            'mode = ? AND sentence_english = ? AND sentence_chinese = ? '
            'AND user_answer = ?',
        whereArgs: [
          modeValue(mode),
          normalize(sentence.english),
          normalize(sentence.chinese),
          normalize(userAnswer),
        ],
        limit: 1,
      );
      if (rows.isEmpty) return null;

      final row = rows.first;
      // 刷新命中统计（失败不影响本次命中）
      try {
        await db.rawUpdate(
          'UPDATE $table SET hit_count = hit_count + 1, last_hit_at = ? '
          'WHERE id = ?',
          [DateTime.now().toIso8601String(), row['id']],
        );
      } catch (e, stackTrace) {
        logError('SentenceEvalCacheService', '更新缓存命中统计失败: $e', stackTrace);
      }

      final result = AiSentenceResult(
        score: (row['score'] as num).toInt(),
        markup: row['markup'] as String? ?? '',
        comment: row['comment'] as String? ?? '',
      );
      logInfo(
        'SentenceEvalCacheService',
        '命中缓存 mode=${mode.name} score=${result.score}',
      );
      return result;
    } catch (e, stackTrace) {
      logError('SentenceEvalCacheService', '查询缓存失败: $e', stackTrace);
      return null;
    }
  }

  // ── 写 ────────────────────────────────────────────

  /// 写入一条缓存（相同键已存在时忽略，保留首次结果）
  Future<void> store({
    required Sentence sentence,
    required String userAnswer,
    required PracticeMode mode,
    required AiSentenceResult result,
    String? profileName,
    String? model,
  }) async {
    if (!await isEnabled()) return;

    try {
      final db = await _openDatabase();
      await db.insert(table, {
        'mode': modeValue(mode),
        'sentence_english': normalize(sentence.english),
        'sentence_chinese': normalize(sentence.chinese),
        'user_answer': normalize(userAnswer),
        'score': result.score,
        'markup': result.markup,
        'comment': result.comment,
        'profile_name': profileName,
        'model': model,
        'hit_count': 0,
        'created_at': DateTime.now().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    } catch (e, stackTrace) {
      logError('SentenceEvalCacheService', '写入缓存失败: $e', stackTrace);
    }
  }

  /// 删除某条缓存（用于「重新批改」时强制走一次 AI）
  Future<void> remove({
    required Sentence sentence,
    required String userAnswer,
    required PracticeMode mode,
  }) async {
    try {
      final db = await _openDatabase();
      await db.delete(
        table,
        where:
            'mode = ? AND sentence_english = ? AND sentence_chinese = ? '
            'AND user_answer = ?',
        whereArgs: [
          modeValue(mode),
          normalize(sentence.english),
          normalize(sentence.chinese),
          normalize(userAnswer),
        ],
      );
    } catch (e, stackTrace) {
      logError('SentenceEvalCacheService', '删除缓存失败: $e', stackTrace);
    }
  }

  // ── 管理 ──────────────────────────────────────────

  /// 缓存概览：条数、占用估算、累计命中、时间跨度
  Future<SentenceEvalCacheStats> fetchStats() async {
    try {
      final db = await _openDatabase();
      final rows = await db.rawQuery('''
        SELECT
          COUNT(*) AS cnt,
          COALESCE(SUM(hit_count), 0) AS hits,
          MIN(created_at) AS oldest,
          MAX(created_at) AS newest,
          COALESCE(SUM(
            LENGTH(CAST(sentence_english AS BLOB)) +
            LENGTH(CAST(sentence_chinese AS BLOB)) +
            LENGTH(CAST(user_answer AS BLOB)) +
            LENGTH(CAST(markup AS BLOB)) +
            LENGTH(CAST(comment AS BLOB))
          ), 0) AS text_bytes
        FROM $table
      ''');
      final row = rows.isNotEmpty ? rows.first : const <String, Object?>{};
      final count = (row['cnt'] as num?)?.toInt() ?? 0;
      final textBytes = (row['text_bytes'] as num?)?.toInt() ?? 0;
      return SentenceEvalCacheStats(
        count: count,
        bytes: textBytes + count * _rowOverheadBytes,
        hits: (row['hits'] as num?)?.toInt() ?? 0,
        oldest: _parseTime(row['oldest']),
        newest: _parseTime(row['newest']),
      );
    } catch (e, stackTrace) {
      logError('SentenceEvalCacheService', '查询缓存概览失败: $e', stackTrace);
      return SentenceEvalCacheStats.empty;
    }
  }

  /// 统计早于 [days] 天的缓存条数（删除前预览用）
  Future<int> countOlderThanDays(int days) async {
    try {
      final db = await _openDatabase();
      return Sqflite.firstIntValue(
            await db.rawQuery(
              'SELECT COUNT(*) FROM $table WHERE created_at < ?',
              [_cutoff(days)],
            ),
          ) ??
          0;
    } catch (e, stackTrace) {
      logError('SentenceEvalCacheService', '统计过期缓存条数失败: $e', stackTrace);
      return 0;
    }
  }

  /// 删除全部缓存，返回删除条数
  Future<int> deleteAll() async {
    try {
      final db = await _openDatabase();
      final deleted = await db.delete(table);
      logInfo('SentenceEvalCacheService', '已清空缓存，共 $deleted 条');
      return deleted;
    } catch (e, stackTrace) {
      logError('SentenceEvalCacheService', '清空缓存失败: $e', stackTrace);
      return 0;
    }
  }

  /// 删除早于 [days] 天的缓存，返回删除条数
  Future<int> deleteOlderThanDays(int days) async {
    try {
      final db = await _openDatabase();
      final deleted = await db.delete(
        table,
        where: 'created_at < ?',
        whereArgs: [_cutoff(days)],
      );
      logInfo('SentenceEvalCacheService', '已删除 $days 天前的缓存，共 $deleted 条');
      return deleted;
    } catch (e, stackTrace) {
      logError('SentenceEvalCacheService', '删除过期缓存失败: $e', stackTrace);
      return 0;
    }
  }

  // ── 工具 ──────────────────────────────────────────

  /// [days] 天前的时间点（ISO8601 字符串，与 created_at 存储格式一致）
  static String _cutoff(int days) =>
      DateTime.now().subtract(Duration(days: days)).toIso8601String();

  static DateTime? _parseTime(Object? value) {
    if (value is! String || value.isEmpty) return null;
    return DateTime.tryParse(value);
  }

  /// 格式化字节数，如 `0 B` / `1.2 KB` / `3.45 MB`
  static String formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    return '${mb.toStringAsFixed(2)} MB';
  }
}
