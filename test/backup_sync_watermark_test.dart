import 'dart:io';

import 'package:aquamarina/models/sync_op.dart';
import 'package:aquamarina/services/backup_service.dart';
import 'package:aquamarina/services/sync_schema.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory dir;
  late String dbPath;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('aquamarina-backup-sync-');
    dbPath = '${dir.path}/aquamarina.db';
  });

  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  test('导出前提取来源水位并保留墓碑与行版本', () async {
    final db = await databaseFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await db.execute('''
      CREATE TABLE sync_meta (
        id INTEGER PRIMARY KEY,
        device_id TEXT,
        head_hlc TEXT,
        head_key TEXT,
        backend_id TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE sync_state (
        device_id TEXT PRIMARY KEY,
        last_hlc TEXT,
        last_chunk_key TEXT
      )
    ''');
    await db.execute(
      'CREATE TABLE sync_tombstones ('
      'entity TEXT NOT NULL, key TEXT NOT NULL, '
      'deleted_hlc TEXT NOT NULL, deleted_at TEXT NOT NULL, '
      'PRIMARY KEY (entity, key))',
    );
    await db.execute(
      'CREATE TABLE sync_row_versions ('
      'entity TEXT NOT NULL, key TEXT NOT NULL, hlc TEXT NOT NULL, '
      'PRIMARY KEY (entity, key))',
    );
    await db.execute('CREATE TABLE oplog_word_notes (seq INTEGER)');
    const ownId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const otherId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    await db.insert('sync_meta', {
      'id': 1,
      'device_id': ownId,
      'head_hlc': SyncHlc(5000, 0).value,
      'head_key': 'p/devices/$ownId/chunks/head.jsonl.gz',
      'backend_id': 'backend-A',
    });
    // 本机状态可能比 head 更新（恢复后重放过自己的 chunk），应取较大值。
    await db.insert('sync_state', {
      'device_id': ownId,
      'last_hlc': SyncHlc(6000, 0).value,
      'last_chunk_key': 'p/devices/$ownId/chunks/own.jsonl.gz',
    });
    await db.insert('sync_state', {
      'device_id': otherId,
      'last_hlc': SyncHlc(3000, 0).value,
      'last_chunk_key': 'p/devices/$otherId/chunks/other.jsonl.gz',
    });
    await db.insert('sync_tombstones', {
      'entity': 'word_notes',
      'key': '{"word":"apple"}',
      'deleted_hlc': SyncHlc(4000, 0).value,
      'deleted_at': '2026-10-01T00:00:00Z',
    });
    await db.insert('sync_row_versions', {
      'entity': 'word_notes',
      'key': '{"word":"apple"}',
      'hlc': SyncHlc(4000, 0).value,
    });
    await db.close();

    final extracted =
        await BackupService.extractAndStripSyncRuntimeTablesForTesting(dbPath);
    final watermarks = extracted.$1;
    expect(extracted.$2, 'backend-A');
    expect(watermarks, hasLength(2));
    final own = watermarks.firstWhere((w) => w.deviceId == ownId);
    final other = watermarks.firstWhere((w) => w.deviceId == otherId);
    expect(own.lastHlc, SyncHlc(6000, 0).value);
    expect(own.lastChunkKey, contains('own.jsonl.gz'));
    expect(other.lastHlc, SyncHlc(3000, 0).value);

    final probe = await databaseFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    final tables = await probe.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    );
    final names = {for (final row in tables) row['name'] as String};
    expect(names, contains('sync_tombstones'));
    expect(names, contains('sync_row_versions'));
    expect(
      names.any(
        (name) =>
            name.startsWith('sync_') &&
            name != 'sync_tombstones' &&
            name != 'sync_row_versions',
      ),
      isFalse,
    );
    expect(names.any((name) => name.startsWith('oplog_')), isFalse);
    final tombstones = await probe.rawQuery(
      'SELECT COUNT(*) AS c FROM sync_tombstones',
    );
    final versions = await probe.rawQuery(
      'SELECT COUNT(*) AS c FROM sync_row_versions',
    );
    expect(tombstones.single['c'], 1);
    expect(versions.single['c'], 1);
    await probe.close();
  });

  test('跨后端恢复丢弃来源水位，但保留当前后端身份以保护 baseline', () {
    const watermark = SyncWatermark(
      deviceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      lastHlc: '00000000000003e8:00000000',
      lastChunkKey: 'p/devices/a/chunks/1.jsonl.gz',
    );

    final mismatch = BackupService.resolveRestoreWatermarks(
      backupWatermarks: const [watermark],
      backupBackendId: 'backend-A',
      localBackendIdentity: 'backend-B',
    );
    expect(mismatch.watermarks, isNull);
    expect(mismatch.backendId, 'backend-B');

    final same = BackupService.resolveRestoreWatermarks(
      backupWatermarks: const [watermark],
      backupBackendId: 'backend-A',
      localBackendIdentity: 'backend-A',
    );
    expect(same.watermarks, isNotNull);
    expect(same.backendId, 'backend-A');
  });
}
