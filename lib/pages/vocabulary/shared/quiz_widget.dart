import 'package:flutter/material.dart';

class QuizPhaseView extends StatelessWidget {
  final String word;
  final List<String> options;
  final int correctOptionIndex;
  final int? selectedOption;
  final bool isAnswered;
  final String hintText;
  final void Function(int optionIndex) onSelect;

  const QuizPhaseView({
    super.key,
    required this.word,
    required this.options,
    required this.correctOptionIndex,
    required this.selectedOption,
    required this.isAnswered,
    required this.hintText,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final colors = [
      colorScheme.primary,
      Colors.orange,
      Colors.teal,
      Colors.deepPurple,
    ];

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

        const SizedBox(height: 16),

        Text(
          hintText,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),

        const SizedBox(height: 24),

        ...List.generate(options.length, (i) {
          final isSelected = selectedOption == i;
          final isCorrectOption = i == correctOptionIndex;
          Color? bgColor;
          Color? borderColor;
          Color textColor = colorScheme.onSurface;

          if (isAnswered) {
            if (isCorrectOption) {
              bgColor = Colors.green.withValues(alpha: 0.15);
              borderColor = Colors.green;
              textColor = Colors.green.shade700;
            } else if (isSelected && !isCorrectOption) {
              bgColor = Colors.red.withValues(alpha: 0.1);
              borderColor = Colors.red;
              textColor = Colors.red.shade700;
            }
          } else if (isSelected) {
            bgColor = colorScheme.primaryContainer;
            borderColor = colorScheme.primary;
          }

          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: isAnswered ? null : () => onSelect(i),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: bgColor,
                  side: BorderSide(
                    color: borderColor ?? colorScheme.outline,
                    width: isSelected ? 2 : 1,
                  ),
                  foregroundColor: textColor,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: colors[i % colors.length].withValues(
                          alpha: isAnswered ? 0.15 : 0.2,
                        ),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        ['A', 'B', 'C', 'D'][i],
                        style: TextStyle(
                          color: colors[i % colors.length],
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                        textScaler: TextScaler.noScaling,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        options[i],
                        style: const TextStyle(fontSize: 16),
                        textScaler: TextScaler.noScaling,
                      ),
                    ),
                    if (isAnswered && isCorrectOption)
                      const Icon(Icons.check_circle, color: Colors.green),
                    if (isAnswered && isSelected && !isCorrectOption)
                      const Icon(Icons.cancel, color: Colors.red),
                  ],
                ),
              ),
            ),
          );
        }),

        const Spacer(flex: 2),
      ],
    );
  }
}
