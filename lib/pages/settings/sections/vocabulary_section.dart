import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 背单词设置分区（复习上限、询问词书、学习上限）
class VocabularySection extends StatefulWidget {
  const VocabularySection({super.key});

  @override
  State<VocabularySection> createState() => _VocabularySectionState();
}

class _VocabularySectionState extends State<VocabularySection> {
  int _reviewLimit = 10;
  int _learningLimit = 10;
  bool _reviewAskBook = true;
  bool _requireReviewBeforeLearning = true;
  int _dailyGoal = 10;
  bool _quickSpelling = false;

  static const String _reviewLimitKey = 'review_limit';
  static const String _learningLimitKey = 'learning_limit';
  static const String _reviewAskBookKey = 'review_ask_book';
  static const String _requireReviewBeforeLearningKey =
      'require_review_before_learning';
  static const String _dailyGoalKey = 'daily_goal';
  static const String _quickSpellingKey = 'quick_spelling_review_enabled';

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _reviewLimit = prefs.getInt(_reviewLimitKey) ?? 10;
      _learningLimit = prefs.getInt(_learningLimitKey) ?? 10;
      _reviewAskBook = prefs.getBool(_reviewAskBookKey) ?? true;
      _requireReviewBeforeLearning =
          prefs.getBool(_requireReviewBeforeLearningKey) ?? true;
      _dailyGoal = prefs.getInt(_dailyGoalKey) ?? 10;
      _quickSpelling = prefs.getBool(_quickSpellingKey) ?? false;
    });
    await prefs.setInt(_reviewLimitKey, _reviewLimit);
    await prefs.setInt(_learningLimitKey, _learningLimit);
    await prefs.setBool(_reviewAskBookKey, _reviewAskBook);
    await prefs.setBool(
      _requireReviewBeforeLearningKey,
      _requireReviewBeforeLearning,
    );
    await prefs.setInt(_dailyGoalKey, _dailyGoal);
    await prefs.setBool(_quickSpellingKey, _quickSpelling);
  }

  Future<void> _setReviewLimit(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_reviewLimitKey, value);
    setState(() => _reviewLimit = value);
  }

  Future<void> _setLearningLimit(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_learningLimitKey, value);
    setState(() => _learningLimit = value);
  }

  Future<void> _setReviewAskBook(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_reviewAskBookKey, value);
    setState(() => _reviewAskBook = value);
  }

  Future<void> _setRequireReviewBeforeLearning(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_requireReviewBeforeLearningKey, value);
    setState(() => _requireReviewBeforeLearning = value);
  }

  Future<void> _setDailyGoal(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_dailyGoalKey, value);
    setState(() => _dailyGoal = value);
  }

  Future<void> _setQuickSpelling(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_quickSpellingKey, value);
    setState(() => _quickSpelling = value);
  }

  void _showReviewLimitPicker() {
    _showLimitPicker(
      title: '单次复习上限',
      current: _reviewLimit,
      onSave: _setReviewLimit,
    );
  }

  void _showLearningLimitPicker() {
    _showLimitPicker(
      title: '单次学习上限',
      current: _learningLimit,
      onSave: _setLearningLimit,
    );
  }

  void _showDailyGoalPicker() {
    _showLimitPicker(
      title: '每日学习目标',
      current: _dailyGoal,
      onSave: _setDailyGoal,
    );
  }

  void _showLimitPicker({
    required String title,
    required int current,
    required Future<void> Function(int) onSave,
  }) {
    int temp = current;
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(title),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('当前值: $temp'),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.remove_circle_outline),
                          onPressed: temp > 5
                              ? () => setDialogState(() => temp--)
                              : null,
                        ),
                        const SizedBox(width: 16),
                        Text(
                          '$temp',
                          style: Theme.of(context).textTheme.headlineMedium
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(width: 16),
                        IconButton(
                          icon: const Icon(Icons.add_circle_outline),
                          onPressed: temp < 100
                              ? () => setDialogState(() => temp++)
                              : null,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () {
                    onSave(temp);
                    Navigator.of(context).pop();
                  },
                  child: const Text('确认'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Column(
      children: [
        ListTile(
          leading: Icon(Icons.replay, color: colorScheme.primary),
          title: const Text('单次复习上限'),
          subtitle: Text('每次复习最多 $_reviewLimit 个单词'),
          trailing: Text(
            '$_reviewLimit',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: colorScheme.primary,
            ),
          ),
          onTap: _showReviewLimitPicker,
        ),
        SwitchListTile(
          secondary: Icon(Icons.question_answer, color: colorScheme.primary),
          title: const Text('复习前询问词书'),
          subtitle: const Text('多本词书有待复习时，选择先复习哪个词书'),
          value: _reviewAskBook,
          onChanged: _setReviewAskBook,
        ),
        SwitchListTile(
          secondary: Icon(Icons.lock_open, color: colorScheme.primary),
          title: const Text('复习后才能学习新词'),
          subtitle: const Text('有待复习单词时，需先完成复习才能学习新词'),
          value: _requireReviewBeforeLearning,
          onChanged: _setRequireReviewBeforeLearning,
        ),
        SwitchListTile(
          secondary: Icon(Icons.spellcheck, color: colorScheme.primary),
          title: const Text('快速拼写复习'),
          subtitle: const Text('开启后，点击「开始复习」将直接进入拼写模式'),
          value: _quickSpelling,
          onChanged: _setQuickSpelling,
        ),
        ListTile(
          leading: Icon(Icons.auto_stories, color: colorScheme.primary),
          title: const Text('单次学习上限'),
          subtitle: Text('每次学习最多 $_learningLimit 个新词'),
          trailing: Text(
            '$_learningLimit',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: colorScheme.primary,
            ),
          ),
          onTap: _showLearningLimitPicker,
        ),
        const Divider(),
        ListTile(
          leading: Icon(Icons.event_available, color: colorScheme.primary),
          title: const Text('每日学习目标'),
          subtitle: Text('每日学习 $_dailyGoal 个新词即完成打卡'),
          trailing: Text(
            '$_dailyGoal',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: colorScheme.primary,
            ),
          ),
          onTap: _showDailyGoalPicker,
        ),
      ],
    );
  }
}
