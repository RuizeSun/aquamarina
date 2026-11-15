import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../models/word_book.dart';
import '../../data/database_service.dart';
import '../../data/dictionary_service.dart';
import '../../data/learning_service.dart';
import '../../data/word_book_service.dart';
import '../../data/word_note_service.dart';
import '../ai_sentence_set_service.dart';
import 'ai_tool.dart';

/// App 内置工具集。
///
/// 约定：
/// - 只读工具用 [AiToolRisk.readOnly]，可在设置里开启「自动批准」后直接执行；
/// - 会改数据的工具用 [AiToolRisk.mutating]，**每次**都要用户批准；
/// - 返回值统一是紧凑的中文文本，便于模型直接引用，同时附带结构化 `data`。
class AppTools {
  AppTools._();

  /// 构造全部工具。允许注入依赖以便测试，但默认都走真实服务。
  static List<AiToolDescriptor> build({
    Future<PackageInfo> Function()? packageInfoLoader,
    int Function()? schemaVersionLoader,
  }) {
    final loadPackageInfo =
        packageInfoLoader ?? () => PackageInfo.fromPlatform();
    final loadSchemaVersion =
        schemaVersionLoader ?? (() => DatabaseService.schemaVersion);

    return [
      _searchDictionary(),
      _listWordBooks(),
      _getWordBookWords(),
      _getLearningStats(),
      _getDueReviews(),
      _listSentenceSets(),
      _getWordNotes(),
      _getAppInfo(loadPackageInfo, loadSchemaVersion),
      _addWordsToWordBook(),
      _setWordNote(),
      _setWordFavorite(),
    ];
  }

  // ── 只读工具 ──────────────────────────────────────

  static AiToolDescriptor _searchDictionary() => AiToolDescriptor(
    name: 'search_dictionary',
    description:
        '查询内置离线词典。传入英文单词或中文词语，返回音标、释义与词性等信息。'
        '查不到时返回未找到。',
    risk: AiToolRisk.readOnly,
    parameters: {
      'type': 'object',
      'properties': {
        'word': {'type': 'string', 'description': '要查询的英文单词或中文词语'},
      },
      'required': ['word'],
    },
    execute: (args) async {
      final arg = AiToolArgs(args);
      final word = arg.requireString('word', maxLength: 64);
      final result = await DictionaryService.searchAllExact(word);

      if (!result.hasAny) {
        return AiToolResult.success('词典中未找到 "$word"。', data: {'found': false});
      }

      final lines = <String>[];
      final data = <String, dynamic>{'found': true, 'query': word};

      final en = result.enEntry;
      if (en != null) {
        final phonetic = en.phonetic;
        lines.add(
          '【英文词条】${en.word}${phonetic == null || phonetic.isEmpty ? '' : ' /$phonetic/'}',
        );
        if (en.pos != null && en.pos!.isNotEmpty) lines.add('词性: ${en.pos}');
        if (en.translation != null && en.translation!.isNotEmpty) {
          lines.add('中文释义: ${_oneLine(en.translation!)}');
        }
        if (en.definition != null && en.definition!.isNotEmpty) {
          lines.add('英文释义: ${_oneLine(en.definition!)}');
        }
        if (en.exchange != null && en.exchange!.isNotEmpty) {
          lines.add('词形变化: ${en.exchange}');
        }
        data['en'] = {
          'word': en.word,
          'phonetic': en.phonetic,
          'translation': en.translation,
          'definition': en.definition,
        };
      }

      final cn = result.cnEntry;
      if (cn != null) {
        lines.add(
          '【中英词条】${cn.simplified}'
          '${cn.pinyin == null || cn.pinyin!.isEmpty ? '' : '（${cn.pinyin}）'}',
        );
        lines.add('含义: ${_oneLine(cn.definitions)}');
        data['cn'] = {
          'simplified': cn.simplified,
          'traditional': cn.traditional,
          'pinyin': cn.pinyin,
          'definitions': cn.definitions,
        };
      }

      return AiToolResult.success(lines.join('\n'), data: data);
    },
  );

  /// 把一本书渲染成一行纯文本。
  ///
  /// 单独抽出来便于测试：这里曾写成 `$b.title`，Dart 会解析成
  /// `${b}.title`，于是模型看到的是 `Instance of 'WordBook'.title`。
  @visibleForTesting
  static String describeBookLine(WordBook book) {
    final tag = book.isBuiltin ? '（内置）' : '';
    return '- id=${book.id} ${book.title}$tag：${book.wordCount} 个单词';
  }

  static AiToolDescriptor _listWordBooks() => AiToolDescriptor(
    name: 'list_word_books',
    description: '列出用户本地的全部词书（id、标题、单词数量、是否内置）。',
    risk: AiToolRisk.readOnly,
    parameters: {'type': 'object', 'properties': {}},
    execute: (args) async {
      final books = await WordBookService.getAllBooks();
      if (books.isEmpty) {
        return AiToolResult.success('本机还没有任何词书。', data: {'books': []});
      }
      final rows = books.map(describeBookLine).toList();
      return AiToolResult.success(
        '共 ${books.length} 本词书：\n${rows.join('\n')}',
        data: {
          'books': [
            for (final b in books)
              {
                'id': b.id,
                'title': b.title,
                'word_count': b.wordCount,
                'is_builtin': b.isBuiltin,
              },
          ],
        },
      );
    },
  );

  static AiToolDescriptor _getWordBookWords() => AiToolDescriptor(
    name: 'get_word_book_words',
    description: '读取指定词书中的单词列表（按 id 指定词书，可用 list_word_books 获取 id）。',
    risk: AiToolRisk.readOnly,
    parameters: {
      'type': 'object',
      'properties': {
        'book_id': {'type': 'integer', 'description': '词书 id'},
        'limit': {'type': 'integer', 'description': '最多返回多少个单词，默认 100'},
      },
      'required': ['book_id'],
    },
    execute: (args) async {
      final arg = AiToolArgs(args);
      final bookId = arg.requireInt('book_id', min: 1);
      final limit = arg.optionalInt('limit', fallback: 100, min: 1, max: 500);
      final all = await WordBookService.getBookWords(bookId);
      final words = all.take(limit).toList(growable: false);
      if (words.isEmpty) {
        return AiToolResult.success(
          '词书 $bookId 中还没有单词。',
          data: {'book_id': bookId, 'words': []},
        );
      }
      return AiToolResult.success(
        '词书 $bookId 共 ${all.length} 个单词，前 ${words.length} 个：\n${words.join(', ')}',
        data: {
          'book_id': bookId,
          'total': all.length,
          'words': words,
        },
      );
    },
  );

  static AiToolDescriptor _getLearningStats() => AiToolDescriptor(
    name: 'get_learning_stats',
    description: '获取用户今天的学习统计：已学/已复习单词数、待复习数、错词数、连续打卡天数与今日目标进度。',
    risk: AiToolRisk.readOnly,
    parameters: {'type': 'object', 'properties': {}},
    execute: (args) async {
      final stats = await LearningService.getDailyStats();
      final streak = await LearningService.getStreak();
      final goal = await LearningService.getTodayGoalProgress();

      final learned = (goal['learned'] as int?) ?? 0;
      final goalTarget = (goal['goal'] as int?) ?? 0;
      final completed = (goal['completed'] as bool?) ?? false;

      final text = [
        '今日已学新词: ${stats.todayLearnedCount}',
        '今日已复习: ${stats.todayReviewedCount}',
        '待复习单词: ${stats.dueReviewCount}',
        '今日错词: ${stats.wrongWordCount}',
        '今日错句: ${stats.wrongSentenceCount}',
        '连续打卡: $streak 天',
        '今日目标: $learned/$goalTarget${completed ? '（已达成）' : ''}',
      ].join('\n');

      return AiToolResult.success(text, data: {
        'today_learned': stats.todayLearnedCount,
        'today_reviewed': stats.todayReviewedCount,
        'due_reviews': stats.dueReviewCount,
        'wrong_words': stats.wrongWordCount,
        'wrong_sentences': stats.wrongSentenceCount,
        'streak': streak,
        'goal_learned': learned,
        'goal_target': goalTarget,
        'goal_completed': completed,
      });
    },
  );

  static AiToolDescriptor _getDueReviews() => AiToolDescriptor(
    name: 'get_due_reviews',
    description: '列出当前待复习的单词（按复习计划排序）。',
    risk: AiToolRisk.readOnly,
    parameters: {
      'type': 'object',
      'properties': {
        'limit': {'type': 'integer', 'description': '最多返回多少个单词，默认 50'},
      },
    },
    execute: (args) async {
      final arg = AiToolArgs(args);
      final limit = arg.optionalInt('limit', fallback: 50, min: 1, max: 200);
      final due = await LearningService.getAllDueWords();
      if (due.isEmpty) {
        return AiToolResult.success('当前没有待复习的单词。', data: {'words': []});
      }
      final words = due.take(limit).toList(growable: false);
      return AiToolResult.success(
        '待复习 ${due.length} 个单词，前 ${words.length} 个：\n${words.join(', ')}',
        data: {'total': due.length, 'words': words},
      );
    },
  );

  static AiToolDescriptor _listSentenceSets() => AiToolDescriptor(
    name: 'list_sentence_sets',
    description: '列出用户的 AI 句式集（名称、句数），用于句型练习相关提问。',
    risk: AiToolRisk.readOnly,
    parameters: {'type': 'object', 'properties': {}},
    execute: (args) async {
      final service = SentenceSetService.instance;
      if (!service.loaded) {
        await service.load();
      }
      final sets = service.sets;
      if (sets.isEmpty) {
        return AiToolResult.success('还没有句式集。', data: {'sets': []});
      }
      final rows = sets
          .map((s) => '- ${s.name}（${s.sentenceCount} 句）')
          .toList();
      return AiToolResult.success(
        '共 ${sets.length} 个句式集：\n${rows.join('\n')}',
        data: {
          'sets': [
            for (final s in sets)
              {'id': s.id, 'name': s.name, 'sentence_count': s.sentenceCount},
          ],
        },
      );
    },
  );

  static AiToolDescriptor _getWordNotes() => AiToolDescriptor(
    name: 'get_word_notes',
    description: '读取用户的单词笔记与收藏；可传 query 做模糊筛选。',
    risk: AiToolRisk.readOnly,
    parameters: {
      'type': 'object',
      'properties': {
        'query': {'type': 'string', 'description': '可选，按单词或笔记内容筛选'},
        'limit': {'type': 'integer', 'description': '最多返回多少条，默认 30'},
      },
    },
    execute: (args) async {
      final arg = AiToolArgs(args);
      final query = arg.optionalString('query', maxLength: 64);
      final limit = arg.optionalInt('limit', fallback: 30, min: 1, max: 100);
      final notes = query == null
          ? await WordNoteService.getNotes()
          : await WordNoteService.searchNotes(query);
      if (notes.isEmpty) {
        return AiToolResult.success(
          query == null ? '还没有单词笔记。' : '没有匹配 "$query" 的笔记。',
          data: {'notes': []},
        );
      }
      final picked = notes.take(limit).toList(growable: false);
      final rows = picked
          .map(
            (n) =>
                '- ${n.word}${n.isFavorited ? ' ★' : ''}${n.note == null || n.note!.isEmpty ? '' : '：${_oneLine(n.note!)}'}',
          )
          .toList();
      return AiToolResult.success(
        '共 ${notes.length} 条笔记，展示 ${picked.length} 条：\n${rows.join('\n')}',
        data: {
          'total': notes.length,
          'notes': [
            for (final n in picked)
              {
                'word': n.word,
                'note': n.note,
                'is_favorited': n.isFavorited,
              },
          ],
        },
      );
    },
  );

  static AiToolDescriptor _getAppInfo(
    Future<PackageInfo> Function() loadPackageInfo,
    int Function() loadSchemaVersion,
  ) => AiToolDescriptor(
    name: 'get_app_info',
    description: '获取 App 版本、数据库 schema 版本等基础信息，用于排查问题或回答产品相关问题。',
    risk: AiToolRisk.readOnly,
    parameters: {'type': 'object', 'properties': {}},
    execute: (args) async {
      String version = '未知';
      String build = '';
      try {
        final info = await loadPackageInfo();
        version = info.version;
        build = info.buildNumber;
      } catch (_) {
        // 测试或平台不支持时降级为未知
      }
      final schema = loadSchemaVersion();
      return AiToolResult.success(
        'App 版本: $version${build.isEmpty ? '' : '+$build'}\n数据库 schema: v$schema',
        data: {'version': version, 'build': build, 'schema_version': schema},
      );
    },
  );

  // ── 写工具（每次都需要用户批准） ────────────────

  static AiToolDescriptor _addWordsToWordBook() => AiToolDescriptor(
    name: 'add_words_to_word_book',
    description:
        '把一批单词加入指定词书（会自动去重）。这是修改用户数据的操作，需要用户批准。',
    risk: AiToolRisk.mutating,
    parameters: {
      'type': 'object',
      'properties': {
        'book_id': {'type': 'integer', 'description': '目标词书 id'},
        'words': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': '要添加的单词列表',
        },
      },
      'required': ['book_id', 'words'],
    },
    execute: (args) async {
      final arg = AiToolArgs(args);
      final bookId = arg.requireInt('book_id', min: 1);
      final words = arg.requireStringList('words');
      final added = await WordBookService.addWordsToBook(bookId, words);
      return AiToolResult.success(
        '已向词书 $bookId 添加 $added 个单词（提交 ${words.length} 个）。',
        data: {'book_id': bookId, 'submitted': words.length, 'added': added},
      );
    },
  );

  static AiToolDescriptor _setWordNote() => AiToolDescriptor(
    name: 'set_word_note',
    description:
        '为某个单词保存或覆盖笔记（传空字符串表示删除笔记）。这是修改用户数据的操作，需要用户批准。',
    risk: AiToolRisk.mutating,
    parameters: {
      'type': 'object',
      'properties': {
        'word': {'type': 'string', 'description': '单词'},
        'note': {'type': 'string', 'description': '笔记内容；空字符串表示清除'},
      },
      'required': ['word', 'note'],
    },
    execute: (args) async {
      final arg = AiToolArgs(args);
      final word = arg.requireString('word', maxLength: 64);
      final note = arg.optionalString('note', maxLength: 2000) ?? '';
      await WordNoteService.saveNote(word, note);
      return AiToolResult.success(
        note.isEmpty ? '已清除 "$word" 的笔记。' : '已保存 "$word" 的笔记。',
        data: {'word': word, 'note': note},
      );
    },
  );

  static AiToolDescriptor _setWordFavorite() => AiToolDescriptor(
    name: 'set_word_favorite',
    description: '收藏或取消收藏某个单词。这是修改用户数据的操作，需要用户批准。',
    risk: AiToolRisk.mutating,
    parameters: {
      'type': 'object',
      'properties': {
        'word': {'type': 'string', 'description': '单词'},
        'favorite': {'type': 'boolean', 'description': 'true 收藏，false 取消收藏'},
      },
      'required': ['word', 'favorite'],
    },
    execute: (args) async {
      final arg = AiToolArgs(args);
      final word = arg.requireString('word', maxLength: 64);
      final favorite = arg.requireBool('favorite');
      await WordNoteService.setFavorite(word, favorite: favorite);
      return AiToolResult.success(
        favorite ? '已收藏 "$word"。' : '已取消收藏 "$word"。',
        data: {'word': word, 'favorite': favorite},
      );
    },
  );

  // ── 内部 ──────────────────────────────────────────

  static String _oneLine(String text) =>
      text.replaceAll(RegExp(r'\s+'), ' ').trim();
}
