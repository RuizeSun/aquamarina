import 'package:aquamarina/models/sync_op.dart';
import 'package:aquamarina/services/database_service.dart';
import 'package:aquamarina/services/sync_capture_service.dart';
import 'package:aquamarina/services/sync_schema.dart';
import 'package:aquamarina/services/sync_table_spec.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 构造 v12 形态的最小业务表（含同步规格涉及的列）。
Future<void> _createLegacyTables(Database db) async {
  for (final spec in SyncSpecs.all) {
    final columns = <String>[];
    // 三张自增主键表需要保留本地 id（服务/回填逻辑使用）
    if (spec.table == 'word_books') {
      columns.add('"id" INTEGER PRIMARY KEY AUTOINCREMENT');
    } else if (spec.table == 'word_book_entries') {
      columns.add('"id" INTEGER PRIMARY KEY AUTOINCREMENT');
      columns.add('"book_id" INTEGER');
    } else if (spec.table == 'learning_sessions' ||
        spec.table == 'vocab_test_history') {
      columns.add('"id" INTEGER PRIMARY KEY AUTOINCREMENT');
    }

    for (final entry in spec.keyColumns.entries) {
      columns.add('"${entry.key}" ${entry.value}');
    }
    for (final entry in spec.dataColumns.entries) {
      columns.add('"${entry.key}" ${entry.value}');
    }
    for (final counter in spec.counters) {
      columns.add('"$counter" INTEGER DEFAULT 0');
    }
    await db.execute('CREATE TABLE "${spec.table}" (${columns.join(', ')})');
  }
}

Future<int> _oplogCount(Database db, String entity) async {
  final result = await db.rawQuery('SELECT COUNT(*) AS c FROM "oplog_$entity"');
  return (result.first['c'] as int?) ?? 0;
}

Future<Set<String>> _columnsOf(Database db, String table) async {
  final rows = await db.rawQuery('PRAGMA table_info("$table")');
  return {for (final row in rows) row['name'] as String};
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Database db;

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await _createLegacyTables(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('v13 迁移：补列、回填稳定 ID、句子顺序与幂等', () async {
    final bookId = await db.insert('word_books', {
      'title': '旧词书',
      'word_count': 2,
      'created_at': '2026-10-01T00:00:00Z',
      'updated_at': '2026-10-01T00:00:00Z',
    });
    await db.insert('word_book_entries', {
      'book_id': bookId,
      'word': 'apple',
      'added_at': '2026-10-01T00:00:00Z',
    });
    await db.insert('word_book_entries', {
      'book_id': bookId,
      'word': 'banana',
      'added_at': '2026-10-01T00:00:00Z',
    });
    await db.insert('learning_sessions', {
      'session_type': 'learn',
      'started_at': '2026-10-01T00:00:00Z',
      'duration_seconds': 60,
      'date': '2026-10-01',
    });
    await db.insert('vocab_test_history', {
      'date': '2026-10-01T00:00:00Z',
      'total_count': 10,
      'correct_count': 8,
      'accuracy': 0.8,
    });
    await db.insert('sentences', {
      'id': 'sentence-1',
      'set_id': 'set-1',
      'english': 'Hello.',
      'chinese': '你好。',
    });
    await db.insert('sentences', {
      'id': 'sentence-2',
      'set_id': 'set-1',
      'english': 'World.',
      'chinese': '世界。',
    });

    await DatabaseService.migrateToV13(db);
    await db.update('sync_meta', {'capture_enabled': 1}, where: 'id = 1');

    final books = await db.query('word_books');
    expect(books.first['uuid'], isNotEmpty);
    final bookUuid = books.first['uuid'] as String;

    final entries = await db.query('word_book_entries', orderBy: 'id ASC');
    expect(entries.map((e) => e['book_uuid']), everyElement(bookUuid));

    final sessions = await db.query('learning_sessions');
    expect(sessions.first['uuid'], isNotEmpty);
    final tests = await db.query('vocab_test_history');
    expect(tests.first['uuid'], isNotEmpty);

    final sentences = await db.query('sentences', orderBy: 'sort_index ASC');
    expect(sentences.map((s) => s['sort_index']), [1.0, 2.0]);

    final triggers = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'trigger'",
    );
    expect(triggers.length, SyncSpecs.all.length * 3);

    // 幂等：再次迁移不应改变稳定 ID / 顺序
    await DatabaseService.migrateToV13(db);
    final booksAgain = await db.query('word_books');
    expect(booksAgain.first['uuid'], bookUuid);
    final sentencesAgain = await db.query(
      'sentences',
      orderBy: 'sort_index ASC',
    );
    expect(sentencesAgain.map((s) => s['sort_index']), [1.0, 2.0]);
  });

  test('触发器捕获 INSERT / UPDATE 增量 / DELETE 与抑制标记', () async {
    await DatabaseService.migrateToV13(db);
    await db.update('sync_meta', {'capture_enabled': 1}, where: 'id = 1');

    await db.insert('user_word_records', {
      'word': 'apple',
      'stage': 0,
      'is_weak': 0,
      'is_mastered': 0,
      'review_count': 0,
      'created_at': '2026-10-01T00:00:00Z',
    });
    var ops = await db.query('oplog_user_word_records', orderBy: 'seq ASC');
    expect(ops.length, 1);
    expect(ops.first['op'], 'upsert');
    expect(ops.first['word'], 'apple');
    expect(ops.first['delta_review_count'], 0);

    await db.update(
      'user_word_records',
      {'review_count': 3},
      where: 'word = ?',
      whereArgs: ['apple'],
    );
    ops = await db.query('oplog_user_word_records', orderBy: 'seq ASC');
    expect(ops.length, 2);
    expect(ops.last['delta_review_count'], 3);

    await db.insert('daily_activity', {
      'date': '2026-10-01',
      'words_learned': 5,
      'words_reviewed': 2,
      'correct_count': 4,
      'wrong_count': 1,
    });
    await db.update(
      'daily_activity',
      {'words_learned': 8},
      where: 'date = ?',
      whereArgs: ['2026-10-01'],
    );
    final daily = await db.query('oplog_daily_activity', orderBy: 'seq ASC');
    expect(daily.length, 2);
    expect(daily.first['delta_words_learned'], 5);
    expect(daily.last['delta_words_learned'], 3);

    await db.insert('word_notes', {
      'word': 'apple',
      'note': 'a note',
      'is_favorited': 1,
    });
    await db.delete('word_notes', where: 'word = ?', whereArgs: ['apple']);
    final notes = await db.query('oplog_word_notes', orderBy: 'seq ASC');
    expect(notes.length, 2);
    expect(notes.last['op'], 'delete');
    expect(notes.last['word'], 'apple');

    // 应用远端操作时（applying = 1）不得回环记录
    await db.update('sync_meta', {'applying': 1}, where: 'id = 1');
    final before = await _oplogCount(db, 'user_word_records');
    await db.insert('user_word_records', {
      'word': 'banana',
      'stage': 1,
      'review_count': 0,
    });
    expect(await _oplogCount(db, 'user_word_records'), before);

    await db.update('sync_meta', {'applying': 0}, where: 'id = 1');
    await db.insert('user_word_records', {
      'word': 'cherry',
      'stage': 1,
      'review_count': 0,
    });
    expect(await _oplogCount(db, 'user_word_records'), before + 1);
  });

  test('未启用捕获时不写 oplog（避免未配置云同步时无限增长）', () async {
    await DatabaseService.migrateToV13(db);
    await db.insert('word_notes', {
      'word': 'apple',
      'note': 'not captured',
      'is_favorited': 0,
    });
    expect(await _oplogCount(db, 'word_notes'), 0);

    await db.update('sync_meta', {'capture_enabled': 1}, where: 'id = 1');
    await db.insert('word_notes', {
      'word': 'banana',
      'note': 'captured',
      'is_favorited': 0,
    });
    expect(await _oplogCount(db, 'word_notes'), 1);
  });

  test('恢复重置后重新开启捕获，可继续记录新写入', () async {
    await DatabaseService.migrateToV13(db);
    await SyncSchema.setCaptureEnabled(db, true);
    await db.insert('word_notes', {
      'word': 'apple',
      'note': 'before restore',
      'is_favorited': 0,
    });
    expect(await _oplogCount(db, 'word_notes'), 1);

    await SyncSchema.resetRuntimeState(
      db,
      baseline: DateTime.utc(2026, 10, 18),
    );
    expect(await _oplogCount(db, 'word_notes'), 0);

    // 快照恢复后 sync_meta 可能按默认值重建为 0；模拟这一状态。
    await SyncSchema.setCaptureEnabled(db, false);
    await db.insert('word_notes', {
      'word': 'banana',
      'note': 'not captured',
      'is_favorited': 0,
    });
    expect(await _oplogCount(db, 'word_notes'), 0);

    // BackupService 恢复完成后会执行这一步；之后的学习必须能再次进入 oplog。
    await SyncSchema.setCaptureEnabled(db, true);
    await db.insert('word_notes', {
      'word': 'cherry',
      'note': 'after restore',
      'is_favorited': 0,
    });
    expect(await SyncCaptureService.isCaptureEnabled(db: db), isTrue);
    expect(await _oplogCount(db, 'word_notes'), 1);
  });

  test('v15 迁移：补齐水位列并回填 chunk 起始 HLC', () async {
    await DatabaseService.migrateToV13(db);
    await DatabaseService.migrateToV15(db);

    expect(
      await _columnsOf(db, 'sync_meta'),
      containsAll(['head_hlc', 'head_key', 'head_chunk_count', 'head_dirty']),
    );
    expect(await _columnsOf(db, 'sync_applied'), contains('hlc'));
    expect(await _columnsOf(db, 'sync_state'), contains('last_chunk_key'));
    expect(
      await _columnsOf(db, 'sync_chunks'),
      containsAll(['min_hlc', 'max_hlc']),
    );

    final hlc = SyncHlc(1000, 0).value;
    await db.insert('sync_chunks', {
      'device_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      'chunk_key':
          'aquamarina/devices/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/chunks/'
          '${hlc.replaceAll(':', '-')}-aaaaaaaaaaaaaaaa.jsonl',
      'sha256':
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      'applied_at': DateTime.now().toUtc().toIso8601String(),
    });

    // 幂等：再次迁移不应重复添加列或失败，并回填旧行的起始 HLC。
    await DatabaseService.migrateToV15(db);
    final rows = await db.query('sync_chunks');
    expect(rows.single['min_hlc'], hlc);
    expect(rows.single['max_hlc'], hlc);
  });
}
