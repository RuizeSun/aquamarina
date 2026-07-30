import 'package:flutter/material.dart';
import '../models/ai_sentence_set.dart';
import '../models/ai_sentence.dart';
import '../services/ai_sentence_set_service.dart';
import '../services/ai_sentence_service.dart';
import 'ai_sentence_set_list_page.dart';
import 'ai_practice_session_page.dart';

class AiPracticePage extends StatefulWidget {
  const AiPracticePage({super.key});

  @override
  State<AiPracticePage> createState() => _AiPracticePageState();
}

class _AiPracticePageState extends State<AiPracticePage> {
  final SentenceSetService _setService = SentenceSetService();
  final AiSentenceService _sentenceService = AiSentenceService();

  // 仪表盘状态
  bool _isLoading = true;

  // 可用的句式集
  List<SentenceSet> _availableSets = [];
  SentenceSet? _selectedSet;

  // 练习设置（从设置页读取）
  PracticeMode _practiceMode = PracticeMode.beginner;
  int _extraWordCount = 3;
  int _sentenceLimit = 10;

  // 错题本状态
  int _wrongSentenceCount = 0;

  // 进度状态
  int _practicedCount = 0;
  int _totalCount = 0;

  // 不重复练习开关
  bool _skipRepeated = false;

  @override
  void initState() {
    super.initState();
    _initData();
  }

  @override
  void dispose() {
    _setService.removeListener(_onSetsChanged);
    super.dispose();
  }

  void _onSetsChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _initData() async {
    setState(() => _isLoading = true);

    // 加载句式集
    await _setService.load();
    _setService.addListener(_onSetsChanged);

    // 加载设置
    await _loadSettings();

    if (mounted) {
      setState(() {
        _availableSets = _setService.sets;
        // 默认选中第一个句式集
        if (_availableSets.isNotEmpty && _selectedSet == null) {
          _selectedSet = _availableSets.first;
        }
        _isLoading = false;
      });
    }
    // 刷新进度和错题数量
    await _refreshProgress();
  }

  Future<void> _loadSettings() async {
    _extraWordCount = await _sentenceService.getExtraWordCount();
    _sentenceLimit = await _sentenceService.getSentenceLimit();
    _practiceMode = await _sentenceService.getPracticeMode();
    _skipRepeated = await _sentenceService.getSkipRepeated();
  }

  Future<void> _refreshProgress() async {
    // 获取错题数量
    final wrongCount = await _sentenceService.getWrongSentenceCount();
    // 获取当前句式集进度
    int practiced = 0;
    int total = 0;
    if (_selectedSet != null) {
      total = _selectedSet!.sentenceCount;
      final practicedIds = await _sentenceService.getPracticedSentenceIds(
        _selectedSet!.id!,
      );
      practiced = practicedIds.length;
    }
    if (mounted) {
      setState(() {
        _wrongSentenceCount = wrongCount;
        _practicedCount = practiced;
        _totalCount = total;
      });
    }
  }

  // ===== 开始句式集练习 =====
  Future<void> _startPractice({required bool isWrongBook}) async {
    // 重新加载最新设置（确保设置页的修改已生效）
    await _loadSettings();

    if (isWrongBook) {
      final wrongSentences = await _sentenceService.getWrongSentences();
      if (wrongSentences.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('错题本为空，请先进行句式集练习')));
        }
        return;
      }

      if (!mounted) return;

      // 将错题记录转换为 Sentence 对象
      final sentences = wrongSentences
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
            selectedSet: _selectedSet ?? SentenceSet(name: '错题本'),
            practiceMode: _practiceMode,
            extraWordCount: _extraWordCount,
            sentenceLimit: _sentenceLimit,
            wrongBookSentences: sentences,
            isWrongBookPractice: true,
          ),
        ),
      );

      await _refreshProgress();
      if (mounted) setState(() {});
      return;
    }

    if (_selectedSet == null) return;

    // 获取句式集所有句子
    final allSentences = await _setService.getSentences(_selectedSet!.id!);
    if (allSentences.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('该句式集没有句子，请先添加')));
      }
      return;
    }

    // 如果开启了"不重复练习"，过滤掉已练习的句子
    final skipRepeated = await _sentenceService.getSkipRepeated();
    List<Sentence> practiceSentences;
    if (skipRepeated) {
      final practicedIds = await _sentenceService.getPracticedSentenceIds(
        _selectedSet!.id!,
      );
      practiceSentences = allSentences
          .where((s) => !practicedIds.contains(s.id))
          .toList();
      if (practiceSentences.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('该句式集所有句子已练习完成，可关闭"不重复练习"重试')),
          );
        }
        return;
      }
    } else {
      practiceSentences = allSentences;
    }

    if (!mounted) return;

    // 跳转到练习会话页面
    await Navigator.of(context).push<dynamic>(
      MaterialPageRoute(
        builder: (_) => AiPracticeSessionPage(
          selectedSet: _selectedSet!,
          practiceMode: _practiceMode,
          extraWordCount: _extraWordCount,
          sentenceLimit: _sentenceLimit,
          preFilteredSentences: practiceSentences,
        ),
      ),
    );

    // 返回后刷新数据
    await _loadSettings();
    await _refreshProgress();
    if (mounted) setState(() {});
  }

  // ===== UI 构建 =====
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('句型练习'), centerTitle: false),
      body: _buildBody(theme, colorScheme),
    );
  }

  Widget _buildBody(ThemeData theme, ColorScheme colorScheme) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_selectedSet == null) {
      return _buildNoSetState(theme, colorScheme);
    }

    return _buildDashboard(theme, colorScheme);
  }

  Widget _buildNoSetState(ThemeData theme, ColorScheme colorScheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.format_quote_rounded,
              size: 80,
              color: colorScheme.primary.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 16),
            Text(
              '还没有句型集',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '请先创建或从在线资源库中添加一个句型集',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _openSetSelector,
              icon: const Icon(Icons.add),
              label: const Text('添加句型集'),
            ),
          ],
        ),
      ),
    );
  }

  // ===== 仪表盘 =====
  Widget _buildDashboard(ThemeData theme, ColorScheme colorScheme) {
    final modeLabel = _practiceMode == PracticeMode.beginner ? '入门版' : '高阶版';

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ---- 句式集区域 ----
            Text('句式集', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Card(
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: _openSetSelector,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          Icons.format_quote,
                          color: colorScheme.onSecondaryContainer,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _selectedSet?.name ?? '请选择句式集',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (_selectedSet != null)
                              Text(
                                '${_selectedSet!.sentenceCount} 句 · $modeLabel',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right),
                    ],
                  ),
                ),
              ),
            ),

            // 句式集练习进度（不重复练习开启时不显示）
            if (_selectedSet != null && _totalCount > 0 && !_skipRepeated) ...[
              const SizedBox(height: 12),
              _buildProgressRow(
                theme: theme,
                colorScheme: colorScheme,
                icon: Icons.menu_book_rounded,
                label: '句式集练习',
                current: _practicedCount,
                total: _totalCount,
              ),
            ],

            const SizedBox(height: 20),

            // ---- 错题本区域 ----
            Row(
              children: [
                Icon(Icons.error_outline, color: colorScheme.error, size: 20),
                const SizedBox(width: 6),
                Text('错题本', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 8),
            Card(
              color: colorScheme.errorContainer.withValues(alpha: 0.3),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: colorScheme.error.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.format_list_numbered,
                        color: colorScheme.error,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '错题本',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            _wrongSentenceCount > 0
                                ? '$_wrongSentenceCount 道错题待练习'
                                : '暂无错题',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 12),

            // ---- 两个练习按钮 ----
            SizedBox(
              width: double.infinity,
              height: 56,
              child: FilledButton.icon(
                onPressed: _selectedSet != null
                    ? () => _startPractice(isWrongBook: false)
                    : null,
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('句式集练习', style: TextStyle(fontSize: 18)),
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: OutlinedButton.icon(
                onPressed: _wrongSentenceCount > 0
                    ? () => _startPractice(isWrongBook: true)
                    : null,
                icon: const Icon(Icons.replay),
                label: const Text('错题本练习', style: TextStyle(fontSize: 18)),
                style: OutlinedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 24),

            // 设置提示
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 16,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '练习模式、句数、错题本等请在「设置」中配置',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
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

  /// 构建进度行
  Widget _buildProgressRow({
    required ThemeData theme,
    required ColorScheme colorScheme,
    required IconData icon,
    required String label,
    required int current,
    required int total,
  }) {
    final progress = total > 0 ? current / total : 0.0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 20, color: colorScheme.primary),
            const SizedBox(width: 8),
            Text(label, style: theme.textTheme.bodyMedium),
            const Spacer(),
            Text(
              '$current / $total',
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: colorScheme.primary,
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 80,
              child: LinearProgressIndicator(
                value: progress,
                borderRadius: BorderRadius.circular(4),
                minHeight: 6,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openSetSelector() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SentenceSetListPage(
          currentSetId: _selectedSet?.id,
          onSetSelected: (set) {
            setState(() => _selectedSet = set);
          },
        ),
      ),
    );
    // 刷新可用句式集
    final sets = _setService.sets;
    setState(() {
      _availableSets = sets;
      if (_selectedSet != null) {
        // 如果当前选中的句式集被删除了，重置
        if (!_availableSets.any((s) => s.id == _selectedSet!.id)) {
          _selectedSet = _availableSets.isNotEmpty
              ? _availableSets.first
              : null;
        }
      }
    });
    await _refreshProgress();
  }
}
