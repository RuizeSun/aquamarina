import 'package:flutter/material.dart';
import '../../models/word_book.dart';
import '../../services/dictionary_service.dart';
import '../../services/word_book_service.dart';
import '../ai_sentence_set_list_page.dart';
import '../word_detail_page.dart';
import 'ai_sentence_set_generate_page.dart';
import 'import_words_dialog.dart';
import 'shared/word_book_word_list.dart';

class WordBookCreatePage extends StatefulWidget {
  final WordBook? existingBook;

  const WordBookCreatePage({super.key, this.existingBook});

  @override
  State<WordBookCreatePage> createState() => _WordBookCreatePageState();
}

class _WordBookCreatePageState extends State<WordBookCreatePage> {
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _authorController = TextEditingController();
  final _importController = TextEditingController();
  final _wordSearchController = TextEditingController();
  int _coverColor = 0xFF00BFA5;
  bool _isImporting = false;

  // 编辑模式下已存在的词汇列表
  List<String> _existingWords = [];
  bool _loadingWords = false;
  String _wordSearchQuery = '';

  // 多选模式（用于按词书调用 AI 生成句式集）
  bool _selectionMode = false;
  final Set<String> _selectedWords = {};

  static const _colorOptions = [
    0xFF00BFA5, // 青绿
    0xFF2196F3, // 蓝色
    0xFF9C27B0, // 紫色
    0xFFFF5722, // 深橙
    0xFF4CAF50, // 绿色
    0xFFFF9800, // 橙色
    0xFFE91E63, // 粉色
    0xFF607D8B, // 蓝灰
  ];

  bool get _isEditing => widget.existingBook != null;

  /// 根据搜索关键词过滤已存在词汇（大小写不敏感）
  List<String> get _filteredExistingWords {
    final query = _wordSearchQuery.trim().toLowerCase();
    if (query.isEmpty) return _existingWords;
    return _existingWords
        .where((w) => w.toLowerCase().contains(query))
        .toList();
  }

  @override
  void initState() {
    super.initState();
    if (widget.existingBook != null) {
      final book = widget.existingBook!;
      _titleController.text = book.title;
      _descriptionController.text = book.description ?? '';
      _authorController.text = book.author ?? '';
      _coverColor = book.coverColor ?? 0xFF00BFA5;
      _loadExistingWords();
    }
  }

  Future<void> _loadExistingWords() async {
    if (widget.existingBook?.id == null) return;
    setState(() => _loadingWords = true);
    final words = await WordBookService.getBookWords(widget.existingBook!.id!);
    if (mounted) {
      setState(() {
        _existingWords = words;
        _loadingWords = false;
      });
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _authorController.dispose();
    _importController.dispose();
    _wordSearchController.dispose();
    super.dispose();
  }

  Future<void> _onSave() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请输入词书标题')));
      return;
    }

    final importText = _importController.text.trim();
    if (importText.isEmpty && !_isEditing) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请粘贴要导入的词汇')));
      return;
    }

    if (_isEditing) {
      // 编辑模式：更新元数据（标题冲突时自动加序号，排除自身）
      final uniqueTitle = await WordBookService.generateUniqueBookTitle(
        title,
        excludeId: widget.existingBook!.id,
      );
      await WordBookService.updateBook(
        widget.existingBook!.copyWith(
          title: uniqueTitle,
          description: _descriptionController.text.trim(),
          author: _authorController.text.trim(),
          coverColor: _coverColor,
        ),
      );

      // 如果有新的导入文本，追加词汇
      if (importText.isNotEmpty) {
        final result = await WordBookService.importWords(importText);

        List<String> wordsToAdd;
        if (mounted && result.missingWords.isNotEmpty) {
          final finalWords = await showDialog<List<String>>(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => ImportWordsDialog(
              missingWords: result.missingWords,
              importResult: result,
            ),
          );

          if (finalWords == null) return;
          wordsToAdd = finalWords;
        } else {
          wordsToAdd = result.foundWords;
        }

        // 过滤已学单词（带用户确认）
        if (widget.existingBook!.id != null) {
          final filtered = await _filterLearnedWordsWithDialog(wordsToAdd);
          if (filtered == null) return;
          if (filtered.isNotEmpty) {
            await WordBookService.addWordsToBook(
              widget.existingBook!.id!,
              filtered,
            );
          }
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('词书已更新')));
        Navigator.of(context).pop(true);
      }
      return;
    }

    // 创建模式
    setState(() => _isImporting = true);

    try {
      final result = await WordBookService.importWords(importText);

      if (!mounted) return;

      if (result.missingWords.isNotEmpty) {
        final finalWords = await showDialog<List<String>>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => ImportWordsDialog(
            missingWords: result.missingWords,
            importResult: result,
          ),
        );

        if (finalWords == null) {
          setState(() => _isImporting = false);
          return;
        }

        await _createBookAndImport(title, finalWords);
      } else {
        await _createBookAndImport(title, result.foundWords);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导入失败: $e')));
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  /// 弹窗让用户选择是否过滤已学单词，返回用户确认后的单词列表
  Future<List<String>?> _filterLearnedWordsWithDialog(
    List<String> words,
  ) async {
    if (words.isEmpty) return words;
    final filtered = await WordBookService.filterLearnedWords(words);
    if (filtered.learnedWords.isEmpty) return words;

    if (!mounted) return null;
    final shouldFilter = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('发现已学单词'),
        content: Text(
          '待导入的词汇中有 ${filtered.learnedWords.length} 个单词已学过'
          '（${filtered.newWords.isEmpty ? "全部已学" : "其中 ${filtered.newWords.length} 个未学"}），'
          '是否过滤掉已学单词？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('不过滤'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('过滤'),
          ),
        ],
      ),
    );
    if (shouldFilter == null) return null;
    return shouldFilter ? filtered.newWords : words;
  }

  Future<void> _createBookAndImport(String title, List<String> words) async {
    // 过滤已学单词（带用户确认）
    final wordsToImport = await _filterLearnedWordsWithDialog(words);
    if (wordsToImport == null) return;
    if (wordsToImport.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('所有有效单词都已学过，无需创建词书')));
        Navigator.of(context).pop(true);
      }
      return;
    }

    // 名称冲突时自动加序号（类似 Windows 重命名）
    final uniqueTitle = await WordBookService.generateUniqueBookTitle(title);
    final bookId = await WordBookService.createBook(
      WordBook(
        title: uniqueTitle,
        description: _descriptionController.text.trim(),
        author: _authorController.text.trim(),
        coverColor: _coverColor,
      ),
    );

    await WordBookService.addWordsToBook(bookId, wordsToImport);

    if (mounted) {
      final skipped = words.length - wordsToImport.length;
      final parts = <String>[
        '成功创建词书 "$uniqueTitle"，共 ${wordsToImport.length} 个词',
      ];
      if (skipped > 0) {
        parts.add('（$skipped 个已学单词已跳过）');
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(parts.join())));
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _removeWord(String word) async {
    if (widget.existingBook?.id == null) return;
    await WordBookService.removeWordFromBook(widget.existingBook!.id!, word);
    if (!mounted) return;
    // 单词已从数据库删除，本地同步移除即可，
    // 无需重新查询整本书（避免再次整表刷新带来的卡顿）
    final target = word.trim().toLowerCase();
    setState(() {
      _existingWords = _existingWords
          .where((w) => w.toLowerCase() != target)
          .toList(growable: false);
      _selectedWords.removeWhere((w) => w.toLowerCase() == target);
    });
  }

  // ===== 多选（AI 生成句式集） =====

  void _toggleSelectionMode() {
    setState(() {
      _selectionMode = !_selectionMode;
      if (!_selectionMode) _selectedWords.clear();
    });
  }

  void _toggleWordSelection(String word) {
    setState(() {
      if (_selectedWords.contains(word)) {
        _selectedWords.remove(word);
      } else {
        _selectedWords.add(word);
      }
    });
  }

  /// 全选 / 取消全选：只作用于当前搜索过滤后的词表，
  /// 便于「搜索一段前缀 → 全选 → 生成」的用法。
  void _toggleSelectAll(List<String> filtered, bool select) {
    setState(() {
      if (select) {
        _selectedWords.addAll(filtered);
      } else {
        _selectedWords.removeAll(filtered);
      }
    });
  }

  /// 带着选中的单词进入 AI 生成句式集页面
  Future<void> _generateFromSelection() async {
    if (_selectedWords.isEmpty) return;
    // 按词书原始顺序排列，便于与提示词、生成结果核对
    final ordered = _existingWords
        .where(_selectedWords.contains)
        .toList(growable: false);
    final bookTitle = _titleController.text.trim().isEmpty
        ? '未命名词书'
        : _titleController.text.trim();

    final outcome = await Navigator.of(context)
        .push<SentenceSetGenerationOutcome>(
          MaterialPageRoute(
            builder: (_) =>
                AiSentenceSetGeneratePage(bookTitle: bookTitle, words: ordered),
          ),
        );
    if (!mounted || outcome == null) return;

    setState(() {
      _selectionMode = false;
      _selectedWords.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '已创建句式集「${outcome.setName}」，共 ${outcome.sentenceCount} 句',
        ),
        backgroundColor: Colors.green,
        behavior: SnackBarBehavior.floating,
      ),
    );

    // 生成完成后直接进入句式集管理界面，方便查看 / 编辑刚生成的句式集
    if (!mounted) return;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const SentenceSetListPage()));
  }

  /// 多选模式的底部操作条
  Widget _buildSelectionBar(ThemeData theme, ColorScheme colorScheme) {
    final filtered = _filteredExistingWords;
    final allSelected =
        filtered.isNotEmpty && filtered.every(_selectedWords.contains);

    return SafeArea(
      child: Material(
        color: colorScheme.surfaceContainerHigh,
        elevation: 8,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  TextButton(
                    onPressed: filtered.isEmpty
                        ? null
                        : () => _toggleSelectAll(filtered, !allSelected),
                    child: Text(allSelected ? '取消全选' : '全选'),
                  ),
                  Expanded(
                    child: Text(
                      _selectedWords.isEmpty
                          ? '点击词条以选择单词'
                          : '已选 ${_selectedWords.length} 个单词',
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: _selectedWords.isEmpty
                            ? colorScheme.onSurfaceVariant
                            : colorScheme.primary,
                        fontWeight: _selectedWords.isEmpty
                            ? FontWeight.normal
                            : FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _toggleSelectionMode,
                    child: const Text('退出选择'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _selectedWords.isEmpty
                      ? null
                      : _generateFromSelection,
                  icon: const Icon(Icons.auto_awesome, size: 18),
                  label: const Text('AI 生成句式集'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 打开单词详情页，展示完整释义
  Future<void> _openWordDetail(String word) async {
    final entry = await DictionaryService.searchEnExact(word);
    if (!mounted) return;
    if (entry == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('未找到「$word」的释义'),
          duration: const Duration(seconds: 1),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WordDetailPage(
          result: CombinedResult(enEntry: entry),
          word: word,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    // 每帧只过滤一次，避免在计数行与词表之间重复计算
    final filteredWords = _filteredExistingWords;
    // 词表行交给 SliverList 懒加载：仅在确有内容时才创建该 Sliver
    final showWordRows =
        _isEditing &&
        !_loadingWords &&
        _existingWords.isNotEmpty &&
        filteredWords.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? '编辑词书' : '创建词书'),
        actions: [
          // 选词入口：仅编辑已有词书且词表非空时可用。
          // 图标与词表区的「AI 生成句式集」卡片一致，明确指向 AI 功能。
          if (_isEditing && _existingWords.isNotEmpty && !_isImporting)
            IconButton(
              icon: Icon(
                _selectionMode ? Icons.close : Icons.auto_awesome,
                color: _selectionMode ? null : colorScheme.primary,
              ),
              tooltip: _selectionMode ? '退出选择' : 'AI 生成句式集（先选择单词）',
              onPressed: _toggleSelectionMode,
            ),
          TextButton(
            onPressed: _isImporting ? null : _onSave,
            child: _isImporting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('保存'),
          ),
        ],
      ),
      // 多选底部操作栏：进入 / 退出选择时以「高度展开 + 上滑 + 淡入」动画出现，
      // 避免整条栏突然出现造成的界面跳动。
      bottomNavigationBar: AnimatedSwitcher(
        duration: const Duration(milliseconds: 260),
        reverseDuration: const Duration(milliseconds: 200),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) => SizeTransition(
          sizeFactor: animation,
          // 从顶部展开（垂直方向），配合上滑形成「从底部升起」的观感
          alignment: Alignment.topCenter,
          child: FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 1),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          ),
        ),
        child: _selectionMode
            ? KeyedSubtree(
                key: const ValueKey('selection-bar'),
                child: _buildSelectionBar(theme, colorScheme),
              )
            : const SizedBox.shrink(key: ValueKey('selection-bar-hidden')),
      ),
      body: Material(
        // 页面级墨迹层：所有词表行的 Ink 装饰与水波都绘制在这一层
        type: MaterialType.transparency,
        child: CustomScrollView(
          slivers: [
            // 表单区（封面颜色 / 标题 / 描述 / 作者 / 导入 / 搜索 / 各种提示）
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              sliver: SliverList.list(
                children: [
                  // 封面颜色选择
                  Text('封面颜色', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: _colorOptions.map((color) {
                      final selected = _coverColor == color;
                      return GestureDetector(
                        onTap: () => setState(() => _coverColor = color),
                        child: Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: Color(color),
                            borderRadius: BorderRadius.circular(12),
                            border: selected
                                ? Border.all(
                                    color: colorScheme.onSurface,
                                    width: 3,
                                  )
                                : null,
                            boxShadow: selected
                                ? [
                                    BoxShadow(
                                      color: Color(
                                        color,
                                      ).withValues(alpha: 0.4),
                                      blurRadius: 8,
                                      offset: const Offset(0, 2),
                                    ),
                                  ]
                                : null,
                          ),
                          child: selected
                              ? Icon(Icons.check, color: Colors.white)
                              : null,
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 24),

                  // 标题
                  TextField(
                    controller: _titleController,
                    decoration: const InputDecoration(
                      labelText: '词书标题 *',
                      hintText: '例如：四级核心词汇',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // 描述
                  TextField(
                    controller: _descriptionController,
                    decoration: const InputDecoration(
                      labelText: '描述（可选）',
                      hintText: '词书简介...',
                      border: OutlineInputBorder(),
                    ),
                    maxLines: 2,
                  ),
                  const SizedBox(height: 16),

                  // 作者
                  TextField(
                    controller: _authorController,
                    decoration: const InputDecoration(
                      labelText: '作者（可选）',
                      hintText: '你的名字',
                      border: OutlineInputBorder(),
                    ),
                  ),

                  const SizedBox(height: 24),
                  const Divider(),
                  const SizedBox(height: 16),

                  // 导入/追加词汇
                  Text(
                    _isEditing ? '追加词汇' : '导入词汇',
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '一行一个单词，将从本地词典中校验',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _importController,
                    decoration: InputDecoration(
                      hintText: _isEditing
                          ? '输入新单词，一行一个...'
                          : 'apple\nbanana\ncat\n...',
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.all(16),
                    ),
                    maxLines: 6,
                    minLines: 3,
                    textInputAction: TextInputAction.newline,
                  ),

                  // 编辑模式下显示已有词汇列表
                  if (_isEditing) ...[
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Text('词表管理', style: theme.textTheme.titleSmall),
                        const Spacer(),
                        Text(
                          _wordSearchQuery.trim().isEmpty
                              ? '${_existingWords.length} 词'
                              : '${filteredWords.length} / ${_existingWords.length} 词',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // AI 生成句式集入口：用带图标与说明的卡片，而不是一个含义
                    // 不明的多选图标，让用户一眼看出这是 AI 功能
                    if (!_selectionMode && _existingWords.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Material(
                          color: colorScheme.primaryContainer.withValues(
                            alpha: 0.45,
                          ),
                          borderRadius: BorderRadius.circular(12),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: _toggleSelectionMode,
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Row(
                                children: [
                                  Container(
                                    width: 38,
                                    height: 38,
                                    decoration: BoxDecoration(
                                      color: colorScheme.primary.withValues(
                                        alpha: 0.15,
                                      ),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Icon(
                                      Icons.auto_awesome,
                                      size: 20,
                                      color: colorScheme.primary,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'AI 生成句式集',
                                          style: theme.textTheme.titleSmall
                                              ?.copyWith(
                                                fontWeight: FontWeight.w600,
                                              ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          '选择本词书中的单词，按 CEFR 难度'
                                          '（入门 ~ 自由运用）调用 AI 生成练习句式',
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                                color: colorScheme
                                                    .onSurfaceVariant,
                                              ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Icon(
                                    Icons.chevron_right,
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (_loadingWords)
                      const Center(child: CircularProgressIndicator())
                    else if (_existingWords.isEmpty)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '词书为空，在上方输入词汇后保存即可添加',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      )
                    else ...[
                      // 搜索框：客户端过滤词表
                      TextField(
                        controller: _wordSearchController,
                        decoration: InputDecoration(
                          hintText: '搜索词汇...',
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: _wordSearchQuery.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear),
                                  tooltip: '清空搜索',
                                  onPressed: () {
                                    _wordSearchController.clear();
                                    setState(() => _wordSearchQuery = '');
                                  },
                                )
                              : null,
                          isDense: true,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onChanged: (value) {
                          setState(() => _wordSearchQuery = value);
                        },
                      ),
                      // 搜索无结果时的空状态（词表行由下方的 SliverList 承载）
                      if (filteredWords.isEmpty) ...[
                        const SizedBox(height: 8),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(24),
                          decoration: BoxDecoration(
                            color: colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '未找到匹配的词汇',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ],
                  ],
                  // 搜索框与词表行之间保留 8px 间距（词表行由下方的 SliverList 承载）
                  if (showWordRows) const SizedBox(height: 8),
                  // 没有词表行时补足页面底部留白，保持与原布局一致的间距
                  if (!showWordRows) const SizedBox(height: 16),
                ],
              ),
            ),
            // 词表行：懒加载，只有可视区域内的行才会被构建与布局
            if (showWordRows)
              WordBookWordList(
                words: filteredWords,
                onTapWord: _openWordDetail,
                onRemoveWord: _removeWord,
                selectionMode: _selectionMode,
                selectedWords: _selectedWords,
                onToggleWord: _toggleWordSelection,
              ),
          ],
        ),
      ),
    );
  }
}
