import 'package:flutter/material.dart';

import '../../../services/sentence_eval_cache_service.dart';
import '../sentence_cache_page.dart';

/// 句型练习缓存设置分区：开关 + 缓存管理入口
class SentenceCacheSection extends StatefulWidget {
  /// 缓存服务（默认使用全局单例，测试可注入内存库实例）
  final SentenceEvalCacheService? cacheService;

  const SentenceCacheSection({super.key, this.cacheService});

  @override
  State<SentenceCacheSection> createState() => _SentenceCacheSectionState();
}

class _SentenceCacheSectionState extends State<SentenceCacheSection> {
  late final SentenceEvalCacheService _cacheService =
      widget.cacheService ?? SentenceEvalCacheService.instance;

  bool _enabled = true;
  SentenceEvalCacheStats _stats = SentenceEvalCacheStats.empty;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final enabled = await _cacheService.isEnabled();
    final stats = await _cacheService.fetchStats();
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _stats = stats;
      _isLoading = false;
    });
  }

  Future<void> _openManager() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const SentenceCachePage()));
    // 管理页可能清除了缓存，返回后刷新概览
    await _load();
  }

  String get _statsSubtitle {
    if (_stats.isEmpty) return '暂无缓存';
    final buffer = StringBuffer(
      '共 ${_stats.count} 条 · 约 '
      '${SentenceEvalCacheService.formatSize(_stats.bytes)}',
    );
    if (_stats.hits > 0) {
      buffer.write(' · 累计命中 ${_stats.hits} 次');
    }
    return buffer.toString();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (_isLoading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    return Column(
      children: [
        SwitchListTile(
          secondary: Icon(Icons.bolt_outlined, color: colorScheme.primary),
          title: const Text('启用练习缓存'),
          subtitle: const Text('相同句子与回答直接复用上次批改结果，不再调用 AI'),
          value: _enabled,
          onChanged: (value) async {
            await _cacheService.setEnabled(value);
            if (!mounted) return;
            setState(() => _enabled = value);
          },
        ),
        ListTile(
          leading: Icon(
            Icons.cleaning_services_outlined,
            color: colorScheme.primary,
          ),
          title: const Text('缓存管理'),
          subtitle: Text(_statsSubtitle),
          trailing: const Icon(Icons.chevron_right, size: 20),
          onTap: _openManager,
        ),
      ],
    );
  }
}
