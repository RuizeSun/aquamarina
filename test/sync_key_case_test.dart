import 'package:aquamarina/models/sync_op.dart';
import 'package:aquamarina/services/cloud/sync_apply_service.dart';
import 'package:aquamarina/services/cloud/sync_schema.dart';
import 'package:aquamarina/services/cloud/sync_table_spec.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 业务表用 `COLLATE NOCASE` 定义，`Apple` 与 `apple` 本就是同一行。
/// 若同步键保留原始大小写，远端 op 会被判定为新行 → 插入被 UNIQUE
/// 约束静默忽略（ConflictAlgorithm.ignore），数据永久丢失且无报错。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  /// 按 spec 建表；大小写不敏感的键列使用 COLLATE NOCASE（与生产一致）。
  Future<void> createTables() async {
    for (final spec in SyncSpecs.all) {
      final columns = <String>[];
      if (spec.table == 'word_books' ||
          spec.table == 'word_book_entries' ||
          spec.table == 'learning_sessions' ||
          spec.table == 'vocab_test_history') {
        columns.add('"id" INTEGER PRIMARY KEY AUTOINCREMENT');
      }
      if (spec.table == 'word_book_entries') {
        columns.add('"book_id" INTEGER');
      }
      for (final entry in spec.keyColumns.entries) {
        final nocase = spec.caseInsensitiveKeyColumns.contains(entry.key)
            ? ' COLLATE NOCASE'
            : '';
        final suffix =
            entry.key == 'word' && spec.keyColumns.length == 1 ? ' UNIQUE' : '';
        columns.add('"${entry.key}" ${entry.value}$nocase$suffix');
      }
      for (final entry in spec.dataColumns.entries) {
        columns.add('"${entry.key}" ${entry.value}');
      }
      for (final counter in spec.counters) {
        columns.add('"$counter" INTEGER DEFAULT 0');
      }
      await db.execute(
        'CREATE TABLE "${spec.table}" (${columns.join(', ')})',
      );
    }
  }

  setUp(() async {
    db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await createTables();
    await SyncSchema.ensure(db);
    await SyncSchema.setCaptureEnabled(db, true);
  });

  tearDown(() async {
    await db.close();
  });

  SyncOp op({
    required String word,
    required int seq,
    required int hlcMs,
    String entity = 'user_word_records',
  }) {
    return SyncOp(
      deviceId: 'device-b',
      seq: seq,
      hlc: SyncHlc(hlcMs, 0),
      entity: entity,
      key: {'word': word},
      op: 'upsert',
      data: {
        'stage': 1,
        'last_reviewed_at': '2026-10-01T00:00:00Z',
        'created_at': '2026-10-01T00:00:00Z',
      },
    );
  }

  test('本机小写记录不会被远端大写 op 静默丢弃', () async {
    await db.insert('user_word_records', {
      'word': 'apple',
      'stage': 0,
      'last_reviewed_at': '2026-09-01T00:00:00Z',
      'created_at': '2026-09-01T00:00:00Z',
    });

    // 远端写入 "Apple"（不同大小写，同一实体）
    final result = await SyncApplyService.applyOps(
      [op(word: 'Apple', seq: 1, hlcMs: 5000)],
      db: db,
    );

    expect(result.applied, 1);
    final rows = await db.query('user_word_records');
    expect(rows, hasLength(1), reason: '大小写不同不应产生第二行');
    // 远端较新 → 本地字段应被更新
    expect(rows.single['stage'], 1);
  });

  test('没有本地记录时远端大写 op 能正常插入', () async {
    final result = await SyncApplyService.applyOps(
      [op(word: 'Banana', seq: 2, hlcMs: 1000)],
      db: db,
    );
    expect(result.applied, 1);
    final rows = await db.query('user_word_records');
    expect(rows, hasLength(1));
    expect(rows.single['stage'], 1);
  });

  test('word_notes 同样按大小写归一化去重', () async {
    final result = await SyncApplyService.applyOps([
      SyncOp(
        deviceId: 'device-b',
        seq: 3,
        hlc: const SyncHlc(2000, 0),
        entity: 'word_notes',
        key: const {'word': 'Focus'},
        op: 'upsert',
        data: const {
          'note': '专注',
          'is_favorited': 1,
          'updated_at': '2026-10-01T00:00:00Z',
        },
      ),
    ], db: db);

    expect(result.applied, 1);
    final rows = await db.query('word_notes');
    expect(rows, hasLength(1));
    expect(rows.single['note'], '专注');
  });

  test('normalizeKey 无变化时返回同一实例', () {
    final spec = SyncSpecs.byEntity['user_word_records']!;
    final key = <String, dynamic>{'word': 'apple'};
    expect(identical(spec.normalizeKey(key), key), isTrue);

    final upper = <String, dynamic>{'word': 'Apple'};
    expect(identical(spec.normalizeKey(upper), upper), isFalse);
    expect(spec.normalizeKey(upper)['word'], 'apple');
  });
}
