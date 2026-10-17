import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../models/sync_op.dart';
import 'database_service.dart';
import 'sync_table_spec.dart';

/// 一次应用远端 chunk 的结果。
class SyncApplyResult {
  int applied = 0;
  int duplicates = 0;
  int skippedByVersion = 0;
  int skippedUnsupported = 0;
  int skippedMissingParent = 0;
  int conflicts = 0;
  final List<String> conflictDetails = [];
}

/// 应用远端操作：幂等、事务化、按表语义合并。
class SyncApplyService {
  SyncApplyService._();

  static Future<Database> _db(Database? db) async =>
      db ?? await DatabaseService.database;

  static Future<SyncApplyResult> applyOps(
    List<SyncOp> ops, {
    Database? db,
  }) async {
    final database = await _db(db);
    final result = SyncApplyResult();
    if (ops.isEmpty) return result;

    final sorted = [...ops]..sort(_compareOps);
    final pendingParents = <SyncOp>[];

    await database.transaction((txn) async {
      await txn.update('sync_meta', {'applying': 1}, where: 'id = 1');
      try {
        for (final op in sorted) {
          final spec = SyncSpecs.byEntity[op.entity];
          if (spec == null) {
            result.skippedUnsupported++;
            await _recordApplied(txn, op);
            continue;
          }
          if (await _isApplied(txn, op)) {
            result.duplicates++;
            continue;
          }
          final currentVersion = await _versionOf(txn, op);
          if (currentVersion != null && currentVersion.compareTo(op.hlc) >= 0) {
            result.skippedByVersion++;
            // 计数增量代表真实发生的事件，即使整行较旧也不能丢
            await _applyStaleCounterDeltas(txn, spec, op);
            await _recordApplied(txn, op);
            continue;
          }

          if (op.isDelete) {
            await _applyDelete(txn, spec, op);
            await _recordTombstone(txn, op);
            await _advanceVersion(txn, op);
            await _recordApplied(txn, op);
            result.applied++;
            continue;
          }

          final outcome = await _applyUpsert(txn, spec, op, result);
          if (outcome == _UpsertOutcome.pendingParent) {
            pendingParents.add(op);
            continue;
          }
          await _advanceVersion(txn, op);
          await _recordApplied(txn, op);
          if (outcome == _UpsertOutcome.applied) {
            result.applied++;
          } else {
            result.skippedUnsupported++;
          }
        }

        // 子表可能先于父表出现在同一 chunk：再尝试一次
        for (final op in pendingParents) {
          final spec = SyncSpecs.byEntity[op.entity];
          if (spec == null) continue;
          if (await _isApplied(txn, op)) continue;
          final outcome = await _applyUpsert(txn, spec, op, result);
          if (outcome == _UpsertOutcome.pendingParent) {
            result.skippedMissingParent++;
            result.conflictDetails.add(
              '${op.entity} 缺少父级词书：${op.keyFingerprint}',
            );
            // 不记录 applied：父级到达后的下一次同步会重试该 op
            continue;
          }
          await _advanceVersion(txn, op);
          await _recordApplied(txn, op);
          if (outcome == _UpsertOutcome.applied) {
            result.applied++;
          } else {
            result.skippedUnsupported++;
          }
        }
      } finally {
        await txn.update('sync_meta', {'applying': 0}, where: 'id = 1');
      }
    });

    return result;
  }

  static int _compareOps(SyncOp a, SyncOp b) {
    final byHlc = a.hlc.compareTo(b.hlc);
    if (byHlc != 0) return byHlc;
    final byEntity = a.entity.compareTo(b.entity);
    if (byEntity != 0) return byEntity;
    return a.seq.compareTo(b.seq);
  }

  static Future<bool> _isApplied(DatabaseExecutor txn, SyncOp op) async {
    final rows = await txn.query(
      'sync_applied',
      columns: ['seq'],
      where: 'device_id = ? AND entity = ? AND seq = ?',
      whereArgs: [op.deviceId, op.entity, op.seq],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  static Future<void> _recordApplied(DatabaseExecutor txn, SyncOp op) async {
    await txn.insert('sync_applied', {
      'device_id': op.deviceId,
      'entity': op.entity,
      'seq': op.seq,
      'applied_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  static Future<SyncHlc?> _versionOf(DatabaseExecutor txn, SyncOp op) async {
    final rows = await txn.query(
      'sync_row_versions',
      columns: ['hlc'],
      where: 'entity = ? AND key = ?',
      whereArgs: [op.entity, op.keyFingerprint],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return SyncHlc.parse(rows.first['hlc'] as String);
  }

  static Future<void> _advanceVersion(DatabaseExecutor txn, SyncOp op) async {
    final current = await _versionOf(txn, op);
    if (current != null && current.compareTo(op.hlc) >= 0) return;
    await txn.insert('sync_row_versions', {
      'entity': op.entity,
      'key': op.keyFingerprint,
      'hlc': op.hlc.value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> _recordTombstone(DatabaseExecutor txn, SyncOp op) async {
    final rows = await txn.query(
      'sync_tombstones',
      columns: ['deleted_hlc'],
      where: 'entity = ? AND key = ?',
      whereArgs: [op.entity, op.keyFingerprint],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      final existing = SyncHlc.parse(rows.first['deleted_hlc'] as String);
      if (existing.compareTo(op.hlc) >= 0) return;
    }
    await txn.insert('sync_tombstones', {
      'entity': op.entity,
      'key': op.keyFingerprint,
      'deleted_hlc': op.hlc.value,
      'deleted_at': (op.deletedAt ?? DateTime.now().toUtc().toIso8601String()),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static String _whereForKey(SyncTableSpec spec, SyncOp op) {
    return spec.keyColumns.keys.map((k) => '"$k" = ?').join(' AND ');
  }

  static List<Object?> _argsForKey(SyncTableSpec spec, SyncOp op) {
    return [for (final key in spec.keyColumns.keys) op.key[key]];
  }

  static DateTime? _parseTs(Object? value) {
    if (value is! String || value.isEmpty) return null;
    return DateTime.tryParse(value);
  }

  static Future<void> _applyStaleCounterDeltas(
    DatabaseExecutor txn,
    SyncTableSpec spec,
    SyncOp op,
  ) async {
    if (op.isDelete || spec.counters.isEmpty) return;
    final hasDelta = spec.counters.any((c) => (op.delta[c] ?? 0) != 0);
    if (!hasDelta) return;
    final rows = await txn.query(
      spec.table,
      where: _whereForKey(spec, op),
      whereArgs: _argsForKey(spec, op),
      limit: 1,
    );
    if (rows.isEmpty) return;
    final updates = <String, Object?>{};
    for (final counter in spec.counters) {
      final current = (rows.first[counter] as num?)?.toInt() ?? 0;
      updates[counter] = current + (op.delta[counter] ?? 0);
    }
    await txn.update(
      spec.table,
      updates,
      where: _whereForKey(spec, op),
      whereArgs: _argsForKey(spec, op),
    );
  }

  static Future<void> _applyDelete(
    DatabaseExecutor txn,
    SyncTableSpec spec,
    SyncOp op,
  ) async {
    switch (spec.entity) {
      case 'word_book_entries':
        await txn.delete(
          'word_book_entries',
          where: 'book_uuid = ? AND word = ?',
          whereArgs: [op.key['book_uuid'], op.key['word']],
        );
        return;
      case 'word_books':
        await txn.delete(
          'word_book_entries',
          where: 'book_uuid = ?',
          whereArgs: [op.key['uuid']],
        );
        await txn.delete(
          'word_books',
          where: 'uuid = ?',
          whereArgs: [op.key['uuid']],
        );
        return;
      case 'sentences':
        final id = op.key['id'];
        await txn.delete(
          'attempted_sentence_ids',
          where: 'sentence_id = ?',
          whereArgs: [id],
        );
        await txn.delete(
          'practiced_sentence_ids',
          where: 'sentence_id = ?',
          whereArgs: [id],
        );
        await txn.delete(
          'wrong_sentences',
          where: 'sentence_id = ?',
          whereArgs: [id],
        );
        await txn.delete('sentences', where: 'id = ?', whereArgs: [id]);
        return;
      default:
        await txn.delete(
          spec.table,
          where: _whereForKey(spec, op),
          whereArgs: _argsForKey(spec, op),
        );
    }
  }

  static Future<_UpsertOutcome> _applyUpsert(
    DatabaseExecutor txn,
    SyncTableSpec spec,
    SyncOp op,
    SyncApplyResult result,
  ) async {
    for (final column in spec.keyColumns.keys) {
      final value = op.key[column];
      if (value == null || (value is String && value.isEmpty)) {
        result.conflictDetails.add(
          '${spec.entity} 缺少稳定键 "$column"：${op.keyFingerprint}',
        );
        return _UpsertOutcome.skipped;
      }
    }

    if (spec.entity == 'word_book_entries') {
      final bookUuid = op.key['book_uuid'];
      final word = op.key['word'];
      final books = await txn.query(
        'word_books',
        columns: ['id'],
        where: 'uuid = ?',
        whereArgs: [bookUuid],
        limit: 1,
      );
      if (books.isEmpty) return _UpsertOutcome.pendingParent;
      final bookId = books.first['id'];
      final existing = await txn.query(
        'word_book_entries',
        columns: ['id'],
        where: 'book_id = ? AND word = ?',
        whereArgs: [bookId, word],
        limit: 1,
      );
      if (existing.isNotEmpty) return _UpsertOutcome.applied;
      await txn.insert('word_book_entries', {
        'book_id': bookId,
        'book_uuid': bookUuid,
        'word': word,
        'added_at': op.data['added_at'] ?? DateTime.now().toIso8601String(),
      });
      return _UpsertOutcome.applied;
    }

    final where = _whereForKey(spec, op);
    final args = _argsForKey(spec, op);
    final rows = await txn.query(
      spec.table,
      where: where,
      whereArgs: args,
      limit: 1,
    );

    final data = <String, Object?>{
      for (final column in spec.dataColumns.keys)
        if (op.data.containsKey(column)) column: op.data[column],
    };

    // 自然时间戳冲突检查：远端较早时保留本地字段；计数增量仍然应用。
    var allowData = true;
    if (rows.isNotEmpty && spec.lwwColumn != null) {
      final localTs = _parseTs(rows.first[spec.lwwColumn!]);
      final remoteTs = _parseTs(data[spec.lwwColumn!]);
      if (localTs != null && remoteTs != null && remoteTs.isBefore(localTs)) {
        allowData = false;
        result.conflicts++;
        result.conflictDetails.add(
          '${spec.entity} ${op.keyFingerprint} 远端字段较旧，保留本地值',
        );
      }
    }

    if (rows.isEmpty) {
      final values = <String, Object?>{
        for (final column in spec.keyColumns.keys) column: op.key[column],
        ...data,
      };
      for (final counter in spec.counters) {
        values[counter] = op.delta[counter] ?? 0;
      }
      if (spec.entity == 'wrong_sentences') {
        final id = values['id'];
        if (id == null || (id is String && id.isEmpty)) {
          values['id'] = const Uuid().v4();
        }
      }
      await txn.insert(
        spec.table,
        values,
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      return _UpsertOutcome.applied;
    }

    final updates = <String, Object?>{};
    if (allowData) updates.addAll(data);
    for (final counter in spec.counters) {
      final current = (rows.first[counter] as num?)?.toInt() ?? 0;
      updates[counter] = current + (op.delta[counter] ?? 0);
    }
    // 主键保持不变，避免远端 id 与本地其它行冲突
    if (spec.entity == 'wrong_sentences') updates.remove('id');
    if (updates.isNotEmpty) {
      await txn.update(spec.table, updates, where: where, whereArgs: args);
    }
    return _UpsertOutcome.applied;
  }
}

enum _UpsertOutcome { applied, skipped, pendingParent }
