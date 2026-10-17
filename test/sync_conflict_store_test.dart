import 'package:aquamarina/services/sync_conflict_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'sync_test_support.dart';

void main() {
  late Database db;

  setUp(() async {
    db = await openSyncTestDb();
    await db.insert('word_notes', {
      'word': 'apple',
      'note': 'local',
      'is_favorited': 1,
      'updated_at': '2026-10-02T00:00:00Z',
    });
  });

  tearDown(() async {
    await db.close();
  });

  test('冲突保存、采用远端并标记已解决', () async {
    await SyncConflictStore.save(db, [
      const SyncConflict(
        entity: 'word_notes',
        key: {'word': 'apple'},
        localData: {
          'note': 'local',
          'is_favorited': 1,
          'updated_at': '2026-10-02T00:00:00Z',
        },
        remoteData: {
          'note': 'remote',
          'is_favorited': 0,
          'updated_at': '2026-10-01T00:00:00Z',
        },
        localTimestamp: '2026-10-02T00:00:00Z',
        remoteTimestamp: '2026-10-01T00:00:00Z',
      ),
    ]);

    final pending = await SyncConflictStore.listUnresolved(db: db);
    expect(pending, hasLength(1));
    expect(await SyncConflictStore.unresolvedCount(db: db), 1);

    expect(await SyncConflictStore.applyRemote(pending.single, db: db), isTrue);
    final row = (await db.query('word_notes')).single;
    expect(row['note'], 'remote');
    expect(row['is_favorited'], 0);
    expect(await db.query('sync_row_versions'), isNotEmpty);

    await SyncConflictStore.markResolved(pending.single.id, 'remote', db: db);
    expect(await SyncConflictStore.unresolvedCount(db: db), 0);
  });

  test('过期冲突按保留期清理', () async {
    await SyncConflictStore.save(db, [
      const SyncConflict(
        entity: 'word_notes',
        key: {'word': 'apple'},
        localData: {'note': 'local'},
        remoteData: {'note': 'remote'},
      ),
    ]);
    final old = DateTime.now()
        .toUtc()
        .subtract(const Duration(days: 400))
        .toIso8601String();
    await db.update('sync_conflicts', {'created_at': old, 'resolved': 1});
    expect(await SyncConflictStore.prune(db: db), 1);
    expect(await db.query('sync_conflicts'), isEmpty);
  });

  test('保留双方把远端笔记追加到本地', () async {
    await SyncConflictStore.save(db, [
      const SyncConflict(
        entity: 'word_notes',
        key: {'word': 'apple'},
        localData: {
          'note': 'local',
          'is_favorited': 1,
          'updated_at': '2026-10-02T00:00:00Z',
        },
        remoteData: {
          'note': 'remote',
          'is_favorited': 0,
          'updated_at': '2026-10-01T00:00:00Z',
        },
      ),
    ]);
    final pending = await SyncConflictStore.listUnresolved(db: db);
    expect(await SyncConflictStore.keepBoth(pending.single, db: db), isTrue);
    final note = (await db.query('word_notes')).single['note'] as String;
    expect(note, contains('local'));
    expect(note, contains('远端版本'));
    expect(note, contains('remote'));
  });
}
