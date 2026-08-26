import 'package:flutter/material.dart';
import 'saved_models.dart';

/// 收藏/笔记页的筛选与排序控件
class SavedFilterBar extends StatelessWidget {
  final SavedType? filterType;
  final SavedSort sort;
  final ValueChanged<SavedType?> onFilterChanged;
  final ValueChanged<SavedSort> onSortChanged;

  const SavedFilterBar({
    super.key,
    required this.filterType,
    required this.sort,
    required this.onFilterChanged,
    required this.onSortChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final options = <_FilterOption, SavedType?>{
      _FilterOption.all: null,
      _FilterOption.word: SavedType.word,
      _FilterOption.sentence: SavedType.sentence,
    };
    final selectedOption = options.entries
        .firstWhere((e) => e.value == filterType)
        .key;

    return Row(
      children: [
        Expanded(
          child: SegmentedButton<_FilterOption>(
            segments: const [
              ButtonSegment(
                value: _FilterOption.all,
                label: Text('全部'),
                icon: Icon(Icons.apps, size: 16),
              ),
              ButtonSegment(
                value: _FilterOption.word,
                label: Text('单词'),
                icon: Icon(Icons.text_fields, size: 16),
              ),
              ButtonSegment(
                value: _FilterOption.sentence,
                label: Text('句子'),
                icon: Icon(Icons.format_quote, size: 16),
              ),
            ],
            selected: {selectedOption},
            onSelectionChanged: (selection) {
              final opt = selection.first;
              onFilterChanged(options[opt]);
            },
            showSelectedIcon: false,
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              textStyle: WidgetStatePropertyAll(
                Theme.of(context).textTheme.labelMedium,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        PopupMenuButton<SavedSort>(
          icon: Icon(
            sort == SavedSort.time
                ? Icons.schedule
                : sort == SavedSort.alphabet
                ? Icons.sort_by_alpha
                : Icons.swap_vert,
            color: colorScheme.primary,
          ),
          tooltip: '排序方式',
          initialValue: sort,
          onSelected: onSortChanged,
          itemBuilder: (context) => const [
            PopupMenuItem(
              value: SavedSort.time,
              child: ListTile(
                leading: Icon(Icons.schedule),
                title: Text('按时间'),
                dense: true,
              ),
            ),
            PopupMenuItem(
              value: SavedSort.alphabet,
              child: ListTile(
                leading: Icon(Icons.sort_by_alpha),
                title: Text('按字母'),
                dense: true,
              ),
            ),
            PopupMenuItem(
              value: SavedSort.length,
              child: ListTile(
                leading: Icon(Icons.swap_vert),
                title: Text('按长度'),
                dense: true,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

enum _FilterOption { all, word, sentence }
