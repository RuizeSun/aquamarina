import 'package:flutter/material.dart';
import '../../../models/ai_sentence.dart';
import '../../../services/ai_sentence_service.dart';

/// AI 句子练习设置分区
class AiSentenceSettingsSection extends StatefulWidget {
  const AiSentenceSettingsSection({super.key});

  @override
  State<AiSentenceSettingsSection> createState() =>
      _AiSentenceSettingsSectionState();
}

class _AiSentenceSettingsSectionState extends State<AiSentenceSettingsSection> {
  final AiSentenceService _sentenceService = AiSentenceService();
  int _sentenceLimit = 10;
  int _extraWordCount = 3;
  PracticeMode _practiceMode = PracticeMode.beginner;
  bool _isLoading = true;

  // 错题本设置
  int _wrongScoreThreshold = 8;
  bool _skipRepeated = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final limit = await _sentenceService.getSentenceLimit();
    final extra = await _sentenceService.getExtraWordCount();
    final mode = await _sentenceService.getPracticeMode();
    final threshold = await _sentenceService.getWrongScoreThreshold();
    final skip = await _sentenceService.getSkipRepeated();
    if (mounted) {
      setState(() {
        _sentenceLimit = limit;
        _extraWordCount = extra;
        _practiceMode = mode;
        _wrongScoreThreshold = threshold;
        _skipRepeated = skip;
        _isLoading = false;
      });
    }
  }

  void _showSentenceLimitPicker() {
    int temp = _sentenceLimit;
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('单次练习句数'),
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
                          onPressed: temp > 1
                              ? () => setDialogState(() => temp -= 5)
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
                          onPressed: temp < 50
                              ? () => setDialogState(() => temp += 5)
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
                    _sentenceService.setSentenceLimit(temp);
                    setState(() => _sentenceLimit = temp);
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

  void _showExtraWordCountPicker() {
    int temp = _extraWordCount;
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('入门版多余词数量'),
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
                          onPressed: temp > 1
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
                          onPressed: temp < 5
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
                    _sentenceService.setExtraWordCount(temp);
                    setState(() => _extraWordCount = temp);
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

  void _showWrongScoreThresholdPicker() {
    int temp = _wrongScoreThreshold;
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('错题本阈值'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('得分 ≤ 该值的句子自动加入错题本'),
                  const SizedBox(height: 16),
                  Text('当前值: $temp'),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.remove_circle_outline),
                          onPressed: temp > 1
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
                          onPressed: temp < 10
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
                    _sentenceService.setWrongScoreThreshold(temp);
                    setState(() => _wrongScoreThreshold = temp);
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

    if (_isLoading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    return Column(
      children: [
        // 练习模式
        ListTile(
          leading: Icon(Icons.tune, color: colorScheme.primary),
          title: const Text('练习模式'),
          subtitle: Text(
            _practiceMode == PracticeMode.beginner
                ? '入门版（选择词块组句）'
                : '高阶版（自由输入句子）',
          ),
          trailing: SegmentedButton<PracticeMode>(
            segments: const [
              ButtonSegment(value: PracticeMode.beginner, label: Text('入门')),
              ButtonSegment(value: PracticeMode.advanced, label: Text('高阶')),
            ],
            selected: {_practiceMode},
            onSelectionChanged: (selected) {
              final mode = selected.first;
              _sentenceService.setPracticeMode(mode);
              setState(() => _practiceMode = mode);
            },
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ),
        ListTile(
          leading: Icon(Icons.repeat, color: colorScheme.primary),
          title: const Text('单次练习句数'),
          subtitle: Text('每次练习 $_sentenceLimit 句'),
          trailing: Text(
            '$_sentenceLimit',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: colorScheme.primary,
            ),
          ),
          onTap: _showSentenceLimitPicker,
        ),
        if (_practiceMode == PracticeMode.beginner)
          ListTile(
            leading: Icon(Icons.layers, color: colorScheme.primary),
            title: const Text('入门版多余词数量'),
            subtitle: Text('$_extraWordCount 个干扰词'),
            trailing: Text(
              '$_extraWordCount',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: colorScheme.primary,
              ),
            ),
            onTap: _showExtraWordCountPicker,
          ),
        const Divider(),
        // 错题本设置
        ListTile(
          leading: Icon(Icons.error_outline, color: colorScheme.primary),
          title: const Text('错题本阈值'),
          subtitle: Text('得分 ≤ $_wrongScoreThreshold 分时加入错题本'),
          trailing: Text(
            '$_wrongScoreThreshold',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: colorScheme.primary,
            ),
          ),
          onTap: _showWrongScoreThresholdPicker,
        ),
        SwitchListTile(
          secondary: Icon(
            Icons.replay_circle_filled,
            color: colorScheme.primary,
          ),
          title: const Text('不重复练习'),
          subtitle: const Text('已练习正确的句子不再出现'),
          value: _skipRepeated,
          onChanged: (value) {
            _sentenceService.setSkipRepeated(value);
            setState(() => _skipRepeated = value);
          },
        ),
      ],
    );
  }
}
