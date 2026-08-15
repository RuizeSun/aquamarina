import 'package:flutter/material.dart';
import '../../services/study_timer_service.dart';
import 'shared/word_session_base.dart';
import 'shared/word_utils.dart';

/// 新词学习页面：分词批学习 → 选择题 → 回忆 → 总结
class LearningPage extends WordSessionPage {
  @override
  final List<String> words;

  @override
  final int bookId;

  const LearningPage({super.key, required this.words, required this.bookId});

  @override
  State<LearningPage> createState() => _LearningPageState();
}

class _LearningPageState extends WordSessionBaseState<LearningPage> {
  // ─── 差异配置 ─────────────────────────────────

  @override
  SessionType get sessionType => SessionType.wordLearn;

  @override
  bool get isReview => false;

  @override
  String get exitTitle => '退出学习';

  @override
  String get exitMessage => '退出后将不保存本次学习进度，确定退出吗？';

  @override
  String get summaryTitle => '学习完成！';

  @override
  IconData get summaryIcon => Icons.emoji_events;

  @override
  String get recallHint => '请回忆这个词的含义：';

  @override
  String get recallConfirmText => '确认你的记忆：';

  @override
  String get quizHint => '选择正确的中文意思：';

  @override
  bool get showLoadingIndicator => true;

  // ─── 阶段 0：学习阶段 ────────────────────────

  @override
  Widget buildPhase0(ThemeData theme, ColorScheme colorScheme) {
    final word = currentWord;
    final entry = entryCache[globalIndex];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Spacer(flex: 2),

        Text(
          word,
          style: theme.textTheme.displayMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: colorScheme.primary,
          ),
          textAlign: TextAlign.center,
        ),

        const SizedBox(height: 12),

        if (entry?.phonetic != null && entry!.phonetic!.isNotEmpty)
          Text(
            '/${entry.phonetic}/',
            style: theme.textTheme.titleLarge?.copyWith(
              color: colorScheme.onSurfaceVariant,
              fontStyle: FontStyle.italic,
            ),
          ),

        const SizedBox(height: 24),

        if (entry?.translation != null && entry!.translation!.isNotEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              normalizeNewlines(entry.translation),
              style: theme.textTheme.bodyLarge,
              textAlign: TextAlign.center,
            ),
          ),

        const Spacer(flex: 3),
      ],
    );
  }

  @override
  void onPhase0Next() {
    completedSteps++;
    if (isLastWordInBatch) {
      setState(() {
        phase = 1;
        currentIndexInBatch = 0;
      });
      animController.forward(from: 0);
      generateQuizOptions();
    } else {
      setState(() {
        currentIndexInBatch++;
      });
      animController.forward(from: 0);
      autoReadCurrentWord();
    }
  }

  // ─── 回忆阶段 2：简单判定 ─────────────────────

  @override
  Future<void> onRecallSecondChoice(bool correct) async {
    completedSteps++;
    animController.forward(from: 0);
    final word = currentWord.trim().toLowerCase();

    String result;
    if (firstChoice == false) {
      result = 'forgot';
    } else if (firstChoice == true && correct == false) {
      result = 'hard';
    } else {
      result = 'easy';
    }
    results[word] = result;

    await advanceAfterResult();
  }
}
