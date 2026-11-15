import 'package:aquamarina/models/word_book.dart';
import 'package:aquamarina/services/ai/tools/app_tools.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('回归：词书行渲染', () {
    test('输出真实标题，而不是 Instance of', () {
      final book = WordBook(
        id: 1,
        title: '大学英语四级核心词',
        wordCount: 417,
        isBuiltin: false,
      );
      final line = AppTools.describeBookLine(book);

      expect(line, contains('大学英语四级核心词'));
      expect(line, contains('417 个单词'));
      expect(line, contains('id=1'));

      // 这条曾因 `$b.title` 被解析成 `${b}.title` 而退化
      expect(line, isNot(contains('Instance of')));
      expect(line, isNot(contains('.title')));
      expect(line, isNot(contains('WordBook')));
    });

    test('内置词书带标记', () {
      final line = AppTools.describeBookLine(
        WordBook(id: 12, title: '雅思高频', wordCount: 417, isBuiltin: true),
      );
      expect(line, contains('雅思高频'));
      expect(line, contains('（内置）'));
      expect(line, isNot(contains('Instance of')));
    });

    test('标题含特殊字符也原样输出', () {
      final line = AppTools.describeBookLine(
        WordBook(id: 13, title: '新人教版 · 九年级（上）', wordCount: 417),
      );
      expect(line, contains('新人教版 · 九年级（上）'));
    });
  });
}
