import 'package:flutter/material.dart';
import '../../../models/word_entry.dart';
import '../../../services/tts_service.dart';
import 'word_utils.dart';

/// 回忆阶段1：显示单词，提示用户回忆含义
class RecallPhase1View extends StatefulWidget {
  final String word;
  final String hintText;
  final bool autoRead;

  const RecallPhase1View({
    super.key,
    required this.word,
    this.hintText = '请回忆这个词的含义：',
    this.autoRead = false,
  });

  @override
  State<RecallPhase1View> createState() => _RecallPhase1ViewState();
}

class _RecallPhase1ViewState extends State<RecallPhase1View> {
  @override
  void initState() {
    super.initState();
    if (widget.autoRead && widget.word.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        TtsService.instance.speak(widget.word);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Spacer(flex: 2),

        Text(
          widget.hintText,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 32),

        Text(
          widget.word,
          style: theme.textTheme.displayLarge?.copyWith(
            fontWeight: FontWeight.bold,
            color: colorScheme.primary,
          ),
          textAlign: TextAlign.center,
        ),

        const Spacer(flex: 3),
      ],
    );
  }
}

/// 回忆阶段2：显示单词 + 音标 + 释义，供用户核对自己的记忆
class RecallPhase2View extends StatelessWidget {
  final String word;
  final WordEntry? entry;
  final bool hasDefinition;
  final String confirmText;

  const RecallPhase2View({
    super.key,
    required this.word,
    required this.entry,
    required this.hasDefinition,
    this.confirmText = '确认你的记忆：',
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final phonetic = entry?.phonetic;
    final translation = entry?.translation;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Spacer(flex: 1),

        Text(
          word,
          style: theme.textTheme.displayMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: colorScheme.primary,
          ),
          textAlign: TextAlign.center,
        ),

        const SizedBox(height: 12),

        if (phonetic != null && phonetic.isNotEmpty)
          Text(
            '/$phonetic/',
            style: theme.textTheme.titleLarge?.copyWith(
              color: colorScheme.onSurfaceVariant,
              fontStyle: FontStyle.italic,
            ),
          ),

        const SizedBox(height: 20),

        if (hasDefinition && translation != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              normalizeNewlines(translation),
              style: theme.textTheme.bodyLarge,
              textAlign: TextAlign.center,
            ),
          ),

        const SizedBox(height: 24),

        Text(
          confirmText,
          style: theme.textTheme.titleSmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),

        const Spacer(flex: 2),
      ],
    );
  }
}
