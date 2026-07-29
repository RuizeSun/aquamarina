import 'package:flutter/material.dart';
import '../../services/learning_service.dart';
import '../../services/dictionary_service.dart';
import '../word_detail_page.dart';

/// 格式化复习日期，显示友好文本
String _formatReviewDate(String dateStr) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final parts = dateStr.split('-');
  if (parts.length != 3) return dateStr;
  final date = DateTime(
    int.parse(parts[0]),
    int.parse(parts[1]),
    int.parse(parts[2]),
  );
  final diff = date.difference(today).inDays;

  if (diff < 0) return '已过期（$dateStr）';
  if (diff == 0) return '今天';
  if (diff == 1) return '明天';
  if (diff <= 7) return '$diff 天后';
  return dateStr;
}

class ReviewPlanPage extends StatefulWidget {
  const ReviewPlanPage({super.key});

  @override
  State<ReviewPlanPage> createState() => _ReviewPlanPageState();
}

class _ReviewPlanPageState extends State<ReviewPlanPage> {
  List<Map<String, dynamic>> _planItems = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadPlan();
  }

  Future<void> _loadPlan() async {
    setState(() => _isLoading = true);
    try {
      final items = await LearningService.getReviewPlan();
      if (mounted) {
        setState(() {
          _planItems = items;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _markAsMastered(int index) async {
    final word = _planItems[index]['word'] as String;
    await LearningService.markAsMastered(word);
    if (mounted) {
      setState(() {
        _planItems.removeAt(index);
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('"$word" 已标记为掌握')));
    }
  }

  Future<void> _openWordDetail(String word) async {
    final result = await DictionaryService.searchEnExact(word);
    if (result == null || !mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WordDetailPage(
          result: CombinedResult(enEntry: result),
          word: word,
        ),
      ),
    );
  }

  Color _dateColor(String dateStr) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final parts = dateStr.split('-');
    if (parts.length != 3) return Colors.grey;
    final date = DateTime(
      int.parse(parts[0]),
      int.parse(parts[1]),
      int.parse(parts[2]),
    );
    final diff = date.difference(today).inDays;

    if (diff < 0) return Colors.red;
    if (diff == 0) return Colors.orange;
    return Colors.grey;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('复习计划')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _planItems.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.event_note,
                    size: 64,
                    color: colorScheme.primary.withValues(alpha: 0.3),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '暂无复习计划',
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '学习新单词后，系统会自动安排复习',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: _loadPlan,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: _planItems.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final item = _planItems[index];
                  final word = item['word'] as String;
                  final date = item['next_review_date'] as String;

                  return ListTile(
                    onTap: () => _openWordDetail(word),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    title: Text(
                      word,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      '复习时间：${_formatReviewDate(date)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: _dateColor(date),
                      ),
                    ),
                    trailing: IconButton(
                      icon: Icon(
                        Icons.check_circle_outline,
                        color: colorScheme.primary,
                      ),
                      tooltip: '标记为已掌握',
                      onPressed: () => _markAsMastered(index),
                    ),
                  );
                },
              ),
            ),
    );
  }
}
