import 'package:aquamarina/widgets/chat/chat_labels.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChatLabels', () {
    test('已知工具名本地化为中文', () {
      expect(ChatLabels.tool('search_dictionary'), '查词典');
      expect(ChatLabels.tool('set_word_note'), '写入单词笔记');
    });

    test('未知工具名回退为原名', () {
      expect(ChatLabels.tool('brand_new_tool'), 'brand_new_tool');
    });

    test('上下文分块名本地化并按序拼接', () {
      expect(
        ChatLabels.contextTags(const ['runtime-context', 'time-context']),
        '运行环境 + 当前时间',
      );
      expect(
        ChatLabels.contextTags(const ['whatever-context']),
        'whatever-context',
      );
    });

    test('写操作与只读工具使用不同图标', () {
      expect(
        ChatLabels.toolIcon('search_dictionary'),
        isNot(ChatLabels.toolIcon('set_word_favorite')),
      );
    });
  });
}
