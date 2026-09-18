import 'package:flutter/material.dart';

import '../../services/sentence_eval_cache_service.dart';

/// 句型练习缓存管理页面
///
/// 展示缓存条数与占用空间，并提供「清除全部」「清除 N 天前」操作。
class SentenceCachePage extends StatefulWidget {
  const SentenceCachePage({super.key});

  @override
  State<SentenceCachePage> createState() => _SentenceCachePageState();
}

class _SentenceCachePageState extends State<SentenceCachePage> {
  final SentenceEvalCacheService _cacheService =
      SentenceEvalCacheService.instance;

  SentenceEvalCacheStats _stats = SentenceEvalCacheStats.empty;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    setState(() => _loading = true);
    final stats = await _cacheService.fetchStats();
    if (!mounted) return;
    setState(() {
      _stats = stats;
      _loading = false;
    });
  }

  void _showSnack(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : null,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ===== 清除全部 =====
  Future<void> _clearAll() async {
    if (_stats.isEmpty) {
      _showSnack('当前没有缓存');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除全部缓存'),
        content: Text(
          '将删除全部 ${_stats.count} 条批改结果缓存'
          '（约 ${SentenceEvalCacheService.formatSize(_stats.bytes)}）。\n\n'
          '清除后相同句子与回答会重新调用 AI 批改。此操作不可撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busy = true);
    final deleted = await _cacheService.deleteAll();
    await _loadStats();
    _showSnack('已清除 $deleted 条缓存');
  }

  // ===== 清除 N 天前的缓存 =====
  Future<void> _clearOlderThanDays() async {
    final days = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('清除多久之前的缓存'),
        children: [
          for (final d in const [7, 30, 90])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, d),
              child: Text('清除 $d 天前的缓存'),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, -1),
            child: const Text('自定义天数…'),
          ),
        ],
      ),
    );
    if (days == null || !mounted) return;

    final targetDays = days == -1 ? await _askCustomDays() : days;
    if (targetDays == null || !mounted) return;

    if (_stats.isEmpty) {
      _showSnack('当前没有缓存');
      return;
    }

    setState(() => _busy = true);
    final count = await _cacheService.countOlderThanDays(targetDays);
    if (!mounted) return;
    setState(() => _busy = false);

    if (count == 0) {
      _showSnack('没有 $targetDays 天前的缓存');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除过期缓存'),
        content: Text('将删除 $targetDays 天前的缓存，共 $count 条。\n\n此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busy = true);
    final deleted = await _cacheService.deleteOlderThanDays(targetDays);
    await _loadStats();
    _showSnack('已删除 $deleted 条缓存');
  }

  /// 自定义天数输入对话框（1 ~ 3650 天）
  Future<int?> _askCustomDays() async {
    final controller = TextEditingController();
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('自定义天数'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            hintText: '例如 60',
            suffixText: '天',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final value = int.tryParse(controller.text.trim());
              if (value == null || value < 1 || value > 3650) {
                Navigator.pop(ctx);
                _showSnack('请输入 1 ~ 3650 之间的天数', isError: true);
                return;
              }
              Navigator.pop(ctx, value);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  // ===== UI =====
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('练习缓存'),
        centerTitle: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: _busy ? null : _loadStats,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                if (_busy) const LinearProgressIndicator(),
                _buildOverviewCard(theme, colorScheme),
                const Divider(),
                ListTile(
                  leading: Icon(
                    Icons.delete_sweep_outlined,
                    color: colorScheme.error,
                  ),
                  title: Text(
                    '清除全部缓存',
                    style: TextStyle(color: colorScheme.error),
                  ),
                  subtitle: const Text('删除所有已缓存的批改结果'),
                  enabled: !_busy,
                  onTap: _busy ? null : _clearAll,
                ),
                ListTile(
                  leading: Icon(
                    Icons.history_toggle_off,
                    color: colorScheme.error,
                  ),
                  title: Text(
                    '清除 N 天前的缓存',
                    style: TextStyle(color: colorScheme.error),
                  ),
                  subtitle: const Text('按缓存创建时间清理较早的记录'),
                  enabled: !_busy,
                  onTap: _busy ? null : _clearOlderThanDays,
                ),
                const Divider(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  child: Text(
                    '缓存命中规则：相同句子（中文 + 英文）+ 相同回答 + 相同练习模式时，'
                    '直接复用上次的批改结果，不再调用 AI；'
                    '练习结果页会标注「命中本地缓存」，也可点击「重新批改」忽略缓存。\n\n'
                    '缓存仅保存批改结果，占用空间为估算值；数据备份会一并包含缓存，'
                    '清除后下次练习会重新调用 AI 批改。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      height: 1.6,
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildOverviewCard(ThemeData theme, ColorScheme colorScheme) {
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      elevation: 0,
      color: colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                Icon(Icons.bolt, size: 20, color: colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  '缓存概览',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _buildStatRow(theme, '缓存条数', '${_stats.count} 条'),
            _buildStatRow(
              theme,
              '占用空间',
              '约 ${SentenceEvalCacheService.formatSize(_stats.bytes)}',
            ),
            _buildStatRow(theme, '累计命中', '${_stats.hits} 次'),
            _buildStatRow(theme, '最早缓存', _formatTime(_stats.oldest)),
            _buildStatRow(theme, '最新缓存', _formatTime(_stats.newest)),
          ],
        ),
      ),
    );
  }

  Widget _buildStatRow(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: theme.textTheme.bodyMedium),
          Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  static String _formatTime(DateTime? time) {
    if (time == null) return '—';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }
}
