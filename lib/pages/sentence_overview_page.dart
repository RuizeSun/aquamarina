import 'package:flutter/material.dart';
import '../models/ai_sentence.dart';
import '../services/ai_sentence_service.dart';
import '../services/ai_sentence_set_service.dart';
import 'shared/dashboard_widgets.dart';

/// 句型总览页：查看某个句式集的全部句子，并标注练习状态。
///
/// 与「单词总览」对应，是句型练习页的功能入口页之一。
class SentenceOverviewPage extends StatefulWidget {
  const SentenceOverviewPage({
    super.key,
    required this.setId,
    required this.setName,
  });

  final String setId;
  final String setName;

  @override
  State<SentenceOverviewPage> createState() => _SentenceOverviewPageState();
}

class _SentenceOverviewPageState extends State<SentenceOverviewPage> {
  final SentenceSetService _setService = SentenceSetService.instance;
  final AiSentenceService _sentenceService = AiSentenceService();
  final TextEditingController _searchController = TextEditingController();

  List<Sentence> _sentences = [];

  /// 已练过（不论对错）的句子 ID
  Set<String> _attemptedIds = {};

  /// 已答对（得分超过阈值）的句子 ID
  Set<String> _practicedIds = {};
  String _searchQuery = '';
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSentences();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadSentences() async {
    final sentences = await _setService.getSentences(widget.setId);
    final attempted = await _sentenceService.getAttemptedSentenceIds(
      widget.setId,
    );
    final practiced = await _sentenceService.getPracticedSentenceIds(
      widget.setId,
    );
    if (!mounted) return;
    setState(() {
      _sentences = sentences;
      _attemptedIds = attempted;
      _practicedIds = practiced;
      _isLoading = false;
    });
  }

  /// 客户端过滤（英文原句 / 中文释义，大小写不敏感）
  List<Sentence> get _filteredSentences {
    final query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) return _sentences;
    return _sentences
        .where(
          (s) =>
              s.english.toLowerCase().contains(query) ||
              s.chinese.toLowerCase().contains(query),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('句型总览'), centerTitle: false),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _sentences.isEmpty
          ? const DashboardEmptyState(
              icon: Icons.format_quote_rounded,
              title: '还没有句子',
              message: '该句式集暂时没有句子，请在句式集编辑页添加',
            )
          : _buildContent(),
    );
  }

  Widget _buildContent() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final sentences = _filteredSentences;

    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            DashboardMetrics.pagePadding.left,
            DashboardMetrics.pagePadding.top,
            DashboardMetrics.pagePadding.right,
            0,
          ),
          child: Column(
            children: [
              // 句式集信息面板
              DashboardPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.setName,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '共 ${_sentences.length} 句 · 已练过 ${_attemptedIds.length} 句 · '
                      '已答对 ${_practicedIds.length} 句',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: DashboardMetrics.itemGap),
              // 搜索框
              TextField(
                controller: _searchController,
                onChanged: (value) => setState(() => _searchQuery = value),
                decoration: InputDecoration(
                  hintText: '搜索英文原句或中文释义',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _searchQuery.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear),
                          tooltip: '清除',
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _searchQuery = '');
                          },
                        ),
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(
                      DashboardMetrics.radius,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: DashboardMetrics.itemGap),
        Expanded(
          child: sentences.isEmpty
              ? Center(
                  child: Text(
                    '没有匹配的句子',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _loadSentences,
                  child: ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: EdgeInsets.fromLTRB(
                      DashboardMetrics.pagePadding.left,
                      0,
                      DashboardMetrics.pagePadding.right,
                      DashboardMetrics.pagePadding.bottom,
                    ),
                    itemCount: sentences.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: DashboardMetrics.itemGap),
                    itemBuilder: (context, index) {
                      final sentence = sentences[index];
                      return _buildSentenceCard(
                        theme,
                        colorScheme,
                        index: index,
                        sentence: sentence,
                        attempted: _attemptedIds.contains(sentence.id),
                        passed: _practicedIds.contains(sentence.id),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildSentenceCard(
    ThemeData theme,
    ColorScheme colorScheme, {
    required int index,
    required Sentence sentence,
    required bool attempted,
    required bool passed,
  }) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 序号
            SizedBox(
              width: 28,
              child: Text(
                '${index + 1}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    sentence.english,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    sentence.chinese,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            // 已答对显示对勾；只是练过（答错）显示文字标签
            if (passed || attempted) ...[
              const SizedBox(width: 12),
              if (passed)
                Icon(Icons.check_circle, size: 20, color: colorScheme.primary)
              else
                Text(
                  '已练过',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
