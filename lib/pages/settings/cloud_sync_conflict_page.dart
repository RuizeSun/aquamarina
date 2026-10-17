import 'package:flutter/material.dart';

import '../../services/sync_conflict_store.dart';

/// 逐条查看并处理同步冲突（P2-6）。
class CloudSyncConflictPage extends StatefulWidget {
  const CloudSyncConflictPage({super.key});

  @override
  State<CloudSyncConflictPage> createState() => _CloudSyncConflictPageState();
}

class _CloudSyncConflictPageState extends State<CloudSyncConflictPage> {
  late Future<List<PendingSyncConflict>> _future;

  @override
  void initState() {
    super.initState();
    _future = SyncConflictStore.listUnresolved();
  }

  void _reload() {
    setState(() {
      _future = SyncConflictStore.listUnresolved();
    });
  }

  Future<void> _resolve(PendingSyncConflict conflict, String action) async {
    var ok = true;
    if (action == 'remote') {
      ok = await SyncConflictStore.applyRemote(conflict);
    } else if (action == 'both') {
      ok = await SyncConflictStore.keepBoth(conflict);
    }
    if (!ok) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('该冲突暂不支持此操作')));
      return;
    }
    await SyncConflictStore.markResolved(conflict.id, action);
    if (!mounted) return;
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('同步冲突'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: FutureBuilder<List<PendingSyncConflict>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = snapshot.data ?? const <PendingSyncConflict>[];
          if (items.isEmpty) {
            return const Center(child: Text('没有待处理的冲突'));
          }
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: items.length,
            separatorBuilder: (_, _) => const Divider(),
            itemBuilder: (context, index) {
              final item = items[index];
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 8),
                      _valueBlock('本地（较新）', item.localData),
                      const SizedBox(height: 6),
                      _valueBlock('远端', item.remoteData),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: [
                          OutlinedButton(
                            onPressed: () => _resolve(item, 'local'),
                            child: const Text('保留本地'),
                          ),
                          FilledButton(
                            onPressed: () => _resolve(item, 'remote'),
                            child: const Text('采用远端'),
                          ),
                          if (item.entity == 'word_notes' ||
                              item.entity == 'sentence_notes')
                            TextButton(
                              onPressed: () => _resolve(item, 'both'),
                              child: const Text('保留双方'),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _valueBlock(String label, Map<String, dynamic> data) {
    final text = data.entries
        .where((e) => e.value != null && '${e.value}'.isNotEmpty)
        .map((e) => '${e.key}: ${e.value}')
        .join('\n');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$label\n${text.isEmpty ? '（无字段）' : text}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}
