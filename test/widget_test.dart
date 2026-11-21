import 'package:flutter_test/flutter_test.dart';
import 'package:aquamarina/main.dart';
import 'package:aquamarina/services/data/study_timer_service.dart';
import 'package:aquamarina/pages/vocabulary/shared/word_utils.dart';
import 'package:aquamarina/pages/vocabulary/spelling_page.dart';

void main() {
  testWidgets('App should build', (WidgetTester tester) async {
    await tester.pumpWidget(const AquamarinaApp());
    expect(find.text('搜索'), findsOneWidget);
    expect(find.text('背单词'), findsOneWidget);
    expect(find.text('句型练习'), findsOneWidget);
    // 底部导航第 4 个 tab 为「AI 对话」，第 5 个为「个人」
    expect(find.text('AI 对话'), findsOneWidget);
    expect(find.text('个人'), findsWidgets);
  });

  test('SessionType 包含拼写类型', () {
    expect(SessionType.wordSpelling.value, 'word_spelling');
  });

  group('mapSpellingResult', () {
    test('首拼即对 → easy', () {
      expect(
        mapSpellingResult(firstTryCorrect: true, everCorrect: true),
        'easy',
      );
      expect(
        mapSpellingResult(firstTryCorrect: true, everCorrect: false),
        'easy',
      );
    });

    test('最终拼对但有失误 → hard', () {
      expect(
        mapSpellingResult(firstTryCorrect: false, everCorrect: true),
        'hard',
      );
    });

    test('始终未拼对 → forgot', () {
      expect(
        mapSpellingResult(firstTryCorrect: false, everCorrect: false),
        'forgot',
      );
    });
  });

  group('extractFirstMeaning', () {
    test('提取第一条中文释义', () {
      expect(extractFirstMeaning('n. 苹果；苹果树\nvt. 使…'), '苹果');
    });

    test('去除词性标记', () {
      expect(extractFirstMeaning('v. 运行；行驶'), '运行');
    });

    test('空值返回空串', () {
      expect(extractFirstMeaning(null), '');
      expect(extractFirstMeaning(''), '');
    });
  });

  group('gradeRecallResult', () {
    test('学习页与复习页共用同一判定', () {
      // 没想起来 + 选择题错 → forgot
      expect(gradeRecallResult(recalled: false, quizCorrect: false), 'forgot');
      // 没想起来 + 选择题对 → hard（可能蒙对）
      expect(gradeRecallResult(recalled: false, quizCorrect: true), 'hard');
      // 想起来 + 选择题错 → hard
      expect(gradeRecallResult(recalled: true, quizCorrect: false), 'hard');
      // 想起来 + 选择题对 → easy
      expect(gradeRecallResult(recalled: true, quizCorrect: true), 'easy');
    });

    test('没有选择题时退化为纯回忆判定', () {
      expect(gradeRecallResult(recalled: true), 'easy');
      expect(gradeRecallResult(recalled: false), 'forgot');
    });
  });
}
