import 'package:flutter/material.dart';

/// 对话界面的本地化名称表。
///
/// 工具名（search_dictionary）与上下文分块名（runtime-context）都是模型协议里的
/// 标识符，直接展示等于把协议细节漏给用户。这里统一做一次中文映射；遇到未知
/// 名字时回退成原名，保证协议演进不会把 UI 撑坏。
class ChatLabels {
  ChatLabels._();

  static const Map<String, String> _tools = <String, String>{
    'search_dictionary': '查词典',
    'list_word_books': '查看词书',
    'get_word_book_words': '读取词书单词',
    'get_learning_stats': '学习统计',
    'get_due_reviews': '待复习单词',
    'list_sentence_sets': '查看句式集',
    'get_word_notes': '查看单词笔记',
    'get_app_info': '查看应用信息',
    'add_words_to_word_book': '添加单词到词书',
    'set_word_note': '写入单词笔记',
    'set_word_favorite': '收藏单词',
    'system': '系统提示',
  };

  static const Map<String, String> _contextTags = <String, String>{
    'runtime-context': '运行环境',
    'time-context': '当前时间',
    'user-context': '用户信息',
    'learning-context': '学习状态',
  };

  /// 工具名 → 中文动作名。
  static String tool(String name) => _tools[name] ?? name;

  /// 上下文分块名 → 中文名称。
  static String contextTag(String tag) => _contextTags[tag] ?? tag;

  /// 多个分块名拼成「运行环境 + 当前时间」。
  static String contextTags(Iterable<String> tags) =>
      tags.map(contextTag).join(' + ');

  /// 工具卡片左侧的图标。
  static IconData toolIcon(String name) {
    switch (name) {
      case 'search_dictionary':
        return Icons.menu_book_outlined;
      case 'list_word_books':
      case 'get_word_book_words':
        return Icons.library_books_outlined;
      case 'get_learning_stats':
        return Icons.insights_outlined;
      case 'get_due_reviews':
        return Icons.event_repeat_outlined;
      case 'list_sentence_sets':
        return Icons.format_quote_outlined;
      case 'get_word_notes':
        return Icons.sticky_note_2_outlined;
      case 'get_app_info':
        return Icons.info_outline;
      case 'add_words_to_word_book':
      case 'set_word_note':
      case 'set_word_favorite':
        return Icons.edit_outlined;
      default:
        return Icons.build_outlined;
    }
  }
}
