import 'package:aquamarina/models/sync_op.dart';
import 'package:aquamarina/services/database_service.dart';
import 'package:aquamarina/services/sync_schema.dart';
import 'package:aquamarina/services/sync_table_spec.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 测试用：按同步规格创建最小业务表（含本地自增 id 与关联列）。
Future<void> createSyncTestTables(Database db) async {
  for (final spec in SyncSpecs.all) {
    final columns = <String>[];
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

/// 测试用：建表并安装 v13 同步 schema。
Future<Database> openSyncTestDb() async {
  sqfliteFfiInit();
  final db = await databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await createSyncTestTables(db);
  await DatabaseService.migrateToV13(db);
  await DatabaseService.migrateToV15(db);
  await DatabaseService.migrateToV16(db);
  await DatabaseService.migrateToV17(db);
  await DatabaseService.migrateToV18(db);
  await DatabaseService.migrateToV19(db);
  await SyncSchema.setCaptureEnabled(db, true);
  return db;
}

/// 测试用：构造一条同步操作。
SyncOp makeOp({
  required String entity,
  required int seq,
  required int hlcMs,
  required Map<String, dynamic> key,
  String op = 'upsert',
  Map<String, dynamic> data = const {},
  Map<String, int> delta = const {},
  String deviceId = 'device-b',
  int hlcCounter = 0,
  String? deletedAt,
}) {
  return SyncOp(
    deviceId: deviceId,
    seq: seq,
    hlc: SyncHlc(hlcMs, hlcCounter),
    entity: entity,
    key: key,
    op: op,
    data: data,
    delta: delta,
    deletedAt: deletedAt,
  );
}
