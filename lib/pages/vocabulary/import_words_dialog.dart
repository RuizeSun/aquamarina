import 'package:flutter/material.dart';
import '../../services/word_book_service.dart';
import '../../services/dictionary_service.dart';

/// 每个缺失词的操作选项
enum MissingWordAction { keep, discard, replace }

class ImportWordsDialog extends StatefulWidget {
  final List<String> missingWords;
  final ImportResult importResult;

  const ImportWordsDialog({
    super.key,
    required this.missingWords,
    required this.importResult,
  });

  @override
  State<ImportWordsDialog> createState() => _ImportWordsDialogState();
}

class _ImportWordsDialogState extends State<ImportWordsDialog> {
  late List<MissingWordAction> _actions;
  late Map<int, String> _replacements;
  late Map<int, List<String>> _suggestions;
  late Map<int, bool> _searching;

  @override
  void initState() {
    super.initState();
    _actions = List.filled(widget.missingWords.length, MissingWordAction.keep);
    _replacements = {};
    _suggestions = {};
    _searching = {};
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 标题区
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(12),
                  topRight: Radius.circular(12),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '导入结果',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '共 ${widget.importResult.totalLines} 个词，'
                    '匹配 ${widget.importResult.foundCount} 个，'
                    '缺失 ${widget.importResult.missingCount} 个',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onPrimaryContainer,
                    ),
                  ),
                ],
              ),
            ),

            // 缺失词汇列表
            if (widget.missingWords.isNotEmpty)
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '以下词汇在词典中未找到，请选择处理方式：',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.error,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Flexible(
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: widget.missingWords.length,
                          itemBuilder: (context, index) {
                            return _buildMissingWordItem(index);
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.all(24),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.check_circle,
                      color: colorScheme.primary,
                      size: 48,
                    ),
                  ],
                ),
              ),

            // 底部按钮
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(null),
                    child: const Text('取消导入'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => _onConfirm(),
                    child: const Text('确认导入'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMissingWordItem(int index) {
    final word = widget.missingWords[index];
    final action = _actions[index];
    final replacement = _replacements[index];
    final suggestions = _suggestions[index] ?? [];
    final isSearching = _searching[index] ?? false;

    Color actionColor;
    switch (action) {
      case MissingWordAction.keep:
        actionColor = Colors.orange;
        break;
      case MissingWordAction.discard:
        actionColor = Colors.red;
        break;
      case MissingWordAction.replace:
        actionColor = Colors.blue;
        break;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 第一行：单词 + 操作按钮
            Row(
              children: [
                Expanded(
                  child: Text(
                    word,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: actionColor,
                      decoration: action == MissingWordAction.discard
                          ? TextDecoration.lineThrough
                          : null,
                    ),
                  ),
                ),
                _buildActionChip(index, MissingWordAction.keep, '保留'),
                const SizedBox(width: 4),
                _buildActionChip(index, MissingWordAction.discard, '丢弃'),
                const SizedBox(width: 4),
                _buildActionChip(index, MissingWordAction.replace, '替换'),
              ],
            ),

            // 替换模式：输入框 + 找词建议
            if (action == MissingWordAction.replace) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      decoration: const InputDecoration(
                        hintText: '输入替换词...',
                        isDense: true,
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                      ),
                      controller: TextEditingController(
                        text: replacement ?? '',
                      ),
                      onChanged: (value) {
                        _replacements[index] = value.trim();
                        _searchSuggestions(index, value.trim());
                      },
                    ),
                  ),
                ],
              ),
              // 建议列表
              if (isSearching)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: LinearProgressIndicator(),
                ),
              if (suggestions.isNotEmpty && !isSearching)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: suggestions.map((suggestion) {
                      return ActionChip(
                        label: Text(suggestion),
                        onPressed: () {
                          setState(() {
                            _replacements[index] = suggestion;
                          });
                        },
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                      );
                    }).toList(),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildActionChip(int index, MissingWordAction action, String label) {
    final isSelected = _actions[index] == action;

    Color color;
    switch (action) {
      case MissingWordAction.keep:
        color = Colors.orange;
        break;
      case MissingWordAction.discard:
        color = Colors.red;
        break;
      case MissingWordAction.replace:
        color = Colors.blue;
        break;
    }

    return ChoiceChip(
      label: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          color: isSelected ? Colors.white : color,
        ),
      ),
      selected: isSelected,
      selectedColor: color,
      onSelected: (_) {
        setState(() {
          _actions[index] = action;
          if (action != MissingWordAction.replace) {
            _replacements.remove(index);
            _suggestions.remove(index);
          }
        });
      },
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );
  }

  Future<void> _searchSuggestions(int index, String query) async {
    if (query.length < 2) {
      setState(() {
        _suggestions.remove(index);
      });
      return;
    }

    setState(() {
      _searching[index] = true;
    });

    try {
      final results = await DictionaryService.searchEnFuzzy(query);
      if (mounted) {
        setState(() {
          _suggestions[index] = results.map((e) => e.word).take(5).toList();
          _searching[index] = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _searching[index] = false;
        });
      }
    }
  }

  void _onConfirm() {
    final finalWords = <String>[...widget.importResult.foundWords];

    for (int i = 0; i < widget.missingWords.length; i++) {
      switch (_actions[i]) {
        case MissingWordAction.keep:
          finalWords.add(widget.missingWords[i]);
          break;
        case MissingWordAction.discard:
          // 丢弃：不加入
          break;
        case MissingWordAction.replace:
          final replacement = _replacements[i];
          if (replacement != null && replacement.isNotEmpty) {
            finalWords.add(replacement);
          }
          // 没有输入替换词则丢弃
          break;
      }
    }

    Navigator.of(context).pop(finalWords);
  }
}
