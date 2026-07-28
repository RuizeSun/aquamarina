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
  }

  Future<void> _loadSettings() async {
    _extraWordCount = await _sentenceService.getExtraWordCount();
    _sentenceLimit = await _sentenceService.getSentenceLimit();
    _practiceMode = await _sentenceService.getPracticeMode();
  }

  // ===== 开始练习（跳转到新页面） =====
  Future<void> _startPractice() async {
    if (_selectedSet == null) return;

    final sentences = await _setService.getSentences(_selectedSet!.id!);
    if (sentences.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('该句式集没有句子，请先添加')));
      }
      return;
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
        ),
      ),
    );

    // 返回后刷新设置（可能用户在设置页修改了）
    await _loadSettings();
    if (mounted) setState(() {});
  }

  // ===== UI 构建 =====
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('AI 句子练习'), centerTitle: false),
      body: _buildBody(theme, colorScheme),
    );
  }

  Widget _buildBody(ThemeData theme, ColorScheme colorScheme) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    return _buildDashboard(theme, colorScheme);
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
            // 句式集选择
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
                          color: _selectedSet?.isBuiltin == true
                              ? colorScheme.primary
                              : colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          _selectedSet?.isBuiltin == true
                              ? Icons.auto_awesome
                              : Icons.format_quote,
                          color: _selectedSet?.isBuiltin == true
                              ? Colors.white
                              : colorScheme.onSecondaryContainer,
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
            const SizedBox(height: 32),

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
                      '练习模式、句数等请在「设置」中配置',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // 开始按钮
            SizedBox(
              width: double.infinity,
              height: 56,
              child: FilledButton.icon(
                onPressed: _selectedSet != null ? _startPractice : null,
                icon: const Icon(Icons.play_arrow_rounded),
                label: Text(
                  _selectedSet != null ? '开始练习' : '请先选择句式集',
                  style: const TextStyle(fontSize: 18),
                ),
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
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
  }
}
