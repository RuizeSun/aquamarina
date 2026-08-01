import 'package:flutter/material.dart';
import '../models/ai_sentence.dart';
import '../models/ai_sentence_set.dart';
import '../services/ai_sentence_service.dart';
import 'ai_practice_session_page.dart';

/// 错题本查看页面
class WrongSentenceBookPage extends StatefulWidget {
  const WrongSentenceBookPage({super.key});

  @override
  State<WrongSentenceBookPage> createState() => _WrongSentenceBookPageState();
}

class _WrongSentenceBookPageState extends State<WrongSentenceBookPage> {
  final AiSentenceService _sentenceService = AiSentenceService();

  List<WrongSentenceRecord> _records = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadRecords();
  }

  Future<void> _loadRecords() async {
    final records = await _sentenceService.getWrongSentences();
    if (mounted) {
      setState(() {
        _records = records;
        _isLoading = false;
      });
    }
  }

  // ===== 删除单个错题 =====
  Future<void> _removeRecord(WrongSentenceRecord record) async {
    await _sentenceService.removeWrongSentence(record.sentenceId);
    await _loadRecords();
  }

  // ===== 清空错题本 =====
  Future<void> _clearAll() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空错题本'),
        content: const Text('确定要清空所有错题吗？\n此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('清空'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _sentenceService.clearWrongSentences();
      await _loadRecords();
    }
  }

  // ===== 错题本练习 =====
  Future<void> _startPractice() async {
    if (_records.isEmpty) return;

    // 读取练习设置
    final practiceMode = await _sentenceService.getPracticeMode();
    final extraWordCount = await _sentenceService.getExtraWordCount();
    final sentenceLimit = await _sentenceService.getSentenceLimit();

    if (!mounted) return;

    // 将错题记录转换为 Sentence 对象
    final sentences = _records
        .map(
          (r) => Sentence(
            id: r.sentenceId,
            setId: r.setId,
            english: r.english,
            chinese: r.chinese,
          ),
        )
        .toList();

    await Navigator.of(context).push<dynamic>(
      MaterialPageRoute(
        builder: (_) => AiPracticeSessionPage(
          selectedSet: SentenceSet(name: '错题本'),
          practiceMode: practiceMode,
          extraWordCount: extraWordCount,
          sentenceLimit: sentenceLimit,
          wrongBookSentences: sentences,
          isWrongBookPractice: true,
        ),
      ),
    );

    // 练习完成后刷新（练习中可能移除了已掌握的错题）
    await _loadRecords();
  }

  // ===== UI 构建 =====
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('错题本'),
        centerTitle: false,
        actions: [
          if (_records.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: '清空错题本',
              onPressed: _clearAll,
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _records.isEmpty
          ? _buildEmptyState(theme, colorScheme)
          : _buildList(theme, colorScheme),
      floatingActionButton: _records.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: _startPractice,
              icon: const Icon(Icons.replay),
              label: const Text('错题本练习'),
            ),
    );
  }

  Widget _buildEmptyState(ThemeData theme, ColorScheme colorScheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.check_circle_outline,
              size: 80,
              color: colorScheme.primary.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 16),
            Text(
              '错题本为空',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '在句式集练习中得分较低的句子会自动加入这里',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(ThemeData theme, ColorScheme colorScheme) {
    return RefreshIndicator(
      onRefresh: _loadRecords,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
        itemCount: _records.length + 1,
        itemBuilder: (context, index) {
          if (index == _records.length) {
            // 底部留白（含练习按钮空间）
            return const SizedBox(height: 8);
          }
          return _buildRecordCard(_records[index], theme, colorScheme);
        },
      ),
    );
  }

  Widget _buildRecordCard(
    WrongSentenceRecord record,
    ThemeData theme,
    ColorScheme colorScheme,
  ) {
    final scoreColor = _scoreColor(record.score);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 顶部行：得分徽章 + 模式 + 时间 + 删除
            Row(
              children: [
                // 得分徽章
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: scoreColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: scoreColor),
                  ),
                  child: Text(
                    '${record.score} 分',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scoreColor,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // 练习模式
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    record.mode == PracticeMode.beginner ? '入门版' : '高阶版',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const Spacer(),
                // 时间
                Text(
                  _formatDate(record.createdAt),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                // 删除按钮
                IconButton(
                  icon: Icon(
                    Icons.delete_outline,
                    size: 20,
                    color: colorScheme.error,
                  ),
                  visualDensity: VisualDensity.compact,
                  tooltip: '移除该错题',
                  onPressed: () => _removeRecord(record),
                ),
              ],
            ),

            const SizedBox(height: 8),

            // 英文原句
            Text(
              record.english,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                height: 1.4,
              ),
            ),

            const SizedBox(height: 4),

            // 中文翻译
            Text(
              record.chinese,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),

            // 用户回答
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.5,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '你的回答：',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    record.userAnswer,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.error,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _scoreColor(int score) {
    if (score >= 7) return Colors.orange.shade700;
    if (score >= 5) return Colors.deepOrange;
    return Colors.red;
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(date.year, date.month, date.day);
    final diffDays = today.difference(that).inDays;

    if (diffDays == 0) {
      final h = date.hour.toString().padLeft(2, '0');
      final m = date.minute.toString().padLeft(2, '0');
      return '今天 $h:$m';
    } else if (diffDays == 1) {
      final h = date.hour.toString().padLeft(2, '0');
      final m = date.minute.toString().padLeft(2, '0');
      return '昨天 $h:$m';
    } else {
      final m = date.month.toString().padLeft(2, '0');
      final d = date.day.toString().padLeft(2, '0');
      return '$m-$d';
    }
  }
}
