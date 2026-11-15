import 'package:flutter/material.dart';

/// 「思考过程」折叠区。
///
/// 一次回答里所有**非正式回答**的内容——思维链、工具调用及其结果、执行状态——
/// 都收进这个手风琴，正式回答永远直接展示在外层气泡里。折叠时只占一行，
/// 展开后按发生顺序铺开，避免工具卡片把回答挤到屏幕外。
class ThinkingSection extends StatefulWidget {
  const ThinkingSection({
    super.key,
    this.reasoning = '',
    this.summary = '',
    this.statusText = '',
    this.children = const <Widget>[],
    this.initiallyExpanded = false,
  });

  /// 模型给出的思维链（可为空）。
  final String reasoning;

  /// 折叠时显示的摘要，例如「查词典 · 已执行」。
  final String summary;

  /// 折叠时显示的运行状态，例如「等待你批准」。
  final String statusText;

  /// 展开后的子内容，通常是工具调用卡片。
  final List<Widget> children;

  final bool initiallyExpanded;

  @override
  State<ThinkingSection> createState() => _ThinkingSectionState();
}

class _ThinkingSectionState extends State<ThinkingSection> {
  late bool _expanded = widget.initiallyExpanded;

  bool get _hasBody =>
      widget.reasoning.trim().isNotEmpty || widget.children.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    if (!_hasBody) return const SizedBox.shrink();

    final header = widget.summary.isEmpty ? '思考过程' : '思考过程 · ${widget.summary}';

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Icon(
                    Icons.psychology_outlined,
                    size: 16,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      header,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (widget.statusText.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Text(
                        widget.statusText,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colorScheme.primary,
                        ),
                      ),
                    ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 150),
            alignment: Alignment.topCenter,
            child: _expanded
                ? Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (widget.reasoning.trim().isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: SelectableText(
                              widget.reasoning,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                                height: 1.5,
                              ),
                            ),
                          ),
                        ...widget.children,
                      ],
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}
