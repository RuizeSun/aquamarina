import 'package:flutter/material.dart';

/// 编辑词书页「词表管理」中的词表列表。
///
/// 以 Sliver 形式提供，需放入 [CustomScrollView] 的 `slivers` 中使用。
///
/// 性能要点（词书可能有上千甚至上万词）：
/// - 使用 [SliverList.builder] 懒加载，只构建与布局可视区域（含缓存区）内的行，
///   而不是一次性构建整张词表；
/// - 行内用 [Ink] + [InkWell] 替代“每行一个 Material + 裁剪图层”的写法：
///   底色绘制在最近的 [Material] 墨迹层上，水波由 [InkWell] 按圆角裁剪，
///   既保留点击反馈，又省掉每行一个 Material 与一个 Clip 图层。
///
/// 也因此，宿主页面只需在 [CustomScrollView] 外层提供一个 [Material]
/// 作为墨迹层（例如 `Material(type: MaterialType.transparency)`）。
class WordBookWordList extends StatelessWidget {
  /// 要展示的单词（调用方负责过滤与排序）。
  final List<String> words;

  /// 点击某一行（查看单词详情）。
  final ValueChanged<String> onTapWord;

  /// 点击行尾的删除按钮（从词书中移除该词）。
  final ValueChanged<String> onRemoveWord;

  /// 是否处于多选模式（用于「按词书调用 AI 生成句式集」的选词）。
  ///
  /// 开启后：行首显示勾选框，点击整行切换选中状态，行尾的删除按钮隐藏。
  final bool selectionMode;

  /// 多选模式下已选中的单词（[selectionMode] 为 false 时忽略）。
  final Set<String> selectedWords;

  /// 多选模式下点击某一行（切换选中状态）。
  final ValueChanged<String>? onToggleWord;

  /// 列表内边距，默认与编辑词书页其他区块左右对齐。
  final EdgeInsetsGeometry padding;

  const WordBookWordList({
    super.key,
    required this.words,
    required this.onTapWord,
    required this.onRemoveWord,
    this.selectionMode = false,
    this.selectedWords = const {},
    this.onToggleWord,
    this.padding = const EdgeInsets.fromLTRB(16, 0, 16, 16),
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return SliverPadding(
      padding: padding,
      sliver: SliverList.builder(
        itemCount: words.length,
        itemBuilder: (context, index) =>
            _buildRow(words[index], theme, colorScheme),
      ),
    );
  }

  Widget _buildRow(String word, ThemeData theme, ColorScheme colorScheme) {
    final borderRadius = BorderRadius.circular(8);
    final selected = selectionMode && selectedWords.contains(word);

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Ink(
        decoration: BoxDecoration(
          color: selected
              ? colorScheme.primaryContainer.withValues(alpha: 0.6)
              : colorScheme.surfaceContainerHighest,
          borderRadius: borderRadius,
        ),
        child: InkWell(
          onTap: selectionMode
              ? () => onToggleWord?.call(word)
              : () => onTapWord(word),
          borderRadius: borderRadius,
          child: Padding(
            padding: const EdgeInsets.only(left: 12, top: 4, bottom: 4),
            child: Row(
              children: [
                if (selectionMode)
                  Icon(
                    selected ? Icons.check_box : Icons.check_box_outline_blank,
                    size: 20,
                    color: selected
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant,
                  )
                else
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
                if (selectionMode)
                  // 多选模式下不提供删除，避免误触破坏词书
                  const SizedBox(width: 8)
                else ...[
                  Icon(
                    Icons.chevron_right,
                    size: 20,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.remove_circle_outline,
                      size: 20,
                      color: colorScheme.error,
                    ),
                    onPressed: () => onRemoveWord(word),
                    tooltip: '移除此词',
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
