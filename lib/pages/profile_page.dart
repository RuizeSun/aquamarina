import 'package:flutter/material.dart';
import '../services/learning_service.dart';
import '../services/study_timer_service.dart';
import 'favorites_page.dart';
import 'vocabulary/stats_page.dart';
import 'notes_page.dart';
import 'settings/settings_page.dart';

/// 个人页：展示个人信息与学习统计，并作为「设置」等功能的入口
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => ProfilePageState();
}

class ProfilePageState extends State<ProfilePage> {
  /// 宽屏断点：达到后切换为「左学习进度 / 右功能入口」双栏布局
  static const double _wideBreakpoint = 900;

  /// 双栏布局下内容的最大宽度，避免左右两栏被拉得过开
  static const double _maxWideContentWidth = 1120;

  /// 单栏布局下内容的最大宽度，避免卡片、统计项被无限拉伸
  static const double _maxNarrowContentWidth = 800;

  /// 外部调用以刷新数据（供 MainShell 切 tab 时使用）
  void refresh() => _loadData();

  DailyStats? _stats;
  int _streak = 0;
  int _todayDurationSeconds = 0;
  Map<String, dynamic> _goalProgress = {
    'learned': 0,
    'goal': 10,
    'completed': false,
  };
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    // 首次加载时显示 loading，后续同步/切 Tab 触发的刷新静默更新。
    final isFirstLoad = _stats == null;
    if (isFirstLoad) {
      setState(() => _isLoading = true);
    }

    try {
      final summary = await Future.wait<dynamic>([
        LearningService.getDailyStats(),
        LearningService.getStreak(),
        LearningService.getTodayGoalProgress(),
        StudyTimerService.getTodayTotalSeconds(),
      ]);
      final stats = summary[0] as DailyStats;
      final streak = summary[1] as int;
      final goalProgress = summary[2] as Map<String, dynamic>;
      final todayDuration = summary[3] as int;
      if (!mounted) return;
      setState(() {
        _stats = stats;
        _streak = streak;
        _goalProgress = goalProgress;
        _todayDurationSeconds = todayDuration;
        _isLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final isWide = screenWidth >= _wideBreakpoint;
    // 宽屏时内容收窄并居中，否则头像、统计项与入口箭头会被推到窗口两端。
    final maxContentWidth = isWide
        ? _maxWideContentWidth
        : _maxNarrowContentWidth;
    final horizontalInset = screenWidth > maxContentWidth
        ? (screenWidth - maxContentWidth) / 2
        : 0.0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('个人'),
        centerTitle: false,
        // 让标题与下方内容左边缘对齐，而不是贴着窗口最左侧
        titleSpacing: horizontalInset + 16,
      ),
      body: RefreshIndicator(
        onRefresh: _loadData,
        child: ListView(
          padding: EdgeInsets.symmetric(
            vertical: 8,
            horizontal: horizontalInset,
          ),
          children: [
            isWide ? _buildWideLayout(context) : _buildNarrowLayout(context),
          ],
        ),
      ),
    );
  }

  /// 窄屏 / 中屏：个人信息 + 学习进度 + 功能入口纵向排列
  Widget _buildNarrowLayout(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildProfileHeader(context),
        const SizedBox(height: 16),
        if (_isLoading)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else ...[
          _buildStatsCard(context),
          const SizedBox(height: 8),
        ],
        const Divider(),
        _buildEntryList(context),
      ],
    );
  }

  /// 宽屏：左侧学习进度、右侧功能入口，提高横向空间利用率
  Widget _buildWideLayout(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildProfileHeader(context),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: SizedBox(
                  key: const ValueKey('profile-progress-column'),
                  child: _isLoading
                      ? _buildStatsLoadingCard()
                      : _buildStatsCard(context, margin: EdgeInsets.zero),
                ),
              ),
              const SizedBox(width: 24),
              Expanded(
                flex: 2,
                child: SizedBox(
                  key: const ValueKey('profile-options-column'),
                  child: _buildEntryCard(context),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 学习进度加载中的占位卡片（宽屏左栏）
  Widget _buildStatsLoadingCard() {
    return const Card(
      margin: EdgeInsets.zero,
      child: SizedBox(
        height: 220,
        child: Center(child: CircularProgressIndicator()),
      ),
    );
  }

  /// 顶部个人信息区域
  Widget _buildProfileHeader(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Padding(
      key: const ValueKey('profile-header'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          CircleAvatar(
            radius: 32,
            backgroundColor: colorScheme.primaryContainer,
            child: Icon(
              Icons.face,
              size: 36,
              color: colorScheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Aquamarina',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '坚持每天学习，遇见更好的自己',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 学习统计卡片
  Widget _buildStatsCard(
    BuildContext context, {
    EdgeInsetsGeometry margin = const EdgeInsets.symmetric(horizontal: 16),
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final stats = _stats;
    final learned = (_goalProgress['learned'] as int?) ?? 0;
    final goal = (_goalProgress['goal'] as int?) ?? 10;
    final completed = (_goalProgress['completed'] as bool?) ?? false;

    final todayDurationText = StudyTimerService.formatDuration(
      _todayDurationSeconds,
    );

    return Card(
      margin: margin,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const StatsPage()));
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    completed
                        ? Icons.emoji_events
                        : Icons.local_fire_department,
                    color: completed ? Colors.amber : colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    completed ? '今日打卡已完成' : '今日学习进度',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '连续打卡 $_streak 天',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // 进度条
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: goal > 0 ? (learned / goal).clamp(0.0, 1.0) : 0,
                  minHeight: 8,
                  backgroundColor: colorScheme.surfaceContainerHighest,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '已学 $learned / $goal 个新词',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              // 统计行
              Row(
                children: [
                  _buildStatItem(
                    icon: Icons.auto_stories,
                    label: '今日学习',
                    value: stats?.todayLearnedCount ?? 0,
                  ),
                  _buildStatItem(
                    icon: Icons.replay,
                    label: '今日复习',
                    value: stats?.todayReviewedCount ?? 0,
                  ),
                  _buildStatItem(
                    icon: Icons.schedule,
                    label: '待复习',
                    value: stats?.dueReviewCount ?? 0,
                  ),
                  _buildStatItem(
                    icon: Icons.error_outline,
                    label: '待纠正',
                    // 这里展示的是「句型错题本」条数（与单词待复习队列分开统计）
                    value: stats?.wrongSentenceCount ?? 0,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // 今日学习时长 + 查看更多提示
              Row(
                children: [
                  Icon(
                    Icons.schedule,
                    size: 16,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '今日学习 $todayDurationText',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '查看详情',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.primary,
                    ),
                  ),
                  Icon(
                    Icons.chevron_right,
                    size: 16,
                    color: colorScheme.primary,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatItem({
    required IconData icon,
    required String label,
    required int value,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Expanded(
      child: Column(
        children: [
          Icon(icon, size: 20, color: colorScheme.primary),
          const SizedBox(height: 4),
          Text(
            '$value',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// 宽屏右栏的功能入口卡片
  Widget _buildEntryCard(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Row(
              children: [
                Icon(
                  Icons.apps_rounded,
                  size: 18,
                  color: colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Text(
                  '快捷入口',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          _buildEntryList(context, divided: true),
        ],
      ),
    );
  }

  /// 功能入口列表
  Widget _buildEntryList(BuildContext context, {bool divided = false}) {
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        ListTile(
          leading: Icon(Icons.edit_note, color: colorScheme.primary),
          title: const Text('我的笔记'),
          subtitle: const Text('查看所有单词笔记'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (context) => const NotesPage()));
          },
        ),
        if (divided) const Divider(height: 1, indent: 56, endIndent: 16),
        ListTile(
          leading: Icon(
            Icons.star_outline_rounded,
            color: Colors.amber.shade700,
          ),
          title: const Text('我的收藏'),
          subtitle: const Text('收藏的单词与笔记'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (context) => const FavoritesPage()),
            );
          },
        ),
        if (divided) const Divider(height: 1, indent: 56, endIndent: 16),
        ListTile(
          leading: Icon(Icons.settings_outlined, color: colorScheme.primary),
          title: const Text('设置'),
          subtitle: const Text('外观、语音、背单词与 AI 配置'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (context) => const SettingsPage()),
            );
          },
        ),
      ],
    );
  }
}
