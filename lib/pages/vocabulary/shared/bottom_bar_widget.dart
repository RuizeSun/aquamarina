import 'package:flutter/material.dart';

/// 底部操作栏的回调集合
typedef RecallFirstChoiceCallback = void Function(bool remembered);
typedef RecallSecondChoiceCallback = void Function(bool correct);

/// 单词学习/复习流程的底部操作栏
///
/// 包含进度条、阶段对应的操作按钮。
class WordLearningBottomBar extends StatelessWidget {
  final int currentPhase;
  final int globalIndex;
  final int totalWords;
  final bool quizAnswered;
  final bool showingAnswer;
  final VoidCallback? onLearnNext;
  final VoidCallback? onQuizConfirm;
  final RecallFirstChoiceCallback? onRecallFirstChoice;
  final RecallSecondChoiceCallback? onRecallSecondChoice;

  const WordLearningBottomBar({
    super.key,
    required this.currentPhase,
    required this.globalIndex,
    required this.totalWords,
    required this.quizAnswered,
    required this.showingAnswer,
    this.onLearnNext,
    this.onQuizConfirm,
    this.onRecallFirstChoice,
    this.onRecallSecondChoice,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: LinearProgressIndicator(value: (globalIndex + 1) / totalWords),
        ),
        Text(
          '已完成 ${globalIndex + 1}/$totalWords',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),

        if (currentPhase == 0)
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: onLearnNext,
              icon: const Icon(Icons.arrow_forward),
              label: const Text('下一步'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          )
        else if (currentPhase == 1)
          quizAnswered
              ? SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: onQuizConfirm,
                    icon: const Icon(Icons.arrow_forward),
                    label: const Text('继续'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                )
              : const SizedBox.shrink()
        else if (currentPhase == 2 && !showingAnswer)
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => onRecallFirstChoice?.call(false),
                  icon: const Icon(Icons.sentiment_dissatisfied, size: 28),
                  label: const Text('忘记了', style: TextStyle(fontSize: 16)),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    foregroundColor: colorScheme.error,
                    side: BorderSide(color: colorScheme.error),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => onRecallFirstChoice?.call(true),
                  icon: const Icon(Icons.sentiment_satisfied, size: 28),
                  label: const Text('我记得', style: TextStyle(fontSize: 16)),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                  ),
                ),
              ),
            ],
          )
        else if (currentPhase == 2 && showingAnswer)
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => onRecallSecondChoice?.call(false),
                  icon: const Icon(Icons.error_outline, size: 24),
                  label: const Text('记错了', style: TextStyle(fontSize: 16)),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    foregroundColor: Colors.orange,
                    side: const BorderSide(color: Colors.orange),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => onRecallSecondChoice?.call(true),
                  icon: const Icon(Icons.check_circle_outline, size: 24),
                  label: const Text('继续', style: TextStyle(fontSize: 16)),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    backgroundColor: colorScheme.primary,
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }
}
