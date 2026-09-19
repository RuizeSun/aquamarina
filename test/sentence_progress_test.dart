import 'package:aquamarina/services/ai_sentence_service.dart';
import 'package:aquamarina/services/database_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 「练习进度（练过即计入）」与「不重复练习（只跳过答对的句子）」的口径分离。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;
  late AiSentenceService service;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS practiced_sentence_ids (
              set_id TEXT NOT NULL,
              sentence_id TEXT NOT NULL,
              PRIMARY KEY (set_id, sentence_id)
            )
          ''');
          await db.execute(DatabaseService.attemptedSentenceIdsTableSql);
        },
      ),
    );
    service = AiSentenceService(openDatabase: () async => db);
  });

  tearDown(() async => db.close());

  test('练过的句子计入练习进度，答错的不会被算作已答对', () async {
    await service.markSentenceAttempted('set1', 's1');
    await service.markSentenceAttempted('set1', 's2');

    expect(await service.getAttemptedSentenceIds('set1'), {'s1', 's2'});
    // 两句都答错（未调用 markSentencePracticed）→ 已答对为空
    expect(await service.getPracticedSentenceIds('set1'), isEmpty);
  });

  test('答对的句子同时计入已练习与已答对', () async {
    await service.markSentenceAttempted('set1', 's1');
    await service.markSentencePracticed('set1', 's1');

    expect(await service.getAttemptedSentenceIds('set1'), {'s1'});
    expect(await service.getPracticedSentenceIds('set1'), {'s1'});
  });

  test('重复练习同一句不会重复计数', () async {
    await service.markSentenceAttempted('set1', 's1');
    await service.markSentenceAttempted('set1', 's1');
    await service.markSentenceAttempted('set1', 's1');

    expect((await service.getAttemptedSentenceIds('set1')).length, 1);
  });

  test('不同句式集之间互不串数据', () async {
    await service.markSentenceAttempted('set1', 's1');
    await service.markSentenceAttempted('set2', 's9');

    expect(await service.getAttemptedSentenceIds('set1'), {'s1'});
    expect(await service.getAttemptedSentenceIds('set2'), {'s9'});
  });

  test('v11 → v12 回填：历史的已答对句子会补进已练习表，且可重复执行', () async {
    await service.markSentencePracticed('set1', 's1');
    await service.markSentencePracticed('set1', 's2');
    expect(await service.getAttemptedSentenceIds('set1'), isEmpty);

    await db.execute(DatabaseService.attemptedSentenceIdsBackfillSql);
    expect(await service.getAttemptedSentenceIds('set1'), {'s1', 's2'});

    // 幂等：再次执行不会报错也不会产生重复
    await db.execute(DatabaseService.attemptedSentenceIdsBackfillSql);
    expect((await service.getAttemptedSentenceIds('set1')).length, 2);
  });
}
