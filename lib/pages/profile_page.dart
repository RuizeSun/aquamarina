import 'package:flutter/material.dart';
import '../services/learning_service.dart';
import 'favorites_page.dart';
import 'notes_page.dart';
import 'settings/settings_page.dart';

/// 个人页：展示个人信息与学习统计，并作为「设置」等功能的入口
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  DailyStats? _stats;
  int _streak = 0;
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
    setState(() => _isLoading = true);

    try {
      final stats = await LearningService.getDailyStats();
      final streak = await LearningService.getStreak();
      final goalProgress = await LearningService.getTodayGoalProgress();
      if (!mounted) return;
      setState(() {
        _stats = stats;
        _streak = streak;
        _goalProgress = goalProgress;
        _isLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('个人'), centerTitle: false),
      body: RefreshIndicator(
        onRefresh: _loadData,
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
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
        ),
      ),
    );
  }

  /// 顶部个人信息区域
  Widget _buildProfileHeader(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Padding(
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
  Widget _buildStatsCard(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final stats = _stats;
    final learned = (_goalProgress['learned'] as int?) ?? 0;
    final goal = (_goalProgress['goal'] as int?) ?? 10;
    final completed = (_goalProgress['completed'] as bool?) ?? false;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  completed ? Icons.emoji_events : Icons.local_fire_department,
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
                  value: stats?.wrongWordCount ?? 0,
                ),
              ],
            ),
          ],
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

  /// 功能入口列表
  Widget _buildEntryList(BuildContext context) {
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
