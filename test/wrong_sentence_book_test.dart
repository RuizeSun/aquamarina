import 'package:aquamarina/models/ai_sentence.dart';
import 'package:aquamarina/services/ai_sentence_service.dart';
import 'package:aquamarina/services/database_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// v9 版本的错题本建表语句（迁移测试用：模拟升级前的旧库结构）
const String _v9WrongSentencesTableSql = '''
  CREATE TABLE IF NOT EXISTS wrong_sentences (
    id TEXT PRIMARY KEY,
    sentence_id TEXT NOT NULL,
    set_id TEXT NOT NULL,
    english TEXT NOT NULL,
    chinese TEXT NOT NULL,
    score INTEGER NOT NULL,
    user_answer TEXT NOT NULL,
    mode INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL
  )
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  /// 构造一条错题记录（id 用毫秒时间戳，与生产代码一致）
  WrongSentenceRecord buildRecord({
    required String sentenceId,
    required String english,
    required int score,
    required String userAnswer,
    required DateTime at,
    String chinese = '译文',
    String setId = 'set1',
    PracticeMode mode = PracticeMode.advanced,
  }) {
    return WrongSentenceRecord(
      id: at.millisecondsSinceEpoch.toString(),
      sentenceId: sentenceId,
      setId: setId,
      english: english,
      chinese: chinese,
      score: score,
      userAnswer: userAnswer,
      mode: mode,
      createdAt: at,
    );
  }

  /// 使用与生产环境完全一致的 DDL / 索引创建错题本测试库
  Future<Database> openWrongBookDatabase() {
    return databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await db.execute(DatabaseService.wrongSentencesTableSql);
          await db.execute(DatabaseService.wrongSentencesUniqueIndexSql);
        },
      ),
    );
  }

  // ===== 纯逻辑：错题主键 =====
  group('错题主键 wrongSentenceKey', () {
    test('有句子 ID 时直接使用句子 ID', () {
      expect(
        AiSentenceService.wrongSentenceKey(
          sentenceId: 's1',
          english: 'I like apples.',
        ),
        's1',
      );
    });

    test('无句子 ID 时回退到英文原文（与收藏/笔记的稳定键一致）', () {
      expect(
        AiSentenceService.wrongSentenceKey(
          sentenceId: null,
          english: 'I like apples.',
        ),
        'bytext:I like apples.',
      );
      expect(
        AiSentenceService.wrongSentenceKey(
          sentenceId: '',
          english: 'I like apples.',
        ),
        'bytext:I like apples.',
      );
    });

    test('不同句子的空 ID 不会落到同一个键上', () {
      expect(
        AiSentenceService.wrongSentenceKey(sentenceId: '', english: 'A'),
        isNot(
          AiSentenceService.wrongSentenceKey(sentenceId: '', english: 'B'),
        ),
      );
    });
  });

  // ===== 真实 SQLite（ffi 内存库）：合并写入 =====
  group('错题本合并：同一句子多次答错', () {
    const english = "That's very thoughtful of you.";
    final base = DateTime(2026, 9, 19, 0, 12);

    late Database db;
    late AiSentenceService service;

    setUp(() async {
      db = await openWrongBookDatabase();
      service = AiSentenceService(openDatabase: () async => db);
    });

    tearDown(() async {
      await db.close();
    });

    test('同一句子多次答错合并为一条，累计错误次数并保留最近一次结果', () async {
      await service.addWrongSentence(
        buildRecord(
          sentenceId: 's1',
          english: english,
          score: 4,
          userAnswer: 'You think so good!',
          at: base,
        ),
      );
      await service.addWrongSentence(
        buildRecord(
          sentenceId: 's1',
          english: english,
          score: 6,
          userAnswer: 'You think so well.',
          at: base.add(const Duration(minutes: 1)),
          mode: PracticeMode.beginner,
        ),
      );
      await service.addWrongSentence(
        buildRecord(
          sentenceId: 's1',
          english: english,
          score: 3,
          userAnswer: 'You are so good think.',
          at: base.add(const Duration(minutes: 2)),
        ),
      );

      final records = await service.getWrongSentences();
      expect(records, hasLength(1));

      final record = records.single;
      expect(record.wrongCount, 3);
      // 得分 / 回答 / 模式为最近一次
      expect(record.score, 3);
      expect(record.userAnswer, 'You are so good think.');
      expect(record.mode, PracticeMode.advanced);
      // 首次收录时间保持不变，最近答错时间为最后一次
      expect(record.createdAt, base);
      expect(record.latestWrongAt, base.add(const Duration(minutes: 2)));

      expect(await service.getWrongSentenceCount(), 1);
    });

    test('不同句子各自独立计数', () async {
      await service.addWrongSentence(
        buildRecord(
          sentenceId: 's1',
          english: english,
          score: 4,
          userAnswer: 'a',
          at: base,
        ),
      );
      await service.addWrongSentence(
        buildRecord(
          sentenceId: 's2',
          english: 'I like apples.',
          score: 5,
          userAnswer: 'b',
          at: base.add(const Duration(minutes: 1)),
        ),
      );

      final records = await service.getWrongSentences();
      expect(records, hasLength(2));
      expect(records.every((r) => r.wrongCount == 1), isTrue);
    });

    test('无句子 ID 时按英文原文区分，不会误合并', () async {
      await service.addWrongSentence(
        buildRecord(
          sentenceId: '',
          english: 'A',
          score: 4,
          userAnswer: 'a',
          at: base,
        ),
      );
      await service.addWrongSentence(
        buildRecord(
          sentenceId: '',
          english: 'B',
          score: 4,
          userAnswer: 'b',
          at: base.add(const Duration(minutes: 1)),
        ),
      );

      final records = await service.getWrongSentences();
      expect(records, hasLength(2));
      expect(
        records.map((r) => r.sentenceId).toSet(),
        {'bytext:A', 'bytext:B'},
      );
    });

    test('移除无句子 ID 的错题不会误删其它句子', () async {
      await service.addWrongSentence(
        buildRecord(
          sentenceId: '',
          english: 'A',
          score: 4,
          userAnswer: 'a',
          at: base,
        ),
      );
      await service.addWrongSentence(
        buildRecord(
          sentenceId: '',
          english: 'B',
          score: 4,
          userAnswer: 'b',
          at: base.add(const Duration(minutes: 1)),
        ),
      );

      await service.removeWrongSentence(
        AiSentenceService.wrongSentenceKey(sentenceId: '', english: 'A'),
      );

      final records = await service.getWrongSentences();
      expect(records, hasLength(1));
      expect(records.single.english, 'B');
    });

    test('错题本练习再次答错仍只保留一条（按句子 ID 合并）', () async {
      // 第一次：句式集练习答错
      await service.addWrongSentence(
        buildRecord(
          sentenceId: 's1',
          english: english,
          score: 4,
          userAnswer: 'a',
          at: base,
        ),
      );
      // 第二次：错题本练习中以错题记录重建的句子（id = sentenceId）再次答错
      await service.addWrongSentence(
        buildRecord(
          sentenceId: 's1',
          english: english,
          score: 2,
          userAnswer: 'b',
          at: base.add(const Duration(days: 1)),
        ),
      );

      final records = await service.getWrongSentences();
      expect(records, hasLength(1));
      expect(records.single.wrongCount, 2);
      expect(records.single.score, 2);
    });

    test('按最近一次答错时间倒序排列', () async {
      await service.addWrongSentence(
        buildRecord(
          sentenceId: 's1',
          english: 'A',
          score: 4,
          userAnswer: 'a',
          at: base,
        ),
      );
      await service.addWrongSentence(
        buildRecord(
          sentenceId: 's2',
          english: 'B',
          score: 4,
          userAnswer: 'b',
          at: base.add(const Duration(minutes: 5)),
        ),
      );
      // s1 又在更晚的时候答错 → 应排到最前
      await service.addWrongSentence(
        buildRecord(
          sentenceId: 's1',
          english: 'A',
          score: 3,
          userAnswer: 'c',
          at: base.add(const Duration(minutes: 10)),
        ),
      );

      final records = await service.getWrongSentences();
      expect(records.map((r) => r.sentenceId).toList(), ['s1', 's2']);
    });

    test('清空错题本', () async {
      await service.addWrongSentence(
        buildRecord(
          sentenceId: 's1',
          english: english,
          score: 4,
          userAnswer: 'a',
          at: base,
        ),
      );

      await service.clearWrongSentences();
      expect(await service.getWrongSentences(), isEmpty);
      expect(await service.getWrongSentenceCount(), 0);
    });

    test('唯一索引兜底：重复插入同一句子的记录被忽略', () async {
      await service.addWrongSentence(
        buildRecord(
          sentenceId: 's1',
          english: english,
          score: 4,
          userAnswer: 'a',
          at: base,
        ),
      );

      await db.insert('wrong_sentences', {
        'id': 'another-id',
        'sentence_id': 's1',
        'set_id': 'set1',
        'english': english,
        'chinese': '译文',
        'score': 5,
        'user_answer': 'b',
        'mode': 1,
        'created_at': base.toIso8601String(),
        'wrong_count': 1,
        'last_wrong_at': base.toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.ignore);

      expect(await service.getWrongSentenceCount(), 1);
    });
  });

  // ===== v9 → v10 迁移 =====
  group('错题本 v9 → v10 迁移', () {
    late Database db;

    setUp(() async {
      db = await databaseFactory.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, version) async =>
              db.execute(_v9WrongSentencesTableSql),
        ),
      );
    });

    tearDown(() async {
      await db.close();
    });

    Future<void> insertLegacy({
      required String id,
      required String sentenceId,
      required String english,
      required int score,
      required String userAnswer,
      required DateTime at,
    }) {
      return db.insert('wrong_sentences', {
        'id': id,
        'sentence_id': sentenceId,
        'set_id': 'set1',
        'english': english,
        'chinese': '译文',
        'score': score,
        'user_answer': userAnswer,
        'mode': 1,
        'created_at': at.toIso8601String(),
      });
    }

    test('同一句子的重复记录合并为一条并累计错误次数', () async {
      final base = DateTime(2026, 9, 19, 0, 12);
      // s1：答错 3 次
      await insertLegacy(
        id: '1000',
        sentenceId: 's1',
        english: "That's very thoughtful of you.",
        score: 4,
        userAnswer: 'a',
        at: base,
      );
      await insertLegacy(
        id: '2000',
        sentenceId: 's1',
        english: "That's very thoughtful of you.",
        score: 5,
        userAnswer: 'b',
        at: base.add(const Duration(minutes: 1)),
      );
      await insertLegacy(
        id: '3000',
        sentenceId: 's1',
        english: "That's very thoughtful of you.",
        score: 3,
        userAnswer: 'c',
        at: base.add(const Duration(minutes: 2)),
      );
      // s2：答错 1 次
      await insertLegacy(
        id: '4000',
        sentenceId: 's2',
        english: 'I like apples.',
        score: 6,
        userAnswer: 'd',
        at: base.add(const Duration(minutes: 3)),
      );

      await DatabaseService.migrateWrongSentencesToV10(db);

      final rows = await db.query('wrong_sentences');
      expect(rows, hasLength(2));

      final s1 = rows.firstWhere((r) => r['sentence_id'] == 's1');
      expect(s1['wrong_count'], 3);
      // 保留最近一次（id 最大）的得分与回答
      expect(s1['id'], '3000');
      expect(s1['score'], 3);
      expect(s1['user_answer'], 'c');
      // 首次收录时间为最早，最近答错时间为最晚
      expect(s1['created_at'], base.toIso8601String());
      expect(
        s1['last_wrong_at'],
        base.add(const Duration(minutes: 2)).toIso8601String(),
      );

      final s2 = rows.firstWhere((r) => r['sentence_id'] == 's2');
      expect(s2['wrong_count'], 1);
      expect(
        s2['last_wrong_at'],
        base.add(const Duration(minutes: 3)).toIso8601String(),
      );
    });

    test('无句子 ID 的历史记录按英文原文归一化，不会相互误合并', () async {
      final base = DateTime(2026, 9, 19, 0, 12);
      await insertLegacy(
        id: '1000',
        sentenceId: '',
        english: 'A',
        score: 4,
        userAnswer: 'a',
        at: base,
      );
      await insertLegacy(
        id: '2000',
        sentenceId: '',
        english: 'A',
        score: 2,
        userAnswer: 'b',
        at: base.add(const Duration(minutes: 1)),
      );
      await insertLegacy(
        id: '3000',
        sentenceId: '',
        english: 'B',
        score: 5,
        userAnswer: 'c',
        at: base.add(const Duration(minutes: 2)),
      );

      await DatabaseService.migrateWrongSentencesToV10(db);

      final rows = await db.query('wrong_sentences');
      expect(rows, hasLength(2));
      expect(rows.map((r) => r['sentence_id']).toSet(), {
        'bytext:A',
        'bytext:B',
      });
      expect(
        rows.firstWhere((r) => r['sentence_id'] == 'bytext:A')['wrong_count'],
        2,
      );
      expect(
        rows.firstWhere((r) => r['sentence_id'] == 'bytext:B')['wrong_count'],
        1,
      );
    });

    test('迁移可重复执行且幂等', () async {
      final base = DateTime(2026, 9, 19, 0, 12);
      await insertLegacy(
        id: '1000',
        sentenceId: 's1',
        english: 'A',
        score: 4,
        userAnswer: 'a',
        at: base,
      );
      await insertLegacy(
        id: '2000',
        sentenceId: 's1',
        english: 'A',
        score: 2,
        userAnswer: 'b',
        at: base.add(const Duration(minutes: 1)),
      );

      await DatabaseService.migrateWrongSentencesToV10(db);
      await DatabaseService.migrateWrongSentencesToV10(db);

      final rows = await db.query('wrong_sentences');
      expect(rows, hasLength(1));
      expect(rows.single['wrong_count'], 2);
      expect(rows.single['created_at'], base.toIso8601String());
    });
  });
}
