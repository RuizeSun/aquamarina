import 'package:aquamarina/services/cloud/sync_schema.dart';
import 'package:aquamarina/services/cloud/sync_table_spec.dart';
import 'package:aquamarina/services/data/database_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sync_test_support.dart';

/// v22 → v23 迁移：给 `wrong_words` 与 oplog 补 retry_count 列并重建触发器。
///
/// v23 之前 `hard`/`forgot` 会把错词永久排在今天，导致今日待复习无法收敛。
/// 迁移必须同时补齐业务表与 oplog，否则触发器写错词时会引用不存在的列。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('补齐 retry_count 列后，写入错词仍能正常捕获 oplog', () async {
    final db = await openSyncTestDb();
    addTearDown(db.close);

    // 模拟 v22 的 oplog：缺少 retry_count 列
    await db.execute('DROP TABLE oplog_wrong_words');
    final spec = SyncSpecs.byEntity['wrong_words']!;
    final oldColumns = <String>[
      '"seq" INTEGER PRIMARY KEY AUTOINCREMENT',
      '"op" TEXT NOT NULL',
      for (final entry in spec.keyColumns.entries)
        '"${entry.key}" ${entry.value}',
      for (final entry in spec.dataColumns.entries)
        if (entry.key != 'retry_count') '"${entry.key}" ${entry.value}',
      '"hlc_ms" INTEGER',
      '"hlc_counter" INTEGER',
      '"captured_at_ms" INTEGER',
    ];
    await db.execute(
      'CREATE TABLE oplog_wrong_words (${oldColumns.join(', ')})',
    );

    await DatabaseService.migrateToV23(db);

    Future<Set<String>> columnsOf(String table) async {
      final rows = await db.rawQuery('PRAGMA table_info($table)');
      return rows.map((row) => row['name'].toString()).toSet();
    }

    expect(await columnsOf('wrong_words'), contains('retry_count'));
    expect(
      await columnsOf('oplog_wrong_words'),
      contains('retry_count'),
      reason: 'oplog 缺少 retry_count 列，触发器会写入失败',
    );

    await SyncSchema.setCaptureEnabled(db, true);
    await db.insert('wrong_words', {
      'word': 'ephemeral',
      'scheduled_date': '2026-11-21',
      'retry_count': 2,
      'created_at': DateTime.now().toIso8601String(),
    });

    final rows = await db.query(
      SyncSpecs.byEntity['wrong_words']!.oplogTable,
      where: "op = 'upsert'",
    );
    expect(rows, isNotEmpty);
    expect(rows.last['retry_count'], 2);
  });
}
