import 'package:aquamarina/models/ai_sentence.dart';
import 'package:aquamarina/pages/settings/sections/sentence_cache_section.dart';
import 'package:aquamarina/services/database_service.dart';
import 'package:aquamarina/services/sentence_eval_cache_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ===== 纯逻辑：缓存键归一化与工具方法 =====
  group('缓存键归一化', () {
    test('去除首尾空白并折叠连续空白', () {
      expect(
        SentenceEvalCacheService.normalize('  Hello   world \n'),
        'Hello world',
      );
    });

    test('保留大小写：大小写计入评分，不应合并为同一条缓存', () {
      expect(SentenceEvalCacheService.normalize('Hello.'), 'Hello.');
      expect(
        SentenceEvalCacheService.normalize('hello.'),
        isNot(SentenceEvalCacheService.normalize('Hello.')),
      );
    });

    test('练习模式与数据库存储值互转', () {
      expect(SentenceEvalCacheService.modeValue(PracticeMode.beginner), 0);
      expect(SentenceEvalCacheService.modeValue(PracticeMode.advanced), 1);
      expect(SentenceEvalCacheService.modeFromValue(0), PracticeMode.beginner);
      expect(SentenceEvalCacheService.modeFromValue(1), PracticeMode.advanced);
    });

    test('格式化占用空间', () {
      expect(SentenceEvalCacheService.formatSize(0), '0 B');
      expect(SentenceEvalCacheService.formatSize(1023), '1023 B');
      expect(SentenceEvalCacheService.formatSize(2048), '2.0 KB');
      expect(SentenceEvalCacheService.formatSize(3 * 1024 * 1024), '3.00 MB');
    });
  });

  // ===== 真实 SQLite（ffi 内存库）：读写与管理 =====
  group('缓存读写与管理', () {
    final sentence = Sentence(
      id: 's1',
      setId: 'set1',
      english: 'I like apples.',
      chinese: '我喜欢苹果。',
    );

    late Database db;
    late SentenceEvalCacheService service;

    setUp(() async {
      // 缓存开关走 SharedPreferences
      SharedPreferences.setMockInitialValues(<String, Object>{});

      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      // 使用与生产环境完全相同的建表 DDL（DatabaseService 中的常量）
      db = await databaseFactory.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, version) async {
            await db.execute(DatabaseService.sentenceEvalCacheTableSql);
            await db.execute(DatabaseService.sentenceEvalCacheIndexSql);
          },
        ),
      );
      service = SentenceEvalCacheService.withDatabase(() async => db);
    });

    tearDown(() async {
      await db.close();
    });

    Future<void> store(
      String answer, {
      PracticeMode mode = PracticeMode.beginner,
      int score = 9,
      String comment = '很好',
    }) {
      return service.store(
        sentence: sentence,
        userAnswer: answer,
        mode: mode,
        result: AiSentenceResult(
          score: score,
          markup: '<yellow>x</yellow>',
          comment: comment,
        ),
      );
    }

    test('相同句子 + 相同回答命中缓存', () async {
      await store('I like apples.');

      final hit = await service.lookup(
        sentence: sentence,
        userAnswer: 'I like apples.',
        mode: PracticeMode.beginner,
      );

      expect(hit, isNotNull);
      expect(hit!.score, 9);
      expect(hit.comment, '很好');
    });

    test('空白差异（首尾 / 连续空格）不影响命中', () async {
      await store('  I   like apples. ');

      final hit = await service.lookup(
        sentence: sentence,
        userAnswer: 'I like apples.',
        mode: PracticeMode.beginner,
      );

      expect(hit, isNotNull);
    });

    test('回答不同则不命中', () async {
      await store('I like apples.');

      final miss = await service.lookup(
        sentence: sentence,
        userAnswer: 'I like apple.',
        mode: PracticeMode.beginner,
      );

      expect(miss, isNull);
    });

    test('练习模式不同则不命中', () async {
      await store('I like apples.');

      final miss = await service.lookup(
        sentence: sentence,
        userAnswer: 'I like apples.',
        mode: PracticeMode.advanced,
      );

      expect(miss, isNull);
    });

    test('句子不同则不命中', () async {
      await store('I like apples.');

      final miss = await service.lookup(
        sentence: Sentence(
          id: 's2',
          setId: 'set1',
          english: 'I like bananas.',
          chinese: '我喜欢香蕉。',
        ),
        userAnswer: 'I like apples.',
        mode: PracticeMode.beginner,
      );

      expect(miss, isNull);
    });

    test('重复写入同一键只保留首次结果', () async {
      await store('I like apples.', score: 9);
      await store('I like apples.', score: 3, comment: '重写');

      final stats = await service.fetchStats();
      expect(stats.count, 1);

      final hit = await service.lookup(
        sentence: sentence,
        userAnswer: 'I like apples.',
        mode: PracticeMode.beginner,
      );
      expect(hit!.score, 9);
      expect(hit.comment, '很好');
    });

    test('命中时累计命中次数并记录最近命中时间', () async {
      await store('I like apples.');

      for (var i = 0; i < 3; i++) {
        await service.lookup(
          sentence: sentence,
          userAnswer: 'I like apples.',
          mode: PracticeMode.beginner,
        );
      }

      final stats = await service.fetchStats();
      expect(stats.count, 1);
      expect(stats.hits, 3);

      final row = (await db.query(SentenceEvalCacheService.table)).first;
      expect(row['last_hit_at'], isNotNull);
    });

    test('关闭缓存后既不读取也不写入', () async {
      await service.setEnabled(false);
      await store('I like apples.');
      expect((await service.fetchStats()).count, 0);

      await service.setEnabled(true);
      await store('I like apples.');
      await service.setEnabled(false);

      final hit = await service.lookup(
        sentence: sentence,
        userAnswer: 'I like apples.',
        mode: PracticeMode.beginner,
      );
      expect(hit, isNull);
    });

    test('fetchStats 汇总条数、占用与时间跨度', () async {
      await store('I like apples.');
      await store('I like apples too.', score: 7);

      final stats = await service.fetchStats();
      expect(stats.count, 2);
      expect(stats.hits, 0);
      // 占用为估算值：至少包含每条记录的固定开销与文本字节
      expect(stats.bytes, greaterThan(2 * 96));
      expect(stats.oldest, isNotNull);
      expect(stats.newest, isNotNull);
      expect(stats.oldest!.isAfter(stats.newest!), isFalse);
    });

    test('按天数清理：只删除早于指定天数的缓存', () async {
      await store('I like apples.');
      await store('I like apples too.');
      await store('Fresh answer.');

      // 把前两条回退到 30 天前
      final oldTime = DateTime.now()
          .subtract(const Duration(days: 30))
          .toIso8601String();
      await db.update(
        SentenceEvalCacheService.table,
        {'created_at': oldTime},
        where: 'user_answer != ?',
        whereArgs: ['Fresh answer.'],
      );

      expect(await service.countOlderThanDays(7), 2);
      expect(await service.deleteOlderThanDays(7), 2);
      expect((await service.fetchStats()).count, 1);
    });

    test('没有更早的缓存时按天数清理不产生副作用', () async {
      await store('Newest answer.');

      expect(await service.countOlderThanDays(1), 0);
      expect(await service.deleteOlderThanDays(1), 0);
      expect((await service.fetchStats()).count, 1);
    });

    test('清空全部缓存返回删除条数', () async {
      await store('I like apples.');
      await store('I like apples too.');

      expect(await service.deleteAll(), 2);

      final stats = await service.fetchStats();
      expect(stats.isEmpty, isTrue);
      expect(stats.bytes, 0);
    });

    // 设置分区会展示缓存条数与占用，此处用注入的内存库服务渲染真实数据
    testWidgets('设置分区展示缓存开关与条数概览', (tester) async {
      // 真实异步 I/O（sqflite ffi / SharedPreferences）需在 runAsync 中执行
      await tester.runAsync(() async {
        await store('I like apples.');
        await store('I like apples too.');

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: SentenceCacheSection(cacheService: service)),
          ),
        );
        // 等待 SharedPreferences 与数据库查询完成
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();

      expect(find.text('启用练习缓存'), findsOneWidget);
      expect(find.byType(SwitchListTile), findsOneWidget);
      expect(find.text('缓存管理'), findsOneWidget);
      expect(find.textContaining('共 2 条'), findsOneWidget);
    });
  });
}
