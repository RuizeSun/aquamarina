import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../models/sync_op.dart';
import '../data/database_service.dart';
import 'sync_table_spec.dart';

/// 一条可持久化、可在 UI 中逐条处理的冲突（P2-6）。
class SyncConflict {
  final String entity;
  final Map<String, dynamic> key;
  final Map<String, dynamic> localData;
  final Map<String, dynamic> remoteData;
  final String? localTimestamp;
  final String? remoteTimestamp;

  const SyncConflict({
    required this.entity,
    required this.key,
    required this.localData,
    required this.remoteData,
    this.localTimestamp,
    this.remoteTimestamp,
  });

  String get keyFingerprint => SyncOp(
    deviceId: 'local',
    seq: 1,
    hlc: const SyncHlc(0, 0),
    entity: entity,
    key: key,
    op: 'upsert',
  ).keyFingerprint;
}

/// 持久化的冲突记录（本机表，不参与同步）。
class PendingSyncConflict {
  final int id;
  final String entity;
  final Map<String, dynamic> key;
  final Map<String, dynamic> localData;
  final Map<String, dynamic> remoteData;
  final String? localTime;
  final String? remoteTime;
  final DateTime createdAt;

  const PendingSyncConflict({
    required this.id,
    required this.entity,
    required this.key,
    required this.localData,
    required this.remoteData,
    required this.localTime,
    required this.remoteTime,
    required this.createdAt,
  });

  String get keyLabel =>
      key.entries.map((e) => '${e.key}=${e.value}').join(', ');

  String get title => '$entity · $keyLabel';
}

/// 冲突记录的存取与解决（P2-6）。
class SyncConflictStore {
  SyncConflictStore._();

  static Future<Database> _db(Database? db) async =>
      db ?? await DatabaseService.database;

  static Future<void> save(Database db, List<SyncConflict> conflicts) async {
    if (conflicts.isEmpty) return;
    final now = DateTime.now().toUtc().toIso8601String();
    await db.transaction((txn) async {
      for (final conflict in conflicts) {
        await txn.insert('sync_conflicts', {
          'entity': conflict.entity,
          'key': jsonEncode(conflict.key),
          'local_json': jsonEncode(conflict.localData),
          'remote_json': jsonEncode(conflict.remoteData),
          'local_time': conflict.localTimestamp,
          'remote_time': conflict.remoteTimestamp,
          'created_at': now,
        });
      }
    });
  }

  static Future<List<PendingSyncConflict>> listUnresolved({
    Database? db,
    int limit = 100,
  }) async {
    final database = await _db(db);
    final rows = await database.query(
      'sync_conflicts',
      where: 'resolved = 0',
      orderBy: 'id DESC',
      limit: limit,
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  /// 清理过期冲突：已解决保留 30 天，未解决保留 180 天。
  static Future<int> prune({
    Database? db,
    Duration resolvedRetention = const Duration(days: 30),
    Duration unresolvedRetention = const Duration(days: 180),
    DateTime? now,
  }) async {
    final database = await _db(db);
    final current = (now ?? DateTime.now()).toUtc();
    final resolvedCutoff = current
        .subtract(resolvedRetention)
        .toIso8601String();
    final unresolvedCutoff = current
        .subtract(unresolvedRetention)
        .toIso8601String();
    var deleted = await database.delete(
      'sync_conflicts',
      where: 'resolved = 1 AND created_at < ?',
      whereArgs: [resolvedCutoff],
    );
    deleted += await database.delete(
      'sync_conflicts',
      where: 'resolved = 0 AND created_at < ?',
      whereArgs: [unresolvedCutoff],
    );
    return deleted;
  }

  static Future<int> unresolvedCount({Database? db}) async {
    final database = await _db(db);
    final rows = await database.rawQuery(
      'SELECT COUNT(*) AS c FROM sync_conflicts WHERE resolved = 0',
    );
    return (rows.first['c'] as int?) ?? 0;
  }

  static Future<void> markResolved(
    int id,
    String resolution, {
    Database? db,
  }) async {
    final database = await _db(db);
    await database.update(
      'sync_conflicts',
      {'resolved': 1, 'resolution': resolution},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 采用远端值：按实体键直接更新本地行（绕过 LWW 门禁，用户显式选择）。
  static Future<bool> applyRemote(
    PendingSyncConflict conflict, {
    Database? db,
  }) async {
    final database = await _db(db);
    final spec = SyncSpecs.byEntity[conflict.entity];
    if (spec == null || conflict.entity == 'word_book_entries') return false;
    final keyValues = <String, Object?>{};
    for (final column in spec.keyColumns.keys) {
      keyValues[column] = conflict.key[column];
    }
    final where = spec.keyColumns.keys
        .map((column) => '"$column" = ?')
        .join(' AND ');
    final args = keyValues.values.toList();
    final data = {
      for (final column in spec.dataColumns.keys)
        if (conflict.remoteData.containsKey(column))
          column: conflict.remoteData[column],
    };
    if (data.isEmpty) return false;
    await database.transaction((txn) async {
      final updated = await txn.update(
        spec.table,
        data,
        where: where,
        whereArgs: args,
      );
      if (updated == 0) {
        await txn.insert(spec.table, {
          ...keyValues,
          ...data,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      await _bumpVersion(txn, conflict);
    });
    return true;
  }

  /// 保留双方：仅笔记类实体支持，把远端笔记追加到本地笔记后。
  static Future<bool> keepBoth(
    PendingSyncConflict conflict, {
    Database? db,
  }) async {
    if (conflict.entity != 'word_notes' &&
        conflict.entity != 'sentence_notes') {
      return false;
    }
    final database = await _db(db);
    final spec = SyncSpecs.byEntity[conflict.entity]!;
    final remoteNote = (conflict.remoteData['note'] as String?)?.trim() ?? '';
    if (remoteNote.isEmpty) return false;
    final localNote = (conflict.localData['note'] as String?)?.trim() ?? '';
    final merged = localNote.isEmpty
        ? remoteNote
        : '$localNote\n\n---\n远端版本：\n$remoteNote';
    final where = spec.keyColumns.keys
        .map((column) => '"$column" = ?')
        .join(' AND ');
    var updated = 0;
    await database.transaction((txn) async {
      updated = await txn.update(
        spec.table,
        {
          'note': merged,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        where: where,
        whereArgs: [
          for (final column in spec.keyColumns.keys) conflict.key[column],
        ],
      );
      if (updated > 0) {
        await _bumpVersion(txn, conflict);
      }
    });
    return updated > 0;
  }

  /// 冲突解决也是一次本地写入：推进行版本，防止更旧的远端 op 覆盖。
  static Future<void> _bumpVersion(
    DatabaseExecutor db,
    PendingSyncConflict conflict,
  ) async {
    final key = SyncOp(
      deviceId: 'local',
      seq: 1,
      hlc: const SyncHlc(0, 0),
      entity: conflict.entity,
      key: conflict.key,
      op: 'upsert',
    ).keyFingerprint;
    var next = SyncHlc(DateTime.now().millisecondsSinceEpoch, 0);
    final rows = await db.query(
      'sync_row_versions',
      columns: ['hlc'],
      where: 'entity = ? AND key = ?',
      whereArgs: [conflict.entity, key],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      try {
        final existing = SyncHlc.parse(rows.first['hlc'] as String);
        if (existing.compareTo(next) >= 0) {
          next = SyncHlc(existing.ms, existing.counter + 1);
        }
      } on FormatException {
        // 损坏版本直接覆盖
      }
    }
    await db.insert('sync_row_versions', {
      'entity': conflict.entity,
      'key': key,
      'hlc': next.value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    // 冲突解决会产生一条新的本地写入；同步推进 HLC，避免本机时钟落后
    // 于远端时，后续本地编辑拿到更小的 HLC 而被其它设备跳过。
    final metaRows = await db.query(
      'sync_meta',
      columns: ['hlc_ms', 'hlc_counter'],
      where: 'id = 1',
      limit: 1,
    );
    if (metaRows.isNotEmpty) {
      final ms = (metaRows.first['hlc_ms'] as int?) ?? 0;
      final counter = (metaRows.first['hlc_counter'] as int?) ?? 0;
      if (next.compareTo(SyncHlc(ms, counter)) > 0) {
        await db.update('sync_meta', {
          'hlc_ms': next.ms,
          'hlc_counter': next.counter,
        }, where: 'id = 1');
      }
    }
  }

  static PendingSyncConflict _fromRow(Map<String, Object?> row) {
    final key = _decodeMap(row['key']);
    final local = _decodeMap(row['local_json']);
    final remote = _decodeMap(row['remote_json']);
    final createdAt =
        DateTime.tryParse('${row['created_at']}') ?? DateTime.now().toUtc();
    return PendingSyncConflict(
      id: (row['id'] as int?) ?? 0,
      entity: (row['entity'] as String?) ?? '',
      key: key,
      localData: local,
      remoteData: remote,
      localTime: row['local_time'] as String?,
      remoteTime: row['remote_time'] as String?,
      createdAt: createdAt,
    );
  }

  static Map<String, dynamic> _decodeMap(Object? raw) {
    if (raw is! String || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return decoded.cast<String, dynamic>();
    } catch (_) {}
    return const {};
  }
}
