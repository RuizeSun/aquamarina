import 'package:flutter/material.dart';
import '../../models/word_book.dart';
import '../../services/word_book_service.dart';
import 'import_words_dialog.dart';

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
  int _coverColor = 0xFF00BFA5;
  bool _isImporting = false;

  // 编辑模式下已存在的词汇列表
  List<String> _existingWords = [];
  bool _loadingWords = false;

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
      // 编辑模式：更新元数据
      await WordBookService.updateBook(
        widget.existingBook!.copyWith(
          title: title,
          description: _descriptionController.text.trim(),
          author: _authorController.text.trim(),
          coverColor: _coverColor,
        ),
      );

      // 如果有新的导入文本，追加词汇
      if (importText.isNotEmpty) {
        final result = await WordBookService.importWords(importText);

        if (mounted && result.missingWords.isNotEmpty) {
          final finalWords = await showDialog<List<String>>(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => ImportWordsDialog(
              missingWords: result.missingWords,
              importResult: result,
            ),
          );

          if (finalWords != null && widget.existingBook!.id != null) {
            await WordBookService.addWordsToBook(
              widget.existingBook!.id!,
              finalWords,
            );
          }
        } else if (widget.existingBook!.id != null) {
          await WordBookService.addWordsToBook(
            widget.existingBook!.id!,
            result.foundWords,
          );
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

  Future<void> _createBookAndImport(String title, List<String> words) async {
    final bookId = await WordBookService.createBook(
      WordBook(
        title: title,
        description: _descriptionController.text.trim(),
        author: _authorController.text.trim(),
        coverColor: _coverColor,
      ),
    );

    await WordBookService.addWordsToBook(bookId, words);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('成功创建词书 "$title"，共 ${words.length} 个词')),
      );
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _removeWord(String word) async {
    if (widget.existingBook?.id == null) return;
    await WordBookService.removeWordFromBook(widget.existingBook!.id!, word);
    _loadExistingWords();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? '编辑词书' : '创建词书'),
        actions: [
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
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
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
                          ? Border.all(color: colorScheme.onSurface, width: 3)
                          : null,
                      boxShadow: selected
                          ? [
                              BoxShadow(
                                color: Color(color).withValues(alpha: 0.4),
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
                    '${_existingWords.length} 词',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
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
              else
                ..._existingWords.map(
                  (word) => Container(
                    margin: const EdgeInsets.only(bottom: 4),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.abc, size: 16, color: colorScheme.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            word,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: Icon(
                            Icons.remove_circle_outline,
                            size: 20,
                            color: colorScheme.error,
                          ),
                          onPressed: () => _removeWord(word),
                          tooltip: '移除此词',
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
