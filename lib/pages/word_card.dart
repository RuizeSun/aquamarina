import 'package:flutter/material.dart';
import '../models/word_entry.dart';
import '../services/tts_service.dart';
import 'vocabulary/shared/word_utils.dart';

class WordCard extends StatelessWidget {
  final WordEntry entry;

  const WordCard({super.key, required this.entry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 单词和音标
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  entry.word,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: colorScheme.primary,
                  ),
                ),
                if (entry.phonetic != null && entry.phonetic!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Text(
                      '/${entry.phonetic}/',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                const Spacer(),
                // 朗读按钮
                IconButton(
                  icon: Icon(Icons.volume_up, color: colorScheme.primary),
                  tooltip: '朗读',
                  onPressed: () async {
                    final success = await TtsService.instance.speak(entry.word);
                    if (!success && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('朗读失败：请检查网络连接或系统语音设置'),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    }
                  },
                ),
              ],
            ),

            // 柯林斯星级和考试标签
            if (entry.collins != null && entry.collins! > 0 ||
                entry.tags.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    if (entry.collins != null && entry.collins! > 0)
                      Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: Text(
                          entry.collinsStars,
                          style: TextStyle(
                            color: Colors.amber.shade600,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ...entry.tags.map(
                      (tag) => Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Chip(
                          label: Text(
                            tag.toUpperCase(),
                            style: TextStyle(
                              fontSize: 11,
                              color: colorScheme.primary,
                            ),
                          ),
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

            const SizedBox(height: 16),

            // 中文释义
            if (entry.translation != null && entry.translation!.isNotEmpty)
              _Section(
                title: '释义',
                child: Text(
                  normalizeNewlines(entry.translation),
                  style: theme.textTheme.bodyLarge,
                ),
              ),

            // 英文释义
            if (entry.definition != null && entry.definition!.isNotEmpty)
              _Section(
                title: '英文释义',
                child: Text(
                  normalizeNewlines(entry.definition),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),

            // 词形变化
            if (entry.exchangeMap.isNotEmpty)
              _Section(
                title: '词形变化',
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: entry.exchangeMap.entries.map((e) {
                    return _ExchangeTag(label: e.key, value: e.value);
                  }).toList(),
                ),
              ),

            // 词频信息
            if (entry.bnc != null || entry.frq != null)
              _Section(
                title: '词频',
                child: Row(
                  children: [
                    if (entry.bnc != null)
                      Padding(
                        padding: const EdgeInsets.only(right: 16),
                        child: Text(
                          'BNC #${entry.bnc}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    if (entry.frq != null)
                      Text(
                        'FRQ #${entry.frq}',
                        style: theme.textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final Widget child;

  const _Section({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          child,
        ],
      ),
    );
  }
}

class _ExchangeTag extends StatelessWidget {
  final String label;
  final String value;

  static const _labels = {
    'p': '过去式',
    'd': '过去分词',
    'i': '现在分词',
    '3': '三单',
    'r': '比较级',
    't': '最高级',
    's': '复数',
    '0': '词元',
  };

  const _ExchangeTag({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final displayLabel = _labels[label] ?? label;
    return Tooltip(
      message: displayLabel,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          value,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
