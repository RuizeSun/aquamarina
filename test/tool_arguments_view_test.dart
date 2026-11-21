import 'package:aquamarina/widgets/chat/tool_arguments_view.dart';
import 'package:flutter_test/flutter_test.dart';

/// 批准面板 / 工具卡片的参数展示回归测试。
///
/// 背景：这里曾经直接把模型给的 JSON 原样甩给用户。用户要在「批准」前看懂
/// 究竟会改什么，所以展示必须是中文语义摘要，而不是一串花括号。
void main() {
  ToolArgumentDigest digest(
    String name,
    Map<String, dynamic> arguments, {
    String? bookTitle,
    bool parseError = false,
  }) => describeToolArguments(
    toolName: name,
    arguments: arguments,
    rawArguments: arguments.isEmpty ? '' : '{"raw":true}',
    parseError: parseError,
    bookTitle: bookTitle,
  );

  test('写工具给出可读的一句话摘要与细节', () {
    final add = digest('add_words_to_word_book', {
      'book_id': 3,
      'words': ['apple', 'banana'],
    }, bookTitle: '四级词汇');
    expect(add.summary, '向词书 #3（四级词汇）添加 2 个单词');
    expect(add.fields.single.items, ['apple', 'banana']);

    final note = digest('set_word_note', {'word': 'apple', 'note': '苹果'});
    expect(note.summary, '为「apple」写入笔记');
    expect(note.fields.single.value, '苹果');

    final clear = digest('set_word_note', {'word': 'apple', 'note': ''});
    expect(clear.summary, '清除「apple」的笔记');

    expect(
      digest('set_word_favorite', {'word': 'apple', 'favorite': true}).summary,
      '收藏「apple」',
    );
    expect(
      digest('set_word_favorite', {'word': 'apple', 'favorite': false}).summary,
      '取消收藏「apple」',
    );
  });

  test('只读工具翻译成查询意图', () {
    expect(
      digest('search_dictionary', {'word': 'apple'}).summary,
      '查词典「apple」',
    );
    expect(
      digest('get_word_book_words', {
        'book_id': 3,
        'limit': 50,
      }, bookTitle: '四级词汇').summary,
      '从词书 #3（四级词汇）读取单词',
    );
    expect(digest('get_learning_stats', {}).summary, '无需额外参数');
  });

  test('词书标题缺失时回退为纯 id', () {
    final result = digest('get_word_book_words', {'book_id': 9});
    expect(result.summary, '从词书 #9读取单词');
  });

  test('非法 JSON 回退原始文本', () {
    final result = digest(
      'set_word_note',
      const {},
      parseError: true,
    );
    expect(result.summary, isNull);
    expect(result.rawFallback, isNotNull);
  });

  test('未知工具按中文标签逐字段展示而不是 JSON', () {
    final result = digest('some_new_tool', {
      'word': 'apple',
      'words': ['a', 'b'],
      'favorite': true,
    });
    expect(result.summary, isNull);
    expect(result.fields.map((f) => f.label), ['单词', '单词列表', '收藏']);
    expect(result.fields.last.value, '是');
  });
}
