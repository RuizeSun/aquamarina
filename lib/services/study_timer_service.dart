import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import 'database_service.dart';
import 'log_service.dart';

/// 学习会话类型
enum SessionType {
  /// 单词学习（新词）
  wordLearn('word_learn'),

  /// 单词复习
  wordReview('word_review'),

  /// 句型练习
  sentencePractice('sentence_practice'),

  /// 错题本练习（句型错题）
  wrongSentencePractice('wrong_sentence_practice'),

  /// 词汇测试
  vocabTest('vocab_test'),

  /// 单词拼写练习/快速拼写复习
  wordSpelling('word_spelling');

  final String value;
  const SessionType(this.value);
}

/// 学习时长统计服务
///
/// 核心设计：
/// - 每次进入学习页面时调用 [startSession]，离开时调用 [endSession]
/// - 每 30 秒将活跃秒数持久化到数据库，防止闪退丢失数据
/// - App 进入后台时暂停计时，回到前台恢复
/// - App 启动时调用 [recoverInterruptedSessions] 清理未正常结束的会话
class StudyTimerService with WidgetsBindingObserver {
  StudyTimerService._();
  static final StudyTimerService instance = StudyTimerService._();

  // ─── 当前会话状态 ──────────────────────────────
  int? _sessionId;

  /// 当前会话已累积的活跃秒数（不含本轮未持久化部分）
  int _persistedSeconds = 0;

  /// 本轮计时开始的墙钟时间（每次 resume 时重置）
  DateTime? _resumeWallTime;

  /// 当前是否处于活跃计时状态
  bool _isRunning = false;

  /// 定期持久化定时器
  Timer? _persistTimer;

  /// 会话代次：用于丢弃跨会话/已结束会话的延迟持久化写入
  int _generation = 0;

  /// 是否已注册 WidgetsBindingObserver
  bool _observerRegistered = false;

  static const int _persistIntervalSeconds = 30;

  // ─── 初始化 & 异常恢复 ─────────────────────────

  /// App 启动时调用，清理上次未正常结束的会话
  static Future<void> recoverInterruptedSessions() async {
    final db = await DatabaseService.database;
    final now = DateTime.now();
    final rows = await db.query(
      'learning_sessions',
      columns: ['id'],
      where: 'ended_at IS NULL',
    );
    if (rows.isNotEmpty) {
      logInfo('StudyTimerService', '发现 ${rows.length} 个中断的学习会话，正在恢复...');
    }
    for (final row in rows) {
      await db.update(
        'learning_sessions',
        {'ended_at': now.toIso8601String()},
        where: 'id = ?',
        whereArgs: [row['id']],
      );
    }
  }

  // ─── 会话生命周期 ──────────────────────────────

  /// 串行化 start/end：页面 initState/dispose 中调用时无法 await，
  /// 若不排队，快速进出页面会出现「end 先于 start 完成 → 留下未结束会话」。
  Future<void> _lifecycleChain = Future<void>.value();

  Future<T> _serialize<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _lifecycleChain = _lifecycleChain.then((_) async {
      try {
        completer.complete(await action());
      } catch (e, stackTrace) {
        completer.completeError(e, stackTrace);
      }
    });
    return completer.future;
  }

  /// 开始一个新的学习会话
  Future<void> startSession(SessionType type) =>
      _serialize(() => _startSession(type));

  Future<void> _startSession(SessionType type) async {
    // 如果已有活跃会话，先结束（直接调用内部实现，避免在队列中等待自己）
    if (_sessionId != null) {
      await _endSession();
    }

    final db = await DatabaseService.database;
    final now = DateTime.now();
    final dateStr = _dateStr(now);

    _generation++;
    _sessionId = await db.insert('learning_sessions', {
      'uuid': const Uuid().v4(),
      'session_type': type.value,
      'started_at': now.toIso8601String(),
      'ended_at': null,
      'duration_seconds': 0,
      'date': dateStr,
    });
    _persistedSeconds = 0;
    _resumeWallTime = now;
    _isRunning = true;
    logDebug('StudyTimerService', '开始会话: ${type.value} id=$_sessionId');

    // 注册生命周期监听
    if (!_observerRegistered) {
      WidgetsBinding.instance.addObserver(this);
      _observerRegistered = true;
    }

    // 启动定期持久化定时器
    _startPersistTimer();
  }

  /// 结束当前学习会话
  Future<void> endSession() => _serialize(_endSession);

  Future<void> _endSession() async {
    if (_sessionId == null) return;

    // 使仍在途的定期持久化失效，避免它晚于最终写入覆盖时长
    _generation++;

    // 先累积本轮未持久化的时间
    _accumulateElapsed();

    // 停止定时器
    _persistTimer?.cancel();
    _persistTimer = null;

    // 移除生命周期监听
    if (_observerRegistered) {
      WidgetsBinding.instance.removeObserver(this);
      _observerRegistered = false;
    }

    // 捕获当前会话状态，避免 await 期间被新会话覆盖
    final sessionId = _sessionId;
    final seconds = _persistedSeconds;

    // 最终写入数据库
    final db = await DatabaseService.database;
    await db.update(
      'learning_sessions',
      {
        'ended_at': DateTime.now().toIso8601String(),
        'duration_seconds': seconds,
      },
      where: 'id = ?',
      whereArgs: [sessionId],
    );

    logDebug('StudyTimerService', '结束会话: id=$sessionId duration=${seconds}s');

    // 重置状态（仅当没有新的会话在此期间启动时）
    if (_sessionId == sessionId) {
      _sessionId = null;
      _persistedSeconds = 0;
      _resumeWallTime = null;
      _isRunning = false;
    }
  }

  // ─── App 生命周期处理 ──────────────────────────

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_sessionId == null) return;

    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        // App 进入后台 → 暂停计时并持久化
        _pauseAndPersist();
        break;
      case AppLifecycleState.resumed:
        // App 回到前台 → 恢复计时
        _resume();
        break;
      case AppLifecycleState.detached:
        // App 被销毁 → 立即持久化（不 end，保留记录等下次恢复）
        _pauseAndPersist();
        break;
    }
  }

  /// 暂停计时并持久化当前累积时间
  void _pauseAndPersist() {
    if (!_isRunning) return;
    _accumulateElapsed();
    _isRunning = false;
    _resumeWallTime = null;

    // 立即持久化
    _persistToDb();
  }

  /// 恢复计时
  void _resume() {
    if (_sessionId == null || _isRunning) return;
    _resumeWallTime = DateTime.now();
    _isRunning = true;
  }

  // ─── 定期持久化 ────────────────────────────────

  void _startPersistTimer() {
    _persistTimer?.cancel();
    _persistTimer = Timer.periodic(
      const Duration(seconds: _persistIntervalSeconds),
      (_) {
        if (_isRunning) {
          _accumulateElapsed();
          _persistToDb();
        }
      },
    );
  }

  /// 累积从上次 resume 到现在的活跃秒数
  void _accumulateElapsed() {
    final resumeWallTime = _resumeWallTime;
    if (resumeWallTime == null) return;
    final now = DateTime.now();
    final elapsed = now.difference(resumeWallTime).inSeconds;
    if (elapsed > 0) {
      _persistedSeconds += elapsed;
    }
    _resumeWallTime = now;
  }

  /// 将当前累积秒数写入数据库
  void _persistToDb() {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    // 捕获当前值，避免 await 期间会话切换导致写到新会话上
    final seconds = _persistedSeconds;
    final generation = _generation;
    unawaited(_persistToDbAsync(sessionId, seconds, generation));
  }

  static Future<void> _persistToDbAsync(
    int sessionId,
    int seconds,
    int generation,
  ) async {
    try {
      final db = await DatabaseService.database;
      if (generation != StudyTimerService.instance._generation) return;
      await db.update(
        'learning_sessions',
        {'duration_seconds': seconds},
        where: 'id = ?',
        whereArgs: [sessionId],
      );
    } catch (e, stackTrace) {
      logError('StudyTimerService', '持久化学习时长失败: $e', stackTrace);
    }
  }

  // ─── 查询接口 ──────────────────────────────────

  /// 今日学习总时长（秒）
  static Future<int> getTodayTotalSeconds() async {
    final db = await DatabaseService.database;
    final today = _dateStr(DateTime.now());
    final result = Sqflite.firstIntValue(
      await db.rawQuery(
        'SELECT COALESCE(SUM(duration_seconds), 0) FROM learning_sessions WHERE date = ?',
        [today],
      ),
    );
    return result ?? 0;
  }

  /// 近 7 天每日学习时长（秒）
  /// 返回列表，每个元素为 `{date, duration_seconds}`
  static Future<List<Map<String, dynamic>>> getWeeklyDuration() async {
    final db = await DatabaseService.database;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final startStr = _dateStr(today.subtract(const Duration(days: 6)));

    // 一次 GROUP BY 查询，避免 7 次串行 SUM
    final rows = await db.rawQuery(
      'SELECT date, COALESCE(SUM(duration_seconds), 0) AS total '
      'FROM learning_sessions WHERE date >= ? GROUP BY date',
      [startStr],
    );
    final byDate = <String, int>{
      for (final row in rows)
        row['date'] as String: (row['total'] as int?) ?? 0,
    };

    final results = <Map<String, dynamic>>[];
    for (int i = 6; i >= 0; i--) {
      final dateStr = _dateStr(today.subtract(Duration(days: i)));
      results.add({'date': dateStr, 'duration_seconds': byDate[dateStr] ?? 0});
    }
    return results;
  }

  /// 指定月份每日学习时长（秒）
  /// 返回列表，每个元素为 `{date, duration_seconds}`
  static Future<List<Map<String, dynamic>>> getMonthlyDuration(
    int year,
    int month,
  ) async {
    final db = await DatabaseService.database;
    final prefix = '${year.toString()}-${month.toString().padLeft(2, '0')}';

    final rows = await db.rawQuery(
      'SELECT date, SUM(duration_seconds) as total FROM learning_sessions WHERE date LIKE ? GROUP BY date',
      ['$prefix%'],
    );

    final durationMap = <String, int>{};
    for (final r in rows) {
      durationMap[r['date'] as String] = (r['total'] as int?) ?? 0;
    }

    final daysInMonth = DateTime(year, month + 1, 0).day;
    final results = <Map<String, dynamic>>[];
    for (int day = 1; day <= daysInMonth; day++) {
      final dateStr = '$prefix-${day.toString().padLeft(2, '0')}';
      results.add({
        'date': dateStr,
        'duration_seconds': durationMap[dateStr] ?? 0,
      });
    }
    return results;
  }

  /// 按学习类型统计累计时长（秒）
  /// 返回 `Map<session_type, duration_seconds>`
  static Future<Map<String, int>> getDurationByType() async {
    final db = await DatabaseService.database;
    final rows = await db.rawQuery(
      'SELECT session_type, COALESCE(SUM(duration_seconds), 0) as total FROM learning_sessions GROUP BY session_type',
    );
    final result = <String, int>{};
    for (final r in rows) {
      result[r['session_type'] as String] = (r['total'] as int?) ?? 0;
    }
    return result;
  }

  /// 累计学习总时长（秒）
  static Future<int> getTotalDuration() async {
    final db = await DatabaseService.database;
    final result = Sqflite.firstIntValue(
      await db.rawQuery(
        'SELECT COALESCE(SUM(duration_seconds), 0) FROM learning_sessions',
      ),
    );
    return result ?? 0;
  }

  // ─── 工具方法 ──────────────────────────────────

  static String _dateStr(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  /// 格式化秒数为可读文本（智能单位）
  /// - < 1 分钟: "不到 1 分钟"
  /// - 1~59 分钟: "23 分钟"
  /// - ≥ 1 小时，分钟 > 0: "1 小时 23 分钟"
  /// - ≥ 1 小时，分钟 = 0: "5 小时"
  static String formatDuration(int totalSeconds) {
    if (totalSeconds < 60) return '不到 1 分钟';
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    if (hours == 0) {
      return '$minutes 分钟';
    }
    if (minutes == 0) {
      return '$hours 小时';
    }
    return '$hours 小时 $minutes 分钟';
  }
}
