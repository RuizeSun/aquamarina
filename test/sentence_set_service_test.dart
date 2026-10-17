import 'dart:convert';

import 'package:aquamarina/models/ai_sentence.dart';
import 'package:aquamarina/models/ai_sentence_set.dart';
import 'package:aquamarina/services/ai_sentence_set_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'sync_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;
  late SentenceSetService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = await openSyncTestDb();
    service = SentenceSetService.forTesting(() async => db);
  });

  tearDown(() async {
    await db.close();
  });

  test('旧 SharedPreferences 数据迁移到 SQLite 且只迁移一次', () async {
    SharedPreferences.setMockInitialValues({
      'sentence_sets_v1': jsonEncode([
        {
          'id': 'legacy-set-1',
          'name': '旧句式集',
          'description': '迁移测试',
          'sentence_count': 0,
          'created_at': '2026-10-01T00:00:00Z',
        },
      ]),
    });
    service = SentenceSetService.forTesting(() async => db);

    await service.load();
    expect(service.sets.length, 1);
    expect(service.sets.single.id, 'legacy-set-1');
    expect(service.sets.single.name, '旧句式集');

    final rows = await db.query('sentence_sets');
    expect(rows.length, 1);
    expect(rows.single['name'], '旧句式集');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('sentence_sets_db_migrated_v1'), isTrue);

    // 再次加载不会重复插入
    await service.load();
    expect((await db.query('sentence_sets')).length, 1);
  });

  test('句式集 CRUD 与句子计数落库', () async {
    await service.load();

    final created = await service.addSet(
      SentenceSet(name: '新句式集', description: '描述'),
    );
    expect(created.id, isNotEmpty);
    var rows = await db.query('sentence_sets');
    expect(rows.single['name'], '新句式集');
    expect(rows.single['updated_at'], isNotEmpty);

    await service.updateSet(created.copyWith(name: '改名后'));
    rows = await db.query('sentence_sets');
    expect(rows.single['name'], '改名后');
    expect(
      (await db.query('oplog_sentence_sets')).length,
      greaterThanOrEqualTo(2),
    );

    await service.addSentence(
      Sentence(setId: created.id!, english: 'Hello.', chinese: '你好。'),
    );
    rows = await db.query('sentence_sets');
    expect(rows.single['sentence_count'], 1);
    expect((await db.query('sentences')).single['sort_index'], 1.0);

    await service.deleteSet(created.id!);
    expect(await db.query('sentence_sets'), isEmpty);
    expect(await db.query('sentences'), isEmpty);
  });
}
