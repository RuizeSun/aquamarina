import 'dart:convert';

import 'package:flutter/material.dart';

import '../../models/ai_chat.dart';
import '../../services/data/word_book_service.dart';
import 'chat_labels.dart';

/// 工具参数的可读化展示。
///
/// 批准面板与对话里的工具卡片都要让用户看清「这次到底要做什么」。直接摆一段
/// JSON 会把意图埋在引号和花括号里，所以这里按工具语义把参数翻译成中文：
/// 先给一行结论（向词书 #3（四级词汇）添加 12 个单词），再列关键细节。只有
/// 参数本身不是合法 JSON 时才回退到原始文本。
class ToolArgumentsView extends StatefulWidget {
  const ToolArgumentsView({super.key, required this.call});

  final AiToolCall call;

  @override
  State<ToolArgumentsView> createState() => _ToolArgumentsViewState();
}

class _ToolArgumentsViewState extends State<ToolArgumentsView> {
  /// 词书 id → 标题（null 表示查不到）；跨面板复用，避免重复查库。
  static final Map<int, String?> _bookTitles = <int, String?>{};

  String? _bookTitle;

  @override
  void initState() {
    super.initState();
    _resolveBookTitle();
  }

  @override
  void didUpdateWidget(covariant ToolArgumentsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.call.rawArguments != widget.call.rawArguments ||
        oldWidget.call.name != widget.call.name) {
      _resolveBookTitle();
    }
  }

  void _resolveBookTitle() {
    final raw = widget.call.arguments['book_id'];
    final id = raw is int ? raw : int.tryParse('${raw ?? ''}');
    if (id == null) {
      _bookTitle = null;
      return;
    }

    if (_bookTitles.containsKey(id)) {
      _bookTitle = _bookTitles[id];
      return;
    }

    _bookTitle = null;
    WordBookService.getBookById(id)
        .then((book) {
          _bookTitles[id] = book?.title;
          if (!mounted) return;
          setState(() => _bookTitle = book?.title);
        })
        .catchError((Object _) {
          // 数据库未就绪（测试、首次启动）时退回纯 id，不影响批准流程。
          _bookTitles[id] = null;
        });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final digest = describeToolArguments(
      toolName: widget.call.name,
      arguments: widget.call.arguments,
      rawArguments: widget.call.rawArguments,
      parseError: widget.call.parseError,
      bookTitle: _bookTitle,
    );

    final children = <Widget>[];

    if (digest.rawFallback != null) {
      children.add(
        SelectableText(
          digest.rawFallback!,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            height: 1.4,
          ),
        ),
      );
    } else {
      if (digest.summary != null) {
        children.add(
          Text(
            digest.summary!,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        );
      }
      for (final field in digest.fields) {
        if (children.isNotEmpty) children.add(const SizedBox(height: 8));
        children.add(
          _ToolArgumentFieldTile(
            field: field,
            labelColor: colorScheme.onSurfaceVariant,
            theme: theme,
          ),
        );
      }
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}

class _ToolArgumentFieldTile extends StatelessWidget {
  const _ToolArgumentFieldTile({
    required this.field,
    required this.labelColor,
    required this.theme,
  });

  final ToolArgumentField field;
  final Color labelColor;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final label = Text(
      field.label,
      style: theme.textTheme.labelSmall?.copyWith(color: labelColor),
    );

    switch (field.kind) {
      case ToolArgumentFieldKind.inline:
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            label,
            const SizedBox(width: 8),
            Expanded(child: _valueText(field.value)),
          ],
        );
      case ToolArgumentFieldKind.block:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            label,
            const SizedBox(height: 2),
            _valueText(field.value),
          ],
        );
      case ToolArgumentFieldKind.chips:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            label,
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final item in field.items) _chip(item),
              ],
            ),
          ],
        );
    }
  }

  Widget _valueText(String value) => SelectableText(
    value,
    style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
  );

  Widget _chip(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: theme.colorScheme.surface.withValues(alpha: 0.75),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: theme.colorScheme.outlineVariant),
    ),
    child: Text(
      text,
      style: theme.textTheme.bodySmall?.copyWith(
        fontFamily: 'monospace',
        fontSize: 12,
      ),
    ),
  );
}

/// 参数可读化的结果。
///
/// [summary] 是一行结论；[fields] 是补充细节；[rawFallback] 非空表示参数不是
/// 合法 JSON，只能原样展示。
class ToolArgumentDigest {
  const ToolArgumentDigest({
    this.summary,
    this.fields = const [],
    this.rawFallback,
  });

  final String? summary;
  final List<ToolArgumentField> fields;
  final String? rawFallback;
}

enum ToolArgumentFieldKind { inline, block, chips }

/// 一个中文标签 + 值。列表类参数用 [ToolArgumentField.chips] 逐个铺开。
class ToolArgumentField {
  const ToolArgumentField._(
    this.label,
    this.kind, {
    this.value = '',
    this.items = const [],
  });

  factory ToolArgumentField.inline(String label, String value) =>
      ToolArgumentField._(label, ToolArgumentFieldKind.inline, value: value);

  factory ToolArgumentField.block(String label, String value) =>
      ToolArgumentField._(label, ToolArgumentFieldKind.block, value: value);

  factory ToolArgumentField.chips(String label, List<String> items) =>
      ToolArgumentField._(label, ToolArgumentFieldKind.chips, items: items);

  final String label;
  final ToolArgumentFieldKind kind;
  final String value;
  final List<String> items;
}

/// 按工具语义把参数翻译成中文摘要。
///
/// [bookTitle] 由调用方异步补齐，查不到时只显示 `#id`。
ToolArgumentDigest describeToolArguments({
  required String toolName,
  required Map<String, dynamic> arguments,
  required String rawArguments,
  required bool parseError,
  String? bookTitle,
}) {
  if (parseError) {
    return ToolArgumentDigest(
      rawFallback: rawArguments.trim().isEmpty ? '（空）' : rawArguments,
    );
  }

  switch (toolName) {
    case 'search_dictionary':
      final word = _text(arguments['word']);
      return word.isEmpty
          ? const ToolArgumentDigest(summary: '查询词典')
          : ToolArgumentDigest(summary: '查词典「$word」');

    case 'get_word_book_words':
      final ref = _bookRef(arguments['book_id'], bookTitle);
      return ToolArgumentDigest(
        summary: '从$ref读取单词',
        fields: _limitField(arguments['limit'], fallback: 100),
      );

    case 'get_due_reviews':
      return ToolArgumentDigest(
        summary: '列出待复习的单词',
        fields: _limitField(arguments['limit'], fallback: 50),
      );

    case 'get_word_notes':
      final query = _text(arguments['query']);
      return ToolArgumentDigest(
        summary: query.isEmpty ? '查看全部单词笔记' : '筛选单词笔记：关键词「$query」',
        fields: _limitField(arguments['limit'], fallback: 30),
      );

    case 'add_words_to_word_book':
      final ref = _bookRef(arguments['book_id'], bookTitle);
      final words = _stringList(arguments['words']);
      return ToolArgumentDigest(
        summary: words.isEmpty ? '向$ref添加单词' : '向$ref添加 ${words.length} 个单词',
        fields: words.isEmpty
            ? const []
            : [ToolArgumentField.chips('单词列表', _capWords(words))],
      );

    case 'set_word_note':
      final word = _text(arguments['word']);
      final note = _text(arguments['note']);
      return ToolArgumentDigest(
        summary: note.isEmpty ? '清除「$word」的笔记' : '为「$word」写入笔记',
        fields: [
          ToolArgumentField.block(
            note.isEmpty ? '笔记内容（将清空现有内容）' : '笔记内容',
            note.isEmpty ? '（无）' : note,
          ),
        ],
      );

    case 'set_word_favorite':
      final word = _text(arguments['word']);
      final favorite = arguments['favorite'];
      final summary = favorite == true
          ? '收藏「$word」'
          : favorite == false
          ? '取消收藏「$word」'
          : '修改「$word」的收藏状态';
      return ToolArgumentDigest(summary: summary);

    default:
      if (arguments.isEmpty) {
        return const ToolArgumentDigest(summary: '无需额外参数');
      }
      return ToolArgumentDigest(
        fields: [
          for (final entry in arguments.entries)
            _genericField(entry.key, entry.value),
        ],
      );
  }
}

/// 只读工具里「最多返回多少条」这类可选项：没传就不啰嗦。
List<ToolArgumentField> _limitField(dynamic raw, {required int fallback}) {
  final limit = _text(raw);
  if (limit.isEmpty) return const [];
  return [
    ToolArgumentField.inline('数量上限', '$limit 条（默认 $fallback）'),
  ];
}

ToolArgumentField _genericField(String key, dynamic value) {
  final label = ChatLabels.argument(key);
  if (value is List && value.every((item) => item is String)) {
    return ToolArgumentField.chips(
      label,
      _capWords(value.cast<String>().map((v) => v.trim()).toList()),
    );
  }
  if (value is Map) {
    return ToolArgumentField.block(
      label,
      const JsonEncoder.withIndent('  ').convert(value),
    );
  }
  final text = _formatValue(value);
  return text.contains('\n')
      ? ToolArgumentField.block(label, text)
      : ToolArgumentField.inline(label, text);
}

String _formatValue(dynamic value) {
  if (value == null) return '（空）';
  if (value is bool) return value ? '是' : '否';
  if (value is String) return value.trim().isEmpty ? '（空）' : value;
  return value.toString();
}

String _text(dynamic value) =>
    value is String ? value.trim() : (value?.toString().trim() ?? '');

List<String> _stringList(dynamic value) {
  if (value is! List) return const [];
  return [
    for (final item in value)
      if (item is String && item.trim().isNotEmpty) item.trim(),
  ];
}

/// 单词列表太长时不把面板撑成词典页。
List<String> _capWords(List<String> words) {
  const max = 40;
  if (words.length <= max) return words;
  return [...words.take(max), '…等 ${words.length} 个'];
}

/// 词书引用：能查到标题就带上，查不到时退化成 `词书 #id`。
String _bookRef(dynamic rawId, String? title) {
  final id = _text(rawId);
  if (id.isEmpty) return '词书';
  final name = title?.trim() ?? '';
  return name.isEmpty ? '词书 #$id' : '词书 #$id（$name）';
}
