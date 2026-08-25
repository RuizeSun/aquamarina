import 'package:flutter/material.dart';
import '../../services/log_service.dart';

/// 日志查看页面
class LogViewerPage extends StatefulWidget {
  const LogViewerPage({super.key});

  @override
  State<LogViewerPage> createState() => _LogViewerPageState();
}

class _LogViewerPageState extends State<LogViewerPage> {
  final _searchController = TextEditingController();
  String _searchQuery = '';
  LogLevel? _filterLevel;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<LogEntry> get _filteredEntries {
    var list = LogService.instance.entries;
    if (_filterLevel != null) {
      list = list.where((e) => e.level == _filterLevel).toList();
    }
    if (_searchQuery.isNotEmpty) {
      final query = _searchQuery.toLowerCase();
      list = list.where((e) {
        return e.tag.toLowerCase().contains(query) ||
            e.message.toLowerCase().contains(query);
      }).toList();
    }
    return list.reversed.toList();
  }

  Color _levelColor(LogLevel level) {
    return switch (level) {
      LogLevel.debug => Colors.grey,
      LogLevel.info => Colors.blue,
      LogLevel.warning => Colors.orange,
      LogLevel.error => Colors.red,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('查看日志'),
        centerTitle: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.share_outlined),
            tooltip: '导出日志',
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              final success = await LogService.instance.exportAndShare();
              if (!mounted) return;
              messenger.showSnackBar(
                SnackBar(
                  content: Text(success ? '日志导出成功' : '日志为空'),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '清空日志',
            onPressed: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('清空日志'),
                  content: const Text('确定要清空所有日志记录吗？'),
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
                LogService.instance.clear();
                if (mounted) setState(() {});
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          _buildSearchBar(),
          _buildLevelFilters(),
          const Divider(height: 1),
          Expanded(child: _buildLogList(theme, colorScheme)),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: TextField(
        controller: _searchController,
        decoration: InputDecoration(
          hintText: '搜索日志...',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                  },
                )
              : null,
          border: const OutlineInputBorder(),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 10,
          ),
        ),
        onChanged: (v) => setState(() => _searchQuery = v.trim()),
      ),
    );
  }

  Widget _buildLevelFilters() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          _filterChip(null, '全部'),
          const SizedBox(width: 8),
          _filterChip(LogLevel.debug, 'DEBUG'),
          const SizedBox(width: 8),
          _filterChip(LogLevel.info, 'INFO'),
          const SizedBox(width: 8),
          _filterChip(LogLevel.warning, 'WARN'),
          const SizedBox(width: 8),
          _filterChip(LogLevel.error, 'ERROR'),
        ]),
      ),
    );
  }

  Widget _filterChip(LogLevel? level, String label) {
    final isSelected = _filterLevel == level;
    final color = level != null ? _levelColor(level) : null;
    return FilterChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (_) => setState(() {
        _filterLevel = isSelected ? null : level;
      }),
      selectedColor: color?.withValues(alpha: 0.2),
      labelStyle: TextStyle(
        color: isSelected ? color : null,
        fontWeight: isSelected ? FontWeight.w600 : null,
        fontSize: 13,
      ),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }

  Widget _buildLogList(ThemeData theme, ColorScheme colorScheme) {
    return ValueListenableBuilder<int>(
      valueListenable: LogService.instance.logCount,
      builder: (context, _, _) {
        final entries = _filteredEntries;
        if (entries.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.article_outlined,
                  size: 64,
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                ),
                const SizedBox(height: 16),
                Text(
                  '暂无日志',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          itemCount: entries.length,
          itemBuilder: (context, index) {
            return _LogEntryTile(
              entry: entries[index],
              levelColor: _levelColor(entries[index].level),
            );
          },
        );
      },
    );
  }
}

/// 单条日志显示组件
class _LogEntryTile extends StatelessWidget {
  final LogEntry entry;
  final Color levelColor;

  const _LogEntryTile({required this.entry, required this.levelColor});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final timeStr =
        '${_two(entry.timestamp.hour)}:${_two(entry.timestamp.minute)}:'
        '${_two(entry.timestamp.second)}'
        '.${entry.timestamp.millisecond.toString().padLeft(3, '0')}';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            timeStr,
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: 11,
            ),
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: levelColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              entry.level.label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: levelColor,
                fontWeight: FontWeight.w700,
                fontSize: 10,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            entry.tag,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
              fontSize: 11,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              entry.message,
              style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  static String _two(int v) => v.toString().padLeft(2, '0');
}


