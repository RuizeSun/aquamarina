import 'package:flutter/material.dart';
import '../../../models/user_word_record.dart';

/// 单词学习/复习总结画面中单个单词的复习安排信息
class WordSummaryItem {
  final String word;
  final String meaning;
  final String statusLabel;

  const WordSummaryItem({
    required this.word,
    required this.meaning,
    required this.statusLabel,
  });
}

/// 将用户单词记录转换为总结画面中的状态文案
/// （如 "1 天后复习"、"今天复习"、"已掌握"、"需重新学习"、"待安排"）
String formatNextReviewLabel(UserWordRecord? record) {
  if (record == null) return '需重新学习';
  if (record.isMastered) return '已掌握';

  final nextDate = record.nextReviewDate;
  if (nextDate == null) return '待安排';

  // 计算下次复习日期与今天的差值（天数）
  final parts = nextDate.split('-');
  if (parts.length != 3) return nextDate;
  final target = DateTime(
    int.parse(parts[0]),
    int.parse(parts[1]),
    int.parse(parts[2]),
  );
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final diff = target.difference(today).inDays;
  if (diff <= 0) return '今天复习';
  return '$diff 天后复习';
}

/// 单词学习/复习完成后的总结画面（仿句型练习完成页风格）
///
/// 展示本次学习的统计信息，以及每个单词的下次复习安排
/// （如 "1 天后复习" / "已掌握" / "需重新学习"）。
class WordLearningSummaryView extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<WordSummaryItem> items;
  final int learnedCount;
  final int easyCount;
  final int hardCount;
  final int forgotCount;
  final int masteredCount;

  const WordLearningSummaryView({
    super.key,
    required this.title,
    required this.icon,
    required this.items,
    required this.learnedCount,
    this.easyCount = 0,
    this.hardCount = 0,
    this.forgotCount = 0,
    this.masteredCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 标题与图标
        Center(
          child: Column(
            children: [
              Icon(icon, size: 64, color: Colors.amber),
              const SizedBox(height: 12),
              Text(
                title,
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),

        // 统计卡片
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              _buildStatRow(theme, '本次学习', '$learnedCount 词'),
              const SizedBox(height: 8),
              _buildStatRow(theme, '简单', '$easyCount 词'),
              const SizedBox(height: 8),
              _buildStatRow(theme, '困难', '$hardCount 词'),
              const SizedBox(height: 8),
              _buildStatRow(theme, '忘记', '$forgotCount 词'),
              const SizedBox(height: 8),
              _buildStatRow(theme, '已掌握', '$masteredCount 词'),
            ],
          ),
        ),
        const SizedBox(height: 20),

        // 复习计划标题
        Text(
          '下次复习计划',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),

        // 单词列表
        Expanded(
          child: ListView.builder(
            itemCount: items.length,
            itemBuilder: (context, index) {
              return _buildWordRow(theme, colorScheme, items[index]);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildStatRow(ThemeData theme, String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: theme.textTheme.bodyMedium),
        Text(
          value,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget _buildWordRow(
    ThemeData theme,
    ColorScheme colorScheme,
    WordSummaryItem item,
  ) {
    final bool mastered = item.statusLabel == '已掌握';
    final bool relearn = item.statusLabel == '需重新学习';
    final Color badgeBg;
    if (mastered) {
      badgeBg = Colors.green.withValues(alpha: 0.15);
    } else if (relearn) {
      badgeBg = colorScheme.errorContainer;
    } else {
      badgeBg = colorScheme.primaryContainer;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.word,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    item.meaning,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: badgeBg,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                item.statusLabel,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
