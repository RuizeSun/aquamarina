import 'package:flutter/material.dart';
import '../../services/learning_service.dart';
import '../../services/study_timer_service.dart';

/// 单词学习统计页：打卡日历、7天趋势、连续打卡、学习时长
class StatsPage extends StatefulWidget {
  const StatsPage({super.key});

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  bool _isLoading = true;
  int _streak = 0;
  int _monthlyCheckInCount = 0;

  // 日历状态
  late DateTime _displayedMonth;
  List<Map<String, dynamic>> _monthlyData = [];
  List<Map<String, dynamic>> _weeklyData = [];

  // 学习时长相关
  int _todayDurationSeconds = 0;
  int _totalDurationSeconds = 0;
  Map<String, int> _durationByType = {};
  List<Map<String, dynamic>> _weeklyDurationData = [];

  // 词汇测试历史相关
  List<Map<String, dynamic>> _vocabTestHistory = [];
  int _vocabTestCount = 0;
  double _vocabTestAvgAccuracy = 0.0;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _displayedMonth = DateTime(now.year, now.month);
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);

    final streak = await LearningService.getStreak();
    final weekly = await LearningService.getWeeklyActivity();
    final monthly = await LearningService.getMonthlyActivity(
      _displayedMonth.year,
      _displayedMonth.month,
    );

    // 学习时长数据
    final todaySeconds = await StudyTimerService.getTodayTotalSeconds();
    final totalSeconds = await StudyTimerService.getTotalDuration();
    final byType = await StudyTimerService.getDurationByType();
    final weeklyDuration = await StudyTimerService.getWeeklyDuration();

    // 词汇测试历史数据
    final testHistory = await LearningService.getVocabTestHistory(limit: 50);
    final testStats = await LearningService.getVocabTestStats();

    if (!mounted) return;
    setState(() {
      _streak = streak;
      _weeklyData = weekly;
      _monthlyData = monthly;
      _monthlyCheckInCount = monthly
          .where((d) => d['completed'] == true)
          .length;
      _todayDurationSeconds = todaySeconds;
      _totalDurationSeconds = totalSeconds;
      _durationByType = byType;
      _weeklyDurationData = weeklyDuration;
      _vocabTestHistory = testHistory;
      _vocabTestCount = testStats['count'] as int? ?? 0;
      _vocabTestAvgAccuracy = testStats['avgAccuracy'] as double? ?? 0.0;
      _isLoading = false;
    });
  }

  Future<void> _changeMonth(int offset) async {
    setState(() {
      _displayedMonth = DateTime(
        _displayedMonth.year,
        _displayedMonth.month + offset,
      );
    });
    final monthly = await LearningService.getMonthlyActivity(
      _displayedMonth.year,
      _displayedMonth.month,
    );
    if (!mounted) return;
    setState(() {
      _monthlyData = monthly;
      _monthlyCheckInCount = monthly
          .where((d) => d['completed'] == true)
          .length;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('学习统计'), centerTitle: false),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadData,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                children: [
                  _buildStreakCard(theme, colorScheme),
                  const SizedBox(height: 24),
                  // 学习时长统计
                  _buildDurationSection(theme, colorScheme),
                  const SizedBox(height: 24),
                  // 词汇测试历史
                  _buildVocabTestSection(theme, colorScheme),
                  const SizedBox(height: 24),
                  Text('打卡日历', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  _buildCalendar(theme, colorScheme),
                  const SizedBox(height: 24),
                  Text('近 7 天趋势', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    '每日学习与复习单词数',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _buildWeeklyChart(theme, colorScheme),
                  const SizedBox(height: 24),
                ],
              ),
            ),
    );
  }

  // ─── 连续打卡卡片 ────────────────────────────

  Widget _buildStreakCard(ThemeData theme, ColorScheme colorScheme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Colors.orange.withValues(alpha: 0.9),
            Colors.deepOrange.withValues(alpha: 0.8),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.local_fire_department,
                color: Colors.white,
                size: 40,
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '连续打卡',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: Colors.white.withValues(alpha: 0.9),
                    ),
                  ),
                  Text(
                    '$_streak 天',
                    style: theme.textTheme.headlineLarge?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '本月已打卡 $_monthlyCheckInCount 天',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: Colors.white.withValues(alpha: 0.9),
            ),
          ),
        ],
      ),
    );
  }

  // ─── 学习时长统计 ────────────────────────────

  Widget _buildDurationSection(ThemeData theme, ColorScheme colorScheme) {
    final todayText = StudyTimerService.formatDuration(_todayDurationSeconds);
    final totalText = StudyTimerService.formatDuration(_totalDurationSeconds);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('学习时长', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),

        // 今日 + 累计时长卡片
        Row(
          children: [
            // 今日时长
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.today,
                      color: colorScheme.onPrimaryContainer,
                      size: 20,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      todayText,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: colorScheme.onPrimaryContainer,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '今日学习',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onPrimaryContainer.withValues(
                          alpha: 0.7,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            // 累计时长
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.timer,
                      color: colorScheme.onSecondaryContainer,
                      size: 20,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      totalText,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: colorScheme.onSecondaryContainer,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '累计学习',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSecondaryContainer.withValues(
                          alpha: 0.7,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),

        const SizedBox(height: 16),

        // 近 7 天时长柱状图
        Text('近 7 天学习时长', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          '每日有效学习时间',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        _buildDurationWeeklyChart(theme, colorScheme),

        // 各类型时长分布（仅当有数据时显示）
        if (_totalDurationSeconds > 0) ...[
          const SizedBox(height: 16),
          Text('时长分布', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          _buildDurationByType(theme, colorScheme),
        ],
      ],
    );
  }

  Widget _buildDurationWeeklyChart(ThemeData theme, ColorScheme colorScheme) {
    final barColor = colorScheme.primary;

    // 计算最大值（秒）
    var maxValue = 0;
    for (final day in _weeklyDurationData) {
      final secs = (day['duration_seconds'] as int?) ?? 0;
      if (secs > maxValue) maxValue = secs;
    }
    if (maxValue <= 0) maxValue = 1;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          SizedBox(
            height: 120,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final day in _weeklyDurationData)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: _buildDurationBar(
                        (day['duration_seconds'] as int?) ?? 0,
                        maxValue,
                        barColor,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // 日期标签
          Row(
            children: [
              for (final day in _weeklyDurationData)
                Expanded(
                  child: Center(
                    child: Text(
                      _formatDateLabel(day['date'] as String),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDurationBar(int seconds, int maxValue, Color color) {
    final fraction = maxValue <= 0 ? 0.0 : (seconds / maxValue).clamp(0.0, 1.0);
    final heightFactor = fraction == 0 ? 0.08 : fraction;

    // 格式化显示文本
    final String label;
    if (seconds < 60) {
      label = '';
    } else {
      final minutes = seconds ~/ 60;
      if (minutes < 60) {
        label = '${minutes}m';
      } else {
        final h = minutes ~/ 60;
        final m = minutes % 60;
        label = m > 0 ? '${h}h${m}m' : '${h}h';
      }
    }

    return Align(
      alignment: Alignment.bottomCenter,
      child: FractionallySizedBox(
        heightFactor: heightFactor,
        child: Container(
          width: 14,
          decoration: BoxDecoration(
            color: color.withValues(alpha: seconds > 0 ? 0.9 : 0.15),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
          ),
          child: label.isNotEmpty
              ? Align(
                  alignment: Alignment.topCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 7,
                        color: color,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                )
              : null,
        ),
      ),
    );
  }

  Widget _buildDurationByType(ThemeData theme, ColorScheme colorScheme) {
    final typeLabels = {
      'word_learn': '单词学习',
      'word_review': '单词复习',
      'sentence_practice': '句型练习',
      'wrong_sentence_practice': '错题练习',
      'vocab_test': '词汇测试',
      'word_spelling': '单词拼写',
    };
    final typeIcons = {
      'word_learn': Icons.auto_stories,
      'word_review': Icons.replay,
      'sentence_practice': Icons.smart_toy,
      'wrong_sentence_practice': Icons.error_outline,
      'vocab_test': Icons.quiz,
      'word_spelling': Icons.spellcheck,
    };
    final typeColors = {
      'word_learn': colorScheme.primary,
      'word_review': Colors.orange,
      'sentence_practice': Colors.teal,
      'wrong_sentence_practice': Colors.red.shade300,
      'vocab_test': Colors.purple,
      'word_spelling': Colors.indigo,
    };

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          for (final entry in typeLabels.entries)
            if ((_durationByType[entry.key] ?? 0) > 0)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Icon(
                      typeIcons[entry.key] ?? Icons.school,
                      size: 18,
                      color: typeColors[entry.key] ?? colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(entry.value, style: theme.textTheme.bodyMedium),
                    const Spacer(),
                    Text(
                      StudyTimerService.formatDuration(
                        _durationByType[entry.key] ?? 0,
                      ),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
          // 如果所有类型都没有数据
          if (_durationByType.isEmpty ||
              _durationByType.values.every((v) => v == 0))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                '暂无数据',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ─── 词汇测试历史 ────────────────────────────

  Widget _buildVocabTestSection(ThemeData theme, ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('词汇测试历史', style: theme.textTheme.titleMedium),
            const Spacer(),
            if (_vocabTestCount > 0)
              Text(
                '平均正确率 ${(_vocabTestAvgAccuracy * 100).round()}%',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (_vocabTestHistory.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '暂无测试记录，完成一次词汇测试后这里会展示历史趋势',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                // 最近 7 次测试的正确率柱状图
                SizedBox(
                  height: 100,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (final item in _vocabTestHistory.reversed.take(7))
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 3),
                            child: _buildTestBar(
                              ((item['accuracy'] as num?) ?? 0).toDouble(),
                              theme,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                // 最近记录摘要
                for (final item in _vocabTestHistory.take(3))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Icon(
                          Icons.quiz,
                          size: 16,
                          color: colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _formatTestDate(item['date'] as String),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        Text(
                          '${item['correct_count']}/${item['total_count']} (${(((item['accuracy'] as num?) ?? 0) * 100).round()}%)',
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  /// 词汇测试正确率柱状条
  Widget _buildTestBar(double accuracy, ThemeData theme) {
    final fraction = accuracy.clamp(0.0, 1.0);
    // 无数据时显示淡色小底座
    final heightFactor = accuracy <= 0 ? 0.08 : fraction;
    final color = accuracy >= 0.8
        ? Colors.green
        : accuracy >= 0.6
        ? Colors.orange
        : Colors.red;

    return Align(
      alignment: Alignment.bottomCenter,
      child: FractionallySizedBox(
        heightFactor: heightFactor,
        child: Container(
          width: 14,
          decoration: BoxDecoration(
            color: color.withValues(alpha: accuracy > 0 ? 0.9 : 0.15),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
          ),
        ),
      ),
    );
  }

  /// 格式化测试时间（ISO 字符串 → MM/dd HH:mm）
  String _formatTestDate(String isoDate) {
    final dt = DateTime.tryParse(isoDate);
    if (dt == null) return isoDate;
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$m/$d $h:$min';
  }

  // ─── 打卡日历 ────────────────────────────────

  Widget _buildCalendar(ThemeData theme, ColorScheme colorScheme) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final firstDay = DateTime(_displayedMonth.year, _displayedMonth.month, 1);
    // DateTime.weekday: 周一=1 ... 周日=7 → 转为周一开头偏移(周一=0 ... 周日=6)
    final leadingEmpty = (firstDay.weekday + 6) % 7;
    final daysInMonth = DateTime(
      _displayedMonth.year,
      _displayedMonth.month + 1,
      0,
    ).day;

    final cells = <Widget>[
      // 星期表头（周一开头）
      for (final label in ['一', '二', '三', '四', '五', '六', '日'])
        Center(
          child: Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      for (int i = 0; i < leadingEmpty; i++) const SizedBox.shrink(),
      for (int day = 1; day <= daysInMonth; day++)
        _buildCalendarCell(theme, colorScheme, day, _displayedMonth, today),
    ];

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          // 月份切换
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: () => _changeMonth(-1),
                tooltip: '上个月',
              ),
              Text(
                '${_displayedMonth.year} 年 ${_displayedMonth.month} 月',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: () => _changeMonth(1),
                tooltip: '下个月',
              ),
            ],
          ),
          const SizedBox(height: 4),
          GridView.count(
            crossAxisCount: 7,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 4,
            crossAxisSpacing: 4,
            children: cells,
          ),
        ],
      ),
    );
  }

  Widget _buildCalendarCell(
    ThemeData theme,
    ColorScheme colorScheme,
    int day,
    DateTime month,
    DateTime today,
  ) {
    final date = DateTime(month.year, month.month, day);
    final dateStr =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

    final isCompleted = _monthlyData.any(
      (d) => d['date'] == dateStr && d['completed'] == true,
    );
    final isToday =
        date.year == today.year &&
        date.month == today.month &&
        date.day == today.day;

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () {
        // 显示当天详情提示
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(isCompleted ? '$dateStr 已打卡' : '$dateStr 未打卡'),
            duration: const Duration(milliseconds: 1200),
          ),
        );
      },
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isCompleted
              ? Colors.orange.withValues(alpha: 0.85)
              : isToday
              ? colorScheme.primary.withValues(alpha: 0.15)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: isToday ? Border.all(color: colorScheme.primary) : null,
        ),
        child: Text(
          '$day',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: isCompleted
                ? Colors.white
                : isToday
                ? colorScheme.primary
                : colorScheme.onSurface,
            fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  // ─── 7 天趋势图 ──────────────────────────────

  Widget _buildWeeklyChart(ThemeData theme, ColorScheme colorScheme) {
    final learnedColor = colorScheme.primary;
    final reviewedColor = Colors.orange;

    // 计算最大值用于柱状图比例
    var maxValue = 0;
    for (final day in _weeklyData) {
      final learned = (day['words_learned'] as int?) ?? 0;
      final reviewed = (day['words_reviewed'] as int?) ?? 0;
      if (learned > maxValue) maxValue = learned;
      if (reviewed > maxValue) maxValue = reviewed;
    }
    if (maxValue <= 0) maxValue = 1;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          // 图例
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildLegendItem(theme, '学习', learnedColor),
              const SizedBox(width: 16),
              _buildLegendItem(theme, '复习', reviewedColor),
            ],
          ),
          const SizedBox(height: 12),
          // 柱状图
          SizedBox(
            height: 140,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final day in _weeklyData)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: Column(
                        children: [
                          // 学习柱（上）
                          _buildBar(
                            (day['words_learned'] as int?) ?? 0,
                            maxValue,
                            learnedColor,
                          ),
                          const SizedBox(height: 2),
                          // 复习柱（下）
                          _buildBar(
                            (day['words_reviewed'] as int?) ?? 0,
                            maxValue,
                            reviewedColor,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // 日期标签
          Row(
            children: [
              for (final day in _weeklyData)
                Expanded(
                  child: Center(
                    child: Text(
                      _formatDateLabel(day['date'] as String),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 单根柱状条：在 Expanded 区域内按数值比例伸缩高度，永不溢出。
  Widget _buildBar(int value, int maxValue, Color color) {
    final fraction = maxValue <= 0 ? 0.0 : (value / maxValue).clamp(0.0, 1.0);
    // 数值为 0 时仍显示一个淡色小底座，便于视觉对比
    final heightFactor = fraction == 0 ? 0.08 : fraction;
    return Expanded(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: FractionallySizedBox(
          heightFactor: heightFactor,
          child: Container(
            width: 14,
            decoration: BoxDecoration(
              color: color.withValues(alpha: value > 0 ? 0.9 : 0.15),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(4),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLegendItem(ThemeData theme, String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(label, style: theme.textTheme.bodySmall),
      ],
    );
  }

  String _formatDateLabel(String dateStr) {
    // dateStr: yyyy-MM-dd → MM/dd
    final parts = dateStr.split('-');
    if (parts.length != 3) return dateStr;
    return '${parts[1]}/${parts[2]}';
  }
}
