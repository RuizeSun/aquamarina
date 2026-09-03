import 'package:flutter/material.dart';
import '../../../services/ai_usage_service.dart';

/// 时间范围筛选
enum _AiUsageRange {
  today('本日'),
  week('近7天'),
  month('近30天'),
  all('全部');

  final String label;
  const _AiUsageRange(this.label);

  DateTime? get from {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return switch (this) {
      _AiUsageRange.today => today,
      _AiUsageRange.week => today.subtract(const Duration(days: 6)),
      _AiUsageRange.month => today.subtract(const Duration(days: 29)),
      _AiUsageRange.all => null,
    };
  }
}

/// AI 调用用量统计分区：Token 用量、请求记录与费用估算
class AiUsageStatsSection extends StatefulWidget {
  const AiUsageStatsSection({super.key});

  @override
  State<AiUsageStatsSection> createState() => _AiUsageStatsSectionState();
}

class _AiUsageStatsSectionState extends State<AiUsageStatsSection> {
  static const int _recordLimit = 50;

  _AiUsageRange _range = _AiUsageRange.all;
  bool _loading = true;
  AiUsageSummary _summary = const AiUsageSummary(
    requests: 0,
    promptTokens: 0,
    cacheHitTokens: 0,
    cacheMissTokens: 0,
    completionTokens: 0,
    totalTokens: 0,
    cost: 0,
  );
  List<AiUsageRecord> _records = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final from = _range.from;
    final summary = await AiUsageService.instance.fetchSummary(from: from);
    final records = await AiUsageService.instance.fetchRecords(
      from: from,
      limit: _recordLimit,
    );
    if (!mounted) return;
    setState(() {
      _summary = summary;
      _records = records;
      _loading = false;
    });
  }

  Future<void> _clearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空统计'),
        content: const Text('确定要清空所有 AI 调用记录与统计吗？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await AiUsageService.instance.clear();
      await _load();
    }
  }

  /// 汇总金额所用格式：取最近一条有费用的记录所用币种
  (String, int, bool) _costFormat() {
    String symbol = '¥';
    int decimals = 2;
    bool grouping = true;
    for (final r in _records) {
      if (r.cost != null) {
        symbol = r.currencySymbol ?? symbol;
        decimals = r.currencyDecimals;
        grouping = r.currencyGrouping;
        break;
      }
    }
    return (symbol, decimals, grouping);
  }

  static String _group(int value) {
    final s = value.toString();
    final b = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      final idx = s.length - 1 - i;
      if (i > 0 && i % 3 == 0) b.write(',');
      b.write(s[idx]);
    }
    return b.toString().split('').reversed.join();
  }

  static String _time(DateTime t) {
    final now = DateTime.now();
    final sameDay =
        t.year == now.year && t.month == now.month && t.day == now.day;
    String two(int v) => v.toString().padLeft(2, '0');
    final hm = '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
    if (sameDay) return hm;
    return '${t.month}-${t.day} $hm';
  }

  Widget _statTile({
    required ColorScheme colorScheme,
    required IconData icon,
    required Color color,
    required String label,
    required String value,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
          ),
          Text(
            value,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final (symbol, decimals, grouping) = _costFormat();
    final s = _summary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: SegmentedButton<_AiUsageRange>(
                segments: _AiUsageRange.values
                    .map(
                      (r) => ButtonSegment(
                        value: r,
                        label: Text(r.label),
                      ),
                    )
                    .toList(),
                selected: {_range},
                onSelectionChanged: (sel) {
                  if (sel.isEmpty) return;
                  setState(() => _range = sel.first);
                  _load();
                },
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: '刷新',
              onPressed: _loading ? null : _load,
              icon: _loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: 8),


        if (_loading) ...[
          const SizedBox(height: 40),
          const Center(child: CircularProgressIndicator()),
          const SizedBox(height: 40),
        ] else ...[
          _statTile(
            colorScheme: colorScheme,
            icon: Icons.receipt_long_outlined,
            color: colorScheme.primary,
            label: '请求数',
            value: _group(s.requests),
          ),
          const SizedBox(height: 8),
          _statTile(
            colorScheme: colorScheme,
            icon: Icons.memory_outlined,
            color: Colors.orange.shade800,
            label: '未缓存输入 Tokens',
            value: _group(s.cacheMissTokens),
          ),
          const SizedBox(height: 8),
          _statTile(
            colorScheme: colorScheme,
            icon: Icons.savings_outlined,
            color: Colors.green.shade700,
            label: '缓存命中输入 Tokens',
            value: _group(s.cacheHitTokens),
          ),
          const SizedBox(height: 8),
          _statTile(
            colorScheme: colorScheme,
            icon: Icons.output_outlined,
            color: Colors.blue.shade700,
            label: '输出 Tokens',
            value: _group(s.completionTokens),
          ),
          const SizedBox(height: 8),
          _statTile(
            colorScheme: colorScheme,
            icon: Icons.payments_outlined,
            color: Colors.purple.shade700,
            label: '估算费用',
            value: AiUsageService.formatMoney(
              s.cost,
              symbol: symbol,
              decimals: decimals,
              grouping: grouping,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '费用为估算值，按各请求发生时对应配置的计费与币种设置计算；'
            'Aquamarina 官方不支持用量与计费统计。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),

          Text('最近请求记录', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 4),
          if (_records.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Column(
                  children: [
                    Icon(
                      Icons.inbox_outlined,
                      size: 40,
                      color: colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '该时间段内暂无记录',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            )
          else ...[
            for (final r in _records) _recordTile(r),
            if (s.requests > _recordLimit)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '仅显示最近 $_recordLimit 条，共 ${_group(s.requests)} 次请求',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
          const SizedBox(height: 8),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            leading: Icon(
              Icons.delete_sweep_outlined,
              color: colorScheme.error,
            ),
            title: Text('清空统计', style: TextStyle(color: colorScheme.error)),
            subtitle: const Text('删除所有 AI 调用记录与统计'),
            onTap: _clearAll,
          ),
        ],
      ],
    );
  }


  Widget _recordTile(AiUsageRecord r) {
    final colorScheme = Theme.of(context).colorScheme;
    final typeLabel = switch (r.profileType) {
      'deepseek' => 'DeepSeek',
      'aquamarina' => 'Aquamarina',
      _ => 'OpenAI',
    };
    final title = (r.model == null || r.model!.isEmpty)
        ? r.profileName
        : '${r.profileName} · ${r.model}';

    final tokenInfo =
        '输入 ${_group(r.cacheMissTokens + r.cacheHitTokens)}'
        ' · 命中缓存 ${_group(r.cacheHitTokens)}'
        ' · 输出 ${_group(r.completionTokens)}';

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      elevation: 0,
      color: colorScheme.surfaceContainerLow,
      child: ListTile(
        dense: true,
        leading: CircleAvatar(
          radius: 16,
          backgroundColor: colorScheme.primaryContainer,
          child: Text(
            typeLabel.substring(0, 1),
            style: TextStyle(
              color: colorScheme.onPrimaryContainer,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        subtitle: Text(
          '${_time(r.createdAt)} · $tokenInfo',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        trailing: Text(
          r.formatCost() ?? '—',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: r.cost != null
                ? colorScheme.onSurface
                : colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

