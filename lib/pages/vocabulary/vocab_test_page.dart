import 'dart:math';
import 'package:flutter/material.dart';
import '../../models/word_entry.dart';
import '../../models/word_book.dart';
import '../../services/dictionary_service.dart';
import '../../services/learning_service.dart';
import '../../services/word_book_service.dart';
import '../../services/study_timer_service.dart';
import 'shared/data_loader.dart';
import 'shared/quiz_widget.dart';
import 'shared/word_utils.dart';

/// 词汇测试页面：测试已掌握词汇的实际掌握情况。
///
/// 包含三个阶段：
/// 1. 配置阶段 - 选择测试数量和可选词书筛选
/// 2. 测试阶段 - 选择题形式逐词测试
/// 3. 结果阶段 - 展示统计并提供后续操作
class VocabTestPage extends StatefulWidget {
  const VocabTestPage({super.key});

  @override
  State<VocabTestPage> createState() => _VocabTestPageState();
}

class _VocabTestPageState extends State<VocabTestPage>
    with SingleTickerProviderStateMixin {
  // ─── 配置阶段状态 ─────────────────────────────
  int _selectedCount = 20;
  int? _selectedBookId;
  List<Map<String, dynamic>> _books = [];
  int _masteredCount = 0;
  bool _isLoadingConfig = true;

  // 自定义数量输入
  final TextEditingController _customCountController = TextEditingController();

  // ─── 测试阶段状态 ─────────────────────────────
  List<String> _testWords = [];
  int _currentIndex = 0;
  bool _isLoadingTest = false;

  // 选择题状态
  List<String> _quizOptions = [];
  int _correctOptionIndex = -1;
  int? _selectedQuizOption;
  bool _quizAnswered = false;

  // 释义缓存
  final Map<int, WordEntry?> _entryCache = {};

  // 干扰项池
  final Map<String, String> _distractorPool = {};

  // 测试结果：word → true(正确) / false(错误)
  final Map<String, bool> _testResults = {};

  // 是否已确认退出
  bool _isExiting = false;

  // ─── 结果阶段状态 ─────────────────────────────
  // 错误单词的释义
  final Map<String, String> _wrongWordMeanings = {};

  // 阶段: 0=配置, 1=测试, 2=结果
  int _phase = 0;

  late AnimationController _animController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _animController,
      curve: Curves.easeInOut,
    );
    _animController.forward();
    _loadConfigData();
  }

  @override
  void dispose() {
    // 结束学习时长计时
    StudyTimerService.instance.endSession();
    _customCountController.dispose();
    _animController.dispose();
    super.dispose();
  }

  // ─── 配置阶段 ─────────────────────────────────

  Future<void> _loadConfigData() async {
    setState(() => _isLoadingConfig = true);
    try {
      final books = await WordBookService.getAllBooks();
      final masteredWords = await LearningService.getMasteredWordsForTest();
      if (mounted) {
        setState(() {
          _books = books.map((b) => {'id': b.id, 'title': b.title}).toList();
          _masteredCount = masteredWords.length;
          _isLoadingConfig = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoadingConfig = false);
    }
  }

  Future<void> _loadMasteredCountForBook(int? bookId) async {
    final words = await LearningService.getMasteredWordsForTest(bookId: bookId);
    if (mounted) {
      setState(() => _masteredCount = words.length);
    }
  }

  int get _effectiveCount {
    if (_selectedCount <= 0) return _masteredCount;
    return min(_selectedCount, _masteredCount);
  }

  // ─── 开始测试 ─────────────────────────────────

  Future<void> _startTest() async {
    if (_masteredCount == 0) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('没有已掌握的单词可供测试')));
      }
      return;
    }

    setState(() => _isLoadingTest = true);

    try {
      final count = _effectiveCount;
      final data = await LearningService.getMasteredWordsForTest(
        count: count,
        bookId: _selectedBookId,
      );

      if (data.isEmpty) {
        if (mounted) {
          setState(() => _isLoadingTest = false);
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('没有已掌握的单词可供测试')));
        }
        return;
      }

      _testWords = data.map((m) => m['word'] as String).toList();

      // 加载释义
      _entryCache.clear();
      _entryCache.addAll(await loadEntries(words: _testWords));

      // 加载干扰项池
      _distractorPool.clear();
      _distractorPool.addAll(
        await loadDistractorPool(excludeWords: _testWords),
      );

      if (mounted) {
        setState(() {
          _phase = 1;
          _currentIndex = 0;
          _testResults.clear();
          _isLoadingTest = false;
        });
        // 启动学习时长计时
        StudyTimerService.instance.startSession(SessionType.vocabTest);
        _generateQuizOptions();
      }
    } catch (e) {
      if (mounted) setState(() => _isLoadingTest = false);
    }
  }

  // ─── 测试阶段 ─────────────────────────────────

  Future<void> _generateQuizOptions() async {
    final entry = _entryCache[_currentIndex];
    final correctMeaning = extractFirstMeaning(entry?.translation);

    if (correctMeaning.isEmpty) {
      // 无释义，标记为正确并跳过
      _testResults[_testWords[_currentIndex]] = true;
      _advanceToNext();
      return;
    }

    final allOtherMeanings = <String>[];
    for (int i = 0; i < _testWords.length; i++) {
      if (i == _currentIndex) continue;
      final e = _entryCache[i];
      final m = extractFirstMeaning(e?.translation);
      if (m.isNotEmpty && m != correctMeaning) {
        allOtherMeanings.add(m);
      }
    }

    allOtherMeanings.shuffle(Random());
    final distractors = allOtherMeanings.take(3).toList();

    if (distractors.length < 3) {
      final poolEntries = _distractorPool.values.toList()..shuffle(Random());
      for (final m in poolEntries) {
        if (distractors.length >= 3) break;
        final extracted = extractFirstMeaning(m);
        if (extracted.isNotEmpty &&
            extracted != correctMeaning &&
            !distractors.contains(extracted)) {
          distractors.add(extracted);
        }
      }
    }

    var attempts = 0;
    while (distractors.length < 3 && attempts < 5) {
      attempts++;
      final randomWord = await LearningService.getRandomDistractorWord(
        _testWords,
      );
      if (randomWord == null) break;
      final e = await DictionaryService.searchEnExact(randomWord);
      final m = extractFirstMeaning(e?.translation);
      if (m.isNotEmpty && m != correctMeaning && !distractors.contains(m)) {
        distractors.add(m);
      }
    }

    final options = [correctMeaning, ...distractors];
    options.shuffle(Random());

    if (!mounted) return;
    setState(() {
      _quizOptions = options;
      _correctOptionIndex = options.indexOf(correctMeaning);
      _selectedQuizOption = null;
      _quizAnswered = false;
    });
    _animController.forward(from: 0);
  }

  void _onQuizSelect(int optionIndex) {
    if (_quizAnswered) return;
    setState(() {
      _selectedQuizOption = optionIndex;
      _quizAnswered = true;
    });
    // 记录结果
    final isCorrect = optionIndex == _correctOptionIndex;
    _testResults[_testWords[_currentIndex]] = isCorrect;
  }

  void _onNextWord() {
    _advanceToNext();
  }

  void _advanceToNext() {
    if (_currentIndex >= _testWords.length - 1) {
      _finishTest();
    } else {
      setState(() {
        _currentIndex++;
      });
      _generateQuizOptions();
    }
  }

  Future<void> _finishTest() async {
    setState(() => _isLoadingTest = true);

    // 收集错误单词的释义
    _wrongWordMeanings.clear();
    for (final entry in _testResults.entries) {
      if (!entry.value) {
        final idx = _testWords.indexOf(entry.key);
        final wordEntry = idx >= 0 ? _entryCache[idx] : null;
        final meaning = extractFirstMeaning(wordEntry?.translation);
        _wrongWordMeanings[entry.key] = meaning.isEmpty ? '（无释义）' : meaning;
      }
    }

    // 保存测试历史记录（正确率、测试数量等）
    final total = _testResults.length;
    final correctCount = _testResults.values.where((v) => v).length;
    // 查询当前筛选词书的标题
    String? bookTitle;
    if (_selectedBookId != null) {
      for (final b in _books) {
        if (b['id'] == _selectedBookId) {
          bookTitle = b['title'] as String;
          break;
        }
      }
    }
    try {
      await LearningService.saveVocabTestResult(
        totalCount: total,
        correctCount: correctCount,
        bookId: _selectedBookId,
        bookTitle: bookTitle,
      );
    } catch (e) {
      // 保存失败不影响测试结果展示
      debugPrint('saveVocabTestResult failed: $e');
    }

    if (mounted) {
      setState(() {
        _phase = 2;
        _isLoadingTest = false;
      });
      _animController.forward(from: 0);
    }
  }

  // ─── 结果阶段操作 ─────────────────────────────

  Future<void> _doNothing() async {
    Navigator.of(context).pop();
  }

  Future<void> _addToExistingBook() async {
    final wrongWords = _wrongWordMeanings.keys.toList();
    if (wrongWords.isEmpty) return;

    // 弹出词书选择
    final books = await WordBookService.getAllBooks();
    if (!mounted || books.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('没有可用的词书')));
      }
      return;
    }

    final selectedBook = await showDialog<WordBook>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('选择词书'),
        children: books
            .map(
              (book) => SimpleDialogOption(
                onPressed: () => Navigator.of(ctx).pop(book),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(book.title, style: const TextStyle(fontSize: 16)),
                ),
              ),
            )
            .toList(),
      ),
    );

    if (selectedBook == null || !mounted) return;

    // 确认提示
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认加入词书'),
        content: Text(
          '将 ${wrongWords.length} 个未记住的单词加入「${selectedBook.title}」。\n\n'
          '⚠️ 如果词书中已有该单词，将覆盖原有学习记录。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确定'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    // 重置学习状态并加入词书
    await LearningService.resetMasteredBatch(wrongWords);
    await WordBookService.addWordsToBook(selectedBook.id!, wrongWords);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已将 ${wrongWords.length} 个单词加入「${selectedBook.title}」'),
      ),
    );
    Navigator.of(context).pop();
  }

  Future<void> _createNewBook() async {
    final wrongWords = _wrongWordMeanings.keys.toList();
    if (wrongWords.isEmpty) return;

    final nameController = TextEditingController(
      text: '词汇测试 ${DateTime.now().month}/${DateTime.now().day}',
    );

    final bookName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建词书'),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '词书名称',
            hintText: '请输入词书名称',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(nameController.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );

    nameController.dispose();

    if (bookName == null || bookName.isEmpty || !mounted) return;

    // 生成唯一标题
    final uniqueTitle = await WordBookService.generateUniqueBookTitle(bookName);

    // 创建词书
    final book = WordBook(title: uniqueTitle, description: '词汇测试中未记住的单词');
    final bookId = await WordBookService.createBook(book);

    // 重置学习状态并加入词书
    await LearningService.resetMasteredBatch(wrongWords);
    await WordBookService.addWordsToBook(bookId, wrongWords);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已创建词书「$uniqueTitle」并加入 ${wrongWords.length} 个单词'),
      ),
    );
    Navigator.of(context).pop();
  }

  // ─── 退出确认 ─────────────────────────────────

  Future<bool> _confirmExit() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出测试'),
        content: const Text('退出后本次测试结果将不保留，确定退出吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('继续测试'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _handleExit() async {
    if (_isExiting) return;
    final shouldExit = await _confirmExit();
    if (shouldExit && mounted) {
      _isExiting = true;
      Navigator.of(context).pop();
    }
  }

  // ─── UI 构建 ──────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    if (_isLoadingTest) {
      return Scaffold(
        appBar: AppBar(title: const Text('词汇测试')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return PopScope(
      canPop: _phase == 0 || _phase == 2,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop || _isExiting) return;
        await _handleExit();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            _phase == 0
                ? '词汇测试'
                : _phase == 1
                ? '${_currentIndex + 1}/${_testWords.length}'
                : '测试结果',
          ),
          leading: _phase == 1
              ? IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).maybePop(),
                )
              : null,
        ),
        body: FadeTransition(
          opacity: _fadeAnimation,
          child: _buildCurrentPhase(theme, colorScheme),
        ),
      ),
    );
  }

  Widget _buildCurrentPhase(ThemeData theme, ColorScheme colorScheme) {
    switch (_phase) {
      case 0:
        return _buildConfigPhase(theme, colorScheme);
      case 1:
        return _buildTestPhase(theme, colorScheme);
      case 2:
        return _buildResultPhase(theme, colorScheme);
      default:
        return const SizedBox.shrink();
    }
  }

  // ─── 配置阶段 UI ──────────────────────────────

  Widget _buildConfigPhase(ThemeData theme, ColorScheme colorScheme) {
    if (_isLoadingConfig) {
      return const Center(child: CircularProgressIndicator());
    }

    final presetCounts = [10, 20, 30, 50];

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 说明
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(Icons.quiz, color: colorScheme.primary, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '从已掌握的单词中随机抽取，以选择题形式测试你的真实掌握情况。',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // 已掌握单词数量
          Text(
            '已掌握单词',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '共 $_masteredCount 个',
            style: theme.textTheme.headlineSmall?.copyWith(
              color: colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 24),

          // 词书筛选
          Text(
            '词书筛选（可选）',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 42,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: const Text('全部'),
                    selected: _selectedBookId == null,
                    onSelected: (_) {
                      setState(() => _selectedBookId = null);
                      _loadMasteredCountForBook(null);
                    },
                  ),
                ),
                for (final book in _books)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(book['title'] as String),
                      selected: _selectedBookId == book['id'],
                      onSelected: (_) {
                        setState(() => _selectedBookId = book['id'] as int);
                        _loadMasteredCountForBook(book['id'] as int);
                      },
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // 测试数量
          Text(
            '测试数量',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final count in presetCounts)
                ChoiceChip(
                  label: Text('$count 词'),
                  selected: _selectedCount == count,
                  onSelected: _masteredCount >= count
                      ? (_) {
                          setState(() => _selectedCount = count);
                        }
                      : null,
                ),
              ChoiceChip(
                label: Text(
                  _selectedCount > 0 && !presetCounts.contains(_selectedCount)
                      ? '$_selectedCount 词'
                      : '自定义',
                ),
                selected:
                    _selectedCount > 0 &&
                    !presetCounts.contains(_selectedCount),
                onSelected: (_) => _showCustomCountDialog(),
              ),
              ChoiceChip(
                label: const Text('全部'),
                selected: _selectedCount <= 0,
                onSelected: _masteredCount > 0
                    ? (_) {
                        setState(() => _selectedCount = 0);
                      }
                    : null,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '将测试 $_effectiveCount 个单词',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 32),

          // 开始按钮
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _masteredCount > 0 ? _startTest : null,
              icon: const Icon(Icons.play_arrow),
              label: const Text('开始测试', style: TextStyle(fontSize: 16)),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showCustomCountDialog() async {
    _customCountController.text = '';
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('自定义测试数量'),
        content: TextField(
          controller: _customCountController,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(hintText: '请输入数量（1-$_masteredCount）'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final count = int.tryParse(_customCountController.text);
              if (count != null && count > 0) {
                Navigator.of(ctx).pop(count);
              }
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );

    if (result != null && mounted) {
      setState(() => _selectedCount = result);
    }
  }

  // ─── 测试阶段 UI ──────────────────────────────

  Widget _buildTestPhase(ThemeData theme, ColorScheme colorScheme) {
    return Column(
      children: [
        // 进度条
        TweenAnimationBuilder<double>(
          tween: Tween(
            begin: 0,
            end: (_currentIndex + (_quizAnswered ? 1 : 0)) / _testWords.length,
          ),
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          builder: (context, value, _) => LinearProgressIndicator(value: value),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Expanded(
                  child: _quizOptions.isEmpty
                      ? const Center(child: CircularProgressIndicator())
                      : QuizPhaseView(
                          word: _testWords[_currentIndex],
                          options: _quizOptions,
                          correctOptionIndex: _correctOptionIndex,
                          selectedOption: _selectedQuizOption,
                          isAnswered: _quizAnswered,
                          hintText: '选择正确的中文意思：',
                          onSelect: _onQuizSelect,
                        ),
                ),
                // 底部按钮
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _quizAnswered ? _onNextWord : null,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    child: Text(
                      _currentIndex >= _testWords.length - 1 ? '查看结果' : '下一题',
                      style: const TextStyle(fontSize: 16),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ─── 结果阶段 UI ──────────────────────────────

  Widget _buildResultPhase(ThemeData theme, ColorScheme colorScheme) {
    final total = _testResults.length;
    final correctCount = _testResults.values.where((v) => v).length;
    final wrongCount = total - correctCount;
    final accuracy = total > 0 ? (correctCount / total * 100).round() : 0;

    final wrongWords = _wrongWordMeanings.keys.toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 结果标题
          Center(
            child: Column(
              children: [
                Icon(
                  accuracy >= 80 ? Icons.emoji_events : Icons.school,
                  size: 64,
                  color: accuracy >= 80 ? Colors.amber : colorScheme.primary,
                ),
                const SizedBox(height: 12),
                Text(
                  '测试完成！',
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
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                _buildStatRow(theme, '测试总数', '$total 词'),
                const SizedBox(height: 8),
                _buildStatRow(theme, '正确', '$correctCount 词'),
                const SizedBox(height: 8),
                _buildStatRow(theme, '错误', '$wrongCount 词'),
                const Divider(height: 24),
                _buildStatRow(
                  theme,
                  '正确率',
                  '$accuracy%',
                  valueColor: accuracy >= 80 ? Colors.green : Colors.red,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // 错误单词列表
          if (wrongWords.isNotEmpty) ...[
            Text(
              '未记住的单词（${wrongWords.length}）',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            ...wrongWords.map((word) {
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              word,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _wrongWordMeanings[word] ?? '',
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
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          '未记住',
                          style: theme.textTheme.labelMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: colorScheme.onErrorContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
            const SizedBox(height: 16),
          ],

          // 操作按钮
          if (wrongWords.isNotEmpty) ...[
            Text(
              '如何处理未记住的单词？',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _addToExistingBook,
                icon: const Icon(Icons.playlist_add),
                label: const Text('加入现有词书'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _createNewBook,
                icon: const Icon(Icons.create_new_folder),
                label: const Text('新建词书'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: _doNothing,
                child: const Text('不做处理'),
              ),
            ),
          ] else ...[
            // 全部正确
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
              ),
              child: Column(
                children: [
                  const Icon(Icons.check_circle, size: 48, color: Colors.green),
                  const SizedBox(height: 8),
                  Text(
                    '全部正确！你的词汇掌握得非常好！',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: Colors.green.shade700,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _doNothing,
                child: const Text('完成'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStatRow(
    ThemeData theme,
    String label,
    String value, {
    Color? valueColor,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: theme.textTheme.bodyMedium),
        Text(
          value,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: valueColor,
          ),
        ),
      ],
    );
  }
}
