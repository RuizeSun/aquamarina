import 'package:flutter/material.dart';
import '../../services/study_timer_service.dart';
import 'shared/word_session_base.dart';
import 'shared/word_utils.dart';

/// 学习类型：新词学习（第二遍）或复习
enum ReviewType { learning, review }

/// 复习/二次学习页面：分词批浏览 → 选择题 → 回忆 → 总结
class ReviewPage extends WordSessionPage {
  @override
  final List<String> words;

  @override
  final int bookId;
  final ReviewType reviewType;

  const ReviewPage({
    super.key,
    required this.words,
    required this.bookId,
    this.reviewType = ReviewType.learning,
  });

  @override
  State<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends WordSessionBaseState<ReviewPage> {
  // ─── 差异配置 ─────────────────────────────────

  @override
  SessionType get sessionType => SessionType.wordReview;

  @override
  bool get isReview => widget.reviewType == ReviewType.review;

  @override
  String get exitTitle => '退出复习';

  @override
  String get exitMessage => '退出后将不保存本次复习进度，确定退出吗？';

  @override
  String get summaryTitle =>
      widget.reviewType == ReviewType.review ? '复习完成！' : '学习完成！';

  @override
  IconData get summaryIcon => widget.reviewType == ReviewType.review
      ? Icons.thumb_up
      : Icons.emoji_events;

  @override
  String get recallHint => '回想这个词的含义：';

  @override
  String get recallConfirmText => '核对你的记忆：';

  @override
  String get quizHint => '选择正确的释义：';

  @override
  bool get showCloseButton => true;

  // ─── 阶段 0：浏览阶段 ────────────────────────

  @override
  Widget buildPhase0(ThemeData theme, ColorScheme colorScheme) {
    final word = currentWord;
    final entry = entryCache[globalIndex];
    final phonetic = entry?.phonetic;
    final translation = entry?.translation;
    final definition = entry?.definition;
    final hasDefinition = translation != null && translation.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Spacer(flex: 2),

        // 单词
        Text(
          word,
          style: theme.textTheme.displayMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: colorScheme.primary,
          ),
          textAlign: TextAlign.center,
        ),

        const SizedBox(height: 12),

        // 音标
        if (phonetic != null && phonetic.isNotEmpty)
          Text(
            '/$phonetic/',
            style: theme.textTheme.titleLarge?.copyWith(
              color: colorScheme.onSurfaceVariant,
              fontStyle: FontStyle.italic,
            ),
          ),

        const SizedBox(height: 20),

        // 中文释义
        if (hasDefinition)
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

        const SizedBox(height: 16),

        // 英文释义
        if (definition != null && definition.isNotEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(color: colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              normalizeNewlines(definition),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
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

  // ─── 回忆阶段 2：结合选择题结果的高级判定 ─────

  @override
  Future<void> onRecallSecondChoice(bool correct) async {
    completedSteps++;
    final word = currentWord.trim().toLowerCase();
    final quizCorrect = selectedQuizOption == correctOptionIndex;

    String result;
    if (firstChoice == false) {
      // 一开始就没想起来
      // 选择题选对 → 可能是蒙对的，hard；选错 → 彻底忘记，forgot
      result = quizCorrect ? 'hard' : 'forgot';
    } else if (!correct) {
      // 自以为记得但实际错了 → 掌握不牢
      result = 'hard';
    } else {
      // 确实想对了，再参考选择题确认是否真正掌握
      result = quizCorrect ? 'easy' : 'hard';
    }
    results[word] = result;

    await advanceAfterResult();
  }
}
