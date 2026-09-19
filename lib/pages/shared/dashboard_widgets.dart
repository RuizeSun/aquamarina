import 'package:flutter/material.dart';

/// 仪表盘页共用布局常量。
///
/// 「背单词」与「句型练习」两个 Tab 首页共用同一套视觉语言，
/// 骨架固定为：选择卡 → 功能入口 → 进度卡 → 概览统计 → 主操作 → 信息面板。
/// 新增入口时请复用本文件中的组件，避免两页风格再次分叉。
class DashboardMetrics {
  const DashboardMetrics._();

  /// 页面内容内边距
  static const EdgeInsets pagePadding = EdgeInsets.all(16);

  /// 卡片 / 面板统一圆角
  static const double radius = 12;

  /// 顶部选择卡图标块边长
  static const double selectorIconSize = 64;

  /// 区块之间的间距
  static const double sectionGap = 16;

  /// 同一区块内元素之间的间距
  static const double itemGap = 12;

  /// 区块间距占位
  static const Widget sectionSpacer = SizedBox(height: sectionGap);

  /// 区块内元素间距占位
  static const Widget itemSpacer = SizedBox(height: itemGap);

  /// 并排元素（如统计卡片）之间的横向间距占位
  static const Widget itemGapSpacer = SizedBox(width: itemGap);
}

/// 顶部「当前选中项」卡片：左侧图标色块 + 标题 / 副标题 + 右侧切换按钮。
///
/// 背单词页用于当前词书，句型练习页用于当前句式集。
class DashboardSelectorCard extends StatelessWidget {
  const DashboardSelectorCard({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.iconBackgroundColor,
    this.iconForegroundColor,
    this.switchTooltip,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  /// 图标块背景色，默认使用主题主色
  final Color? iconBackgroundColor;
  final Color? iconForegroundColor;

  /// 右侧切换按钮提示文案，为 null 时不显示右侧按钮
  final String? switchTooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(DashboardMetrics.radius),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: DashboardMetrics.selectorIconSize,
                height: DashboardMetrics.selectorIconSize,
                decoration: BoxDecoration(
                  color: iconBackgroundColor ?? colorScheme.primary,
                  borderRadius: BorderRadius.circular(DashboardMetrics.radius),
                ),
                child: Icon(
                  icon,
                  color: iconForegroundColor ?? colorScheme.onPrimary,
                  size: DashboardMetrics.selectorIconSize / 2,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (subtitle != null && subtitle!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (switchTooltip != null)
                IconButton(
                  icon: const Icon(Icons.swap_horiz),
                  onPressed: onTap,
                  tooltip: switchTooltip,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 功能入口按钮（描边样式）。
///
/// 配合 [DashboardButtonRow] 使用：单个按钮占满整行，两个按钮自动并排。
class DashboardEntryButton extends StatelessWidget {
  const DashboardEntryButton({
    super.key,
    required this.icon,
    required this.label,
    this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon),
      label: Text(label, overflow: TextOverflow.ellipsis),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 14),
      ),
    );
  }
}

/// 主操作按钮，与 [DashboardEntryButton] 尺寸对齐。
class DashboardPrimaryButton extends StatelessWidget {
  const DashboardPrimaryButton({
    super.key,
    required this.icon,
    required this.label,
    this.onPressed,
    this.outlined = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  /// 是否为描边样式（主操作为填充样式）
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    const padding = EdgeInsets.symmetric(vertical: 16);
    return outlined
        ? OutlinedButton.icon(
            onPressed: onPressed,
            icon: Icon(icon),
            label: Text(label, overflow: TextOverflow.ellipsis),
            style: OutlinedButton.styleFrom(padding: padding),
          )
        : FilledButton.icon(
            onPressed: onPressed,
            icon: Icon(icon),
            label: Text(label, overflow: TextOverflow.ellipsis),
            style: FilledButton.styleFrom(padding: padding),
          );
  }
}

/// 按钮行：按 [children] 数量自动决定全宽或等宽并排。
class DashboardButtonRow extends StatelessWidget {
  const DashboardButtonRow({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    if (children.length == 1) {
      return SizedBox(width: double.infinity, child: children.first);
    }
    return Row(
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(width: DashboardMetrics.itemGap),
          Expanded(child: children[i]),
        ],
      ],
    );
  }
}

/// 进度卡片：图标 + 标题 + 数值 + 进度条。
///
/// 背单词页用于「今日打卡进度」，句型练习页用于「句式集练习进度」。
class DashboardProgressCard extends StatelessWidget {
  const DashboardProgressCard({
    super.key,
    required this.icon,
    required this.title,
    required this.valueText,
    required this.progress,
    this.completed = false,
    this.completedTitle,
    this.completedIcon = Icons.check_circle,
  });

  final IconData icon;
  final String title;
  final String valueText;

  /// 0.0 ~ 1.0
  final double progress;

  /// 是否已完成（完成后整卡以绿色高亮）
  final bool completed;

  /// 完成后的标题，为 null 时标题保持不变
  final String? completedTitle;
  final IconData completedIcon;

  /// 进度填充条的 Key（测试用于断言实际渲染尺寸）
  static const Key fillKey = ValueKey('dashboard-progress-fill');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final accent = completed ? Colors.green : colorScheme.primary;
    final ratio = progress.clamp(0.0, 1.0);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      decoration: BoxDecoration(
        color: completed
            ? Colors.green.withValues(alpha: 0.12)
            : colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(DashboardMetrics.radius),
        border: completed
            ? Border.all(color: Colors.green.withValues(alpha: 0.5))
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(completed ? completedIcon : icon, color: accent, size: 28),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  completed ? (completedTitle ?? title) : title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: accent,
                  ),
                ),
              ),
              Text(
                valueText,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 自定义进度条：轨道使用半透明前景色，保证进度为 0 时依然可见
          // （LinearProgressIndicator 的默认轨道与卡片背景同色，会整条消失）
          SizedBox(
            height: 8,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(
                    color: colorScheme.onSurface.withValues(alpha: 0.1),
                  ),
                  // heightFactor 必须显式给 1：外层约束是宽松的（minHeight: 0），
                  // 只给 widthFactor 时填充条的高度会收敛为 0 —— 整条永远不可见。
                  FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: ratio,
                    heightFactor: 1,
                    child: ColoredBox(key: fillKey, color: accent),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 概览统计卡片的强调色。
enum DashboardStatTone {
  /// 常规：主色强调
  normal,

  /// 提醒：错误色强调（有待处理事项时使用）
  alert,
}

/// 概览统计卡片：图标 + 标签 + 数值，可点击跳转。
class DashboardStatCard extends StatelessWidget {
  const DashboardStatCard({
    super.key,
    required this.icon,
    required this.label,
    required this.valueText,
    this.tone = DashboardStatTone.normal,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String valueText;
  final DashboardStatTone tone;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isAlert = tone == DashboardStatTone.alert;

    final background = isAlert
        ? colorScheme.errorContainer
        : colorScheme.surfaceContainerHighest;
    final valueColor = isAlert ? colorScheme.error : colorScheme.primary;
    final labelColor = isAlert
        ? colorScheme.onErrorContainer
        : colorScheme.onSurfaceVariant;

    return Material(
      color: background,
      borderRadius: BorderRadius.circular(DashboardMetrics.radius),
      child: InkWell(
        borderRadius: BorderRadius.circular(DashboardMetrics.radius),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(icon, color: valueColor, size: 32),
              const SizedBox(width: 12),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: labelColor,
                      ),
                    ),
                    Text(
                      valueText,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: valueColor,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 区块标题，用于「今日概览」「词书信息」这类小节。
class DashboardSectionTitle extends StatelessWidget {
  const DashboardSectionTitle(
    this.text, {
    super.key,
    this.icon,
    this.iconColor,
    this.small = false,
  });

  final String text;
  final IconData? icon;
  final Color? iconColor;

  /// 使用 titleSmall（用于更次要的信息区块）
  final bool small;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = small
        ? theme.textTheme.titleSmall
        : theme.textTheme.titleMedium;

    if (icon == null) return Text(text, style: style);

    return Row(
      children: [
        Icon(icon, size: 20, color: iconColor ?? theme.colorScheme.primary),
        const SizedBox(width: 6),
        Text(text, style: style),
      ],
    );
  }
}

/// 圆角信息面板（词书信息、设置提示等）。
class DashboardPanel extends StatelessWidget {
  const DashboardPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(12),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(DashboardMetrics.radius),
      ),
      child: child,
    );
  }
}

/// 面板内的「标签: 值」行。
class DashboardInfoRow extends StatelessWidget {
  const DashboardInfoRow({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text(
            '$label: ',
            style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 13),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

/// 空状态 / 错误状态占位 UI（两个 Tab 首页共用同一套排版）。
class DashboardEmptyState extends StatelessWidget {
  const DashboardEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.actionIcon,
    this.onAction,
    this.iconColor,
  });

  final IconData icon;
  final String title;
  final String message;

  /// 操作按钮（三项都提供时才显示）
  final String? actionLabel;
  final IconData? actionIcon;
  final VoidCallback? onAction;

  /// 图标颜色，默认为主题主色的 30% 透明
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 80,
              color: iconColor ?? colorScheme.primary.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            if (onAction != null && actionLabel != null && actionIcon != null)
              FilledButton.icon(
                onPressed: onAction,
                icon: Icon(actionIcon),
                label: Text(actionLabel!),
              ),
          ],
        ),
      ),
    );
  }
}
