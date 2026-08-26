import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../models/ai_sentence_set.dart';
import '../models/ai_sentence.dart';
import '../services/ai_sentence_set_service.dart';
import '../widgets/sentence_note_bar.dart';

class SentenceSetEditPage extends StatefulWidget {
  final SentenceSet? existingSet;
  final SentenceSetService? setService;

  const SentenceSetEditPage({super.key, this.existingSet, this.setService});

  @override
  State<SentenceSetEditPage> createState() => _SentenceSetEditPageState();
}

class _SentenceSetEditPageState extends State<SentenceSetEditPage> {
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _englishController = TextEditingController();
  final _chineseController = TextEditingController();
  final _extraWordsController = TextEditingController();

  late SentenceSetService _setService;
  List<Sentence> _sentences = [];
  bool _isLoading = false;
  bool _isAddingSentence = false;

  bool get _isEditing => widget.existingSet != null;
  String get _setId => widget.existingSet?.id ?? '';

  @override
  void initState() {
    super.initState();
    _setService = widget.setService ?? SentenceSetService.instance;
    if (widget.existingSet != null) {
      _nameController.text = widget.existingSet!.name;
      _descriptionController.text = widget.existingSet!.description ?? '';
      _loadSentences();
    }
  }

  Future<void> _loadSentences() async {
    if (_setId.isEmpty) return;
    setState(() => _isLoading = true);
    final sentences = await _setService.getSentences(_setId);
    if (mounted) {
      setState(() {
        _sentences = sentences;
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _englishController.dispose();
    _chineseController.dispose();
    _extraWordsController.dispose();
    super.dispose();
  }

  Future<void> _onSave() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请输入句式集名称')));
      return;
    }

    if (_isEditing) {
      // 编辑模式：标题冲突时排除自身
      final uniqueName = _setService.generateUniqueSetName(name);
      await _setService.updateSet(
        widget.existingSet!.copyWith(
          name: uniqueName,
          description: _descriptionController.text.trim(),
        ),
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('句式集已更新')));
        Navigator.of(context).pop(true);
      }
    } else {
      // 创建模式：名称冲突时自动加序号
      final uniqueName = _setService.generateUniqueSetName(name);
      await _setService.addSet(
        SentenceSet(
          name: uniqueName,
          description: _descriptionController.text.trim(),
        ),
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('句式集已创建')));
        Navigator.of(context).pop(true);
      }
    }
  }

  Future<void> _addSentence() async {
    final english = _englishController.text.trim();
    final chinese = _chineseController.text.trim();
    if (english.isEmpty || chinese.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请输入英文原句和中文翻译')));
      return;
    }

    // 解析多余词
    final extraWords = _extraWordsController.text
        .trim()
        .split(RegExp(r'[\s,，、]+'))
        .where((w) => w.isNotEmpty)
        .toList();

    // 需要先创建句式集获取 ID
    String setId = _setId;
    if (setId.isEmpty) {
      final tempName = _nameController.text.trim();
      if (tempName.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('请先输入句式集名称')));
        return;
      }
      setId = const Uuid().v4();
      final uniqueName = _setService.generateUniqueSetName(tempName);
      await _setService.addSet(
        SentenceSet(
          id: setId,
          name: uniqueName,
          description: _descriptionController.text.trim(),
        ),
      );
      if (mounted) {
        setState(() {
          widget.existingSet?.id;
        });
      }
    }

    await _setService.addSentence(
      Sentence(
        setId: setId,
        english: english,
        chinese: chinese,
        extraWords: extraWords,
      ),
    );

    _englishController.clear();
    _chineseController.clear();
    _extraWordsController.clear();
    setState(() => _isAddingSentence = false);
    if (setId.isNotEmpty) {
      _loadSentences();
    }
  }

  Future<void> _deleteSentence(Sentence sentence) async {
    await _setService.deleteSentence(sentence.setId, sentence.id!);
    _loadSentences();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? '编辑句式集' : '创建句式集'),
        actions: [
          TextButton(
            onPressed: _isLoading ? null : _onSave,
            child: _isLoading
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
            // ---- 名称 ----
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: '句式集名称 *',
                hintText: '例如：日常口语 100 句',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),

            // ---- 描述 ----
            TextField(
              controller: _descriptionController,
              decoration: const InputDecoration(
                labelText: '描述（可选）',
                hintText: '句式集简介...',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 24),

            if (_isEditing || _sentences.isNotEmpty) ...[
              const Divider(),
              const SizedBox(height: 8),

              // ---- 添加句子 ----
              Row(
                children: [
                  Text('句子列表', style: theme.textTheme.titleSmall),
                  const Spacer(),
                  Text(
                    '${_sentences.length} 句',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // 已添加的句子列表
              if (_isLoading)
                const Center(child: CircularProgressIndicator())
              else if (_sentences.isEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '尚未添加句子，点击下方按钮添加',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                )
              else
                ..._sentences.map(
                  (s) => Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                s.english,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            SentenceNoteBar(sentence: s),
                            IconButton(
                              icon: Icon(
                                Icons.remove_circle_outline,
                                size: 20,
                                color: colorScheme.error,
                              ),
                              onPressed: () => _deleteSentence(s),
                              tooltip: '删除此句',
                              visualDensity: VisualDensity.compact,
                            ),
                          ],
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            s.chinese,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        if (s.extraWords.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Wrap(
                              spacing: 4,
                              runSpacing: 2,
                              children: s.extraWords
                                  .map(
                                    (w) => Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 1,
                                      ),
                                      decoration: BoxDecoration(
                                        color: colorScheme.secondaryContainer,
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        w,
                                        style: theme.textTheme.labelSmall
                                            ?.copyWith(
                                              color: colorScheme
                                                  .onSecondaryContainer,
                                              fontSize: 10,
                                            ),
                                      ),
                                    ),
                                  )
                                  .toList(),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 12),
            ],

            // ---- 添加句子表单 ----
            if (!_isAddingSentence)
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => setState(() => _isAddingSentence = true),
                  icon: const Icon(Icons.add),
                  label: const Text('添加句子'),
                ),
              )
            else ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(color: colorScheme.outlineVariant),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  children: [
                    TextField(
                      controller: _englishController,
                      decoration: const InputDecoration(
                        labelText: '英文原句 *',
                        hintText: 'I want to go shopping.',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      maxLines: 2,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _chineseController,
                      decoration: const InputDecoration(
                        labelText: '中文翻译 *',
                        hintText: '我想去购物。',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      maxLines: 2,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _extraWordsController,
                      decoration: const InputDecoration(
                        labelText: '入门版多余词（可选，1~5个）',
                        hintText: '用空格或逗号分隔，如：always never yesterday',
                        border: OutlineInputBorder(),
                        isDense: true,
                        helperText: '包含正确句子所需词汇 + 干扰项',
                        helperMaxLines: 2,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () =>
                                setState(() => _isAddingSentence = false),
                            child: const Text('取消'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _addSentence,
                            icon: const Icon(Icons.add),
                            label: const Text('添加'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
