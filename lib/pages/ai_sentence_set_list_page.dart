import 'package:flutter/material.dart';
import '../models/ai_sentence_set.dart';
import '../services/ai_sentence_set_service.dart';
import 'ai_sentence_set_edit_page.dart';
import 'online_corpus_list_page.dart';

class SentenceSetListPage extends StatefulWidget {
  final String? currentSetId;
  final ValueChanged<SentenceSet>? onSetSelected;

  const SentenceSetListPage({super.key, this.currentSetId, this.onSetSelected});

  @override
  State<SentenceSetListPage> createState() => _SentenceSetListPageState();
}

class _SentenceSetListPageState extends State<SentenceSetListPage> {
  final SentenceSetService _setService = SentenceSetService();
  List<SentenceSet> _sets = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSets();
  }

  Future<void> _loadSets() async {
    setState(() => _isLoading = true);
    await _setService.load();
    if (mounted) {
      setState(() {
        _sets = _setService.sets;
        _isLoading = false;
      });
    }
  }

  Future<void> _deleteSet(SentenceSet set) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除句式集 "${set.name}" 吗？\n此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirm == true && set.id != null) {
      await _setService.deleteSet(set.id!);
      _loadSets();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('句式集管理'),
        actions: [
          if (widget.onSetSelected != null)
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _sets.isEmpty
          ? _buildEmptyState(theme, colorScheme)
          : _buildSetList(),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.small(
            heroTag: 'online',
            onPressed: () async {
              final result = await Navigator.of(context).push<bool>(
                MaterialPageRoute(builder: (_) => const OnlineCorpusListPage()),
              );
              if (result == true) _loadSets();
            },
            child: const Icon(Icons.cloud_download_outlined),
          ),
          const SizedBox(height: 12),
          FloatingActionButton(
            heroTag: 'create',
            onPressed: () async {
              final result = await Navigator.of(context).push<bool>(
                MaterialPageRoute(builder: (_) => const SentenceSetEditPage()),
              );
              if (result == true) _loadSets();
            },
            child: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme, ColorScheme colorScheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.format_quote_rounded,
              size: 80,
              color: colorScheme.primary.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 16),
            Text(
              '还没有句式集',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '点击右下角 "+" 创建或从在线资源库中添加',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSetList() {
    return RefreshIndicator(
      onRefresh: _loadSets,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
        itemCount: _sets.length,
        itemBuilder: (context, index) => _buildSetCard(_sets[index]),
      ),
    );
  }

  Widget _buildSetCard(SentenceSet set) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isSelected = set.id == widget.currentSetId;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          if (widget.onSetSelected != null) {
            widget.onSetSelected!(set);
            Navigator.of(context).pop();
          }
        },
        onLongPress: () => _deleteSet(set),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // 封面色块
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: Color(set.hashCode).withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.format_quote, color: Colors.white),
              ),
              const SizedBox(width: 16),

              // 句式集信息
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      set.name,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (set.description != null && set.description!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          set.description!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        children: [
                          Icon(
                            Icons.short_text,
                            size: 14,
                            color: colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '${set.sentenceCount} 句',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // 选中标记
              if (isSelected)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Icon(
                    Icons.check_circle,
                    color: colorScheme.primary,
                    size: 20,
                  ),
                ),

              // 编辑按钮
              IconButton(
                icon: const Icon(Icons.edit_outlined),
                onPressed: () async {
                  final result = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(
                      builder: (_) => SentenceSetEditPage(
                        existingSet: set,
                        setService: _setService,
                      ),
                    ),
                  );
                  if (result == true) _loadSets();
                },
              ),
              // 删除按钮
              IconButton(
                icon: Icon(Icons.delete_outline, color: colorScheme.error),
                onPressed: () => _deleteSet(set),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
