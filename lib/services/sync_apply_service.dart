import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../models/sync_op.dart';
import 'database_service.dart';
import 'sync_conflict_store.dart';
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
  final List<SyncConflict> conflictItems = [];

  /// 时间预算/取消导致 chunk 未全部应用；调用方不要标记 chunk 已完成。
  bool deferred = false;
  bool cancelled = false;
}

/// 应用远端操作：幂等、事务化、按表语义合并。
class SyncApplyService {
  SyncApplyService._();

  static Future<Database> _db(Database? db) async =>
      db ?? await DatabaseService.database;

  static Future<SyncApplyResult> applyOps(
    List<SyncOp> ops, {
    Database? db,
    DateTime? deadline,
    bool Function()? isCancelled,
    int sliceSize = 50,
  }) async {
    final database = await _db(db);
    final result = SyncApplyResult();
    if (ops.isEmpty) return result;

    final sorted = [...ops]..sort(_compareOps);
    var pendingParents = <SyncOp>[];
    var index = 0;
    final size = sliceSize < 1 ? 1 : sliceSize;
    while (index < sorted.length) {
      final slice = <SyncOp>[...pendingParents];
      while (slice.length < size && index < sorted.length) {
        slice.add(sorted[index++]);
      }
      pendingParents = await _applySlice(database, slice, result);
      if (isCancelled?.call() ?? false) {
        result.cancelled = true;
        result.deferred = true;
        break;
      }
      if (deadline != null && !DateTime.now().isBefore(deadline)) {
        result.deferred = true;
        break;
      }
    }
    if (pendingParents.isNotEmpty) {
      result.skippedMissingParent += pendingParents.length;
      for (final op in pendingParents) {
        result.conflictDetails.add('${op.entity} 缺少父级词书：${op.keyFingerprint}');
      }
    }

    if (result.conflictItems.isNotEmpty) {
      try {
        await SyncConflictStore.save(database, result.conflictItems);
      } catch (_) {
        // 冲突展示失败不影响合并结果
      }
    }
    return result;
  }

  /// 在一个事务内应用一小批 op；返回仍未满足父级依赖的 op。
  static Future<List<SyncOp>> _applySlice(
    Database database,
    List<SyncOp> slice,
    SyncApplyResult result,
  ) async {
    final pending = <SyncOp>[];
    await database.transaction((txn) async {
      await txn.update('sync_meta', {'applying': 1}, where: 'id = 1');
      try {
        final ctx = await _ApplyContext.load(txn, slice);
        var appliedInSlice = 0;
        for (final op in slice) {
          if (_isApplied(ctx, op)) {
            result.duplicates++;
            continue;
          }
          if (op.isBulk) {
            final outcome = await _applyBulk(txn, ctx, op, result);
            if (outcome == _UpsertOutcome.pendingParent) {
              pending.add(op);
              continue;
            }
            _recordApplied(ctx, op);
            result.applied += op.items.length;
            appliedInSlice += op.items.length;
            continue;
          }
          final spec = SyncSpecs.byEntity[op.entity];
          if (spec == null) {
            result.skippedUnsupported++;
            _recordApplied(ctx, op);
            continue;
          }
          final currentVersion = _versionOf(ctx, op);
          if (currentVersion != null && currentVersion.compareTo(op.hlc) >= 0) {
            result.skippedByVersion++;
            await _recordVersionConflict(txn, ctx, spec, op, result);
            await _applyStaleCounterDeltas(txn, ctx, spec, op);
            _recordApplied(ctx, op);
            continue;
          }

          if (op.isDelete) {
            await _applyDelete(txn, ctx, spec, op);
            _recordTombstone(ctx, op);
            _advanceVersion(ctx, op);
            _recordApplied(ctx, op);
            result.applied++;
            appliedInSlice++;
            continue;
          }

          final outcome = await _applyUpsert(txn, ctx, spec, op, result);
          if (outcome == _UpsertOutcome.pendingParent) {
            pending.add(op);
            continue;
          }
          _advanceVersion(ctx, op);
          _recordApplied(ctx, op);
          if (outcome == _UpsertOutcome.applied) {
            result.applied++;
            appliedInSlice++;
          } else {
            result.skippedUnsupported++;
          }
        }

        // 子表可能先于父表出现在同一小批：再尝试一次。
        final stillPending = <SyncOp>[];
        for (final op in pending) {
          if (op.isBulk) {
            final outcome = await _applyBulk(txn, ctx, op, result);
            if (outcome == _UpsertOutcome.pendingParent) {
              stillPending.add(op);
              continue;
            }
            _recordApplied(ctx, op);
            result.applied += op.items.length;
            appliedInSlice += op.items.length;
            continue;
          }
          final spec = SyncSpecs.byEntity[op.entity];
          if (spec == null) continue;
          if (_isApplied(ctx, op)) continue;
          final outcome = await _applyUpsert(txn, ctx, spec, op, result);
          if (outcome == _UpsertOutcome.pendingParent) {
            stillPending.add(op);
            continue;
          }
          _advanceVersion(ctx, op);
          _recordApplied(ctx, op);
          if (outcome == _UpsertOutcome.applied) {
            result.applied++;
            appliedInSlice++;
          } else {
            result.skippedUnsupported++;
          }
        }

        await ctx.flush(txn);
        // HLC receive 步骤：本机看到远端事件后，后续本地写入必须排在它之后。
        // 否则设备间时钟偏差会让“看到远端后再编辑”的本地写入拿到更小的
        // HLC，被其它设备当作旧数据跳过。
        await _advanceLocalClock(txn, slice);
        if (appliedInSlice > 0) {
          await txn.rawUpdate(
            'UPDATE sync_meta SET total_ops = total_ops + ? WHERE id = 1',
            [appliedInSlice],
          );
        }
        pending
          ..clear()
          ..addAll(stillPending);
      } finally {
        await txn.update('sync_meta', {'applying': 0}, where: 'id = 1');
      }
    });
    return pending;
  }

  /// 把本地 HLC 推进到本批远端 op 的最大值（标准 HLC receive）。
  static Future<void> _advanceLocalClock(
    DatabaseExecutor txn,
    List<SyncOp> ops,
  ) async {
    if (ops.isEmpty) return;
    var remoteMax = ops.first.hlc;
    for (final op in ops) {
      if (op.hlc.compareTo(remoteMax) > 0) remoteMax = op.hlc;
    }
    final rows = await txn.query(
      'sync_meta',
      columns: ['hlc_ms', 'hlc_counter'],
      where: 'id = 1',
      limit: 1,
    );
    if (rows.isEmpty) return;
    final localMs = (rows.first['hlc_ms'] as int?) ?? 0;
    final localCounter = (rows.first['hlc_counter'] as int?) ?? 0;
    if (remoteMax.compareTo(SyncHlc(localMs, localCounter)) <= 0) return;
    await txn.update('sync_meta', {
      'hlc_ms': remoteMax.ms,
      'hlc_counter': remoteMax.counter,
    }, where: 'id = 1');
  }

  static int _compareOps(SyncOp a, SyncOp b) {
    final byHlc = a.hlc.compareTo(b.hlc);
    if (byHlc != 0) return byHlc;
    final byEntity = a.entity.compareTo(b.entity);
    if (byEntity != 0) return byEntity;
    return a.seq.compareTo(b.seq);
  }

  static Future<void> _recordVersionConflict(
    DatabaseExecutor txn,
    _ApplyContext ctx,
    SyncTableSpec spec,
    SyncOp op,
    SyncApplyResult result,
  ) async {
    final lwwColumn = spec.lwwColumn;
    if (lwwColumn == null) return;
    final remoteTs = _parseTs(op.data[lwwColumn]);
    if (remoteTs == null) return;
    final row = ctx.rowFor(spec, op.key);
    if (row == null) return;
    final localTs = _parseTs(row[lwwColumn]);
    if (localTs == null || !remoteTs.isAfter(localTs)) return;
    result.conflicts++;
    result.conflictDetails.add(
      '${spec.entity} ${op.keyFingerprint} 远端时间较新但行版本较旧，已保留本地值',
    );
    result.conflictItems.add(
      SyncConflict(
        entity: spec.entity,
        key: op.key,
        localData: {
          for (final column in spec.dataColumns.keys)
            if (row.containsKey(column)) column: row[column],
        },
        remoteData: {
          for (final column in spec.dataColumns.keys)
            if (op.data.containsKey(column)) column: op.data[column],
        },
        localTimestamp: row[lwwColumn] as String?,
        remoteTimestamp: op.data[lwwColumn] as String?,
      ),
    );
  }

  /// 应用批量 op：逐条复用 upsert 语义，但只记录一次 bulk seq。
  ///
  /// 批量 op 只用于可幂等插入的实体（词书条目/句子）；若父级缺失，
  /// 整个 bulk op 不记录 applied，下一次同步重试。
  static Future<_UpsertOutcome> _applyBulk(
    DatabaseExecutor txn,
    _ApplyContext ctx,
    SyncOp op,
    SyncApplyResult result,
  ) async {
    var appliedAny = false;
    for (final item in op.items) {
      final spec = SyncSpecs.byEntity[item.entity];
      if (spec == null) {
        result.skippedUnsupported++;
        continue;
      }
      final sub = SyncOp(
        deviceId: op.deviceId,
        seq: op.seq,
        hlc: op.hlc,
        entity: item.entity,
        key: item.key,
        op: 'upsert',
        data: item.data,
        delta: item.delta,
      );
      // bulk 与普通 op 使用同一套行版本门禁：旧批量导入不能覆盖更新版本。
      final currentVersion = _versionOf(ctx, sub);
      if (currentVersion != null && currentVersion.compareTo(sub.hlc) >= 0) {
        result.skippedByVersion++;
        await _recordVersionConflict(txn, ctx, spec, sub, result);
        await _applyStaleCounterDeltas(txn, ctx, spec, sub);
        continue;
      }
      final outcome = await _applyUpsert(txn, ctx, spec, sub, result);
      if (outcome == _UpsertOutcome.pendingParent) {
        return _UpsertOutcome.pendingParent;
      }
      if (outcome == _UpsertOutcome.applied) {
        _advanceVersion(ctx, sub);
        appliedAny = true;
      }
    }
    return appliedAny ? _UpsertOutcome.applied : _UpsertOutcome.skipped;
  }

  static bool _isApplied(_ApplyContext ctx, SyncOp op) {
    final seqs = ctx.applied[op.deviceId]?[op.entity];
    return seqs != null && seqs.contains(op.seq);
  }

  static void _recordApplied(_ApplyContext ctx, SyncOp op) {
    final byEntity = ctx.applied.putIfAbsent(op.deviceId, () => {});
    final seqs = byEntity.putIfAbsent(op.entity, () => <int>{});
    if (!seqs.add(op.seq)) return;
    ctx.appliedRows.add({
      'device_id': op.deviceId,
      'entity': op.entity,
      'seq': op.seq,
      'hlc': op.hlc.value,
      'applied_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  static SyncHlc? _versionOf(_ApplyContext ctx, SyncOp op) {
    return ctx.versions['${op.entity}\u0000${op.keyFingerprint}'];
  }

  /// 仅由键生成指纹（用于父级墓碑查询）。
  static String _keyFingerprint(Map<String, dynamic> key) => SyncOp(
    deviceId: 'local',
    seq: 1,
    hlc: const SyncHlc(0, 0),
    entity: 'local',
    key: key,
    op: 'upsert',
  ).keyFingerprint;

  static void _advanceVersion(_ApplyContext ctx, SyncOp op) {
    final key = '${op.entity}\u0000${op.keyFingerprint}';
    final current = ctx.versions[key];
    if (current != null && current.compareTo(op.hlc) >= 0) return;
    ctx.versions[key] = op.hlc;
    ctx.versionRows[key] = {
      'entity': op.entity,
      'key': op.keyFingerprint,
      'hlc': op.hlc.value,
    };
  }

  static void _recordTombstone(_ApplyContext ctx, SyncOp op) {
    final key = '${op.entity}\u0000${op.keyFingerprint}';
    final existing = ctx.tombstones[key];
    if (existing != null && existing.compareTo(op.hlc) >= 0) return;
    ctx.tombstones[key] = op.hlc;
    ctx.tombstoneRows[key] = {
      'entity': op.entity,
      'key': op.keyFingerprint,
      'deleted_hlc': op.hlc.value,
      'deleted_at': (op.deletedAt ?? DateTime.now().toUtc().toIso8601String()),
    };
  }

  /// 父级删除时给子表补墓碑，避免迟到的旧子表 op 在父级重建后复活。
  static void _recordChildTombstone(
    _ApplyContext ctx,
    String entity,
    Map<String, dynamic> key,
    SyncOp parent,
  ) {
    _recordTombstone(
      ctx,
      SyncOp(
        deviceId: parent.deviceId,
        seq: parent.seq,
        hlc: parent.hlc,
        entity: entity,
        key: key,
        op: 'delete',
        deletedAt: parent.deletedAt,
      ),
    );
  }

  static DateTime? _parseTs(Object? value) {
    if (value is! String || value.isEmpty) return null;
    return DateTime.tryParse(value);
  }

  static Future<void> _applyStaleCounterDeltas(
    DatabaseExecutor txn,
    _ApplyContext ctx,
    SyncTableSpec spec,
    SyncOp op,
  ) async {
    if (op.isDelete || spec.counters.isEmpty) return;
    final hasDelta = spec.counters.any((c) => (op.delta[c] ?? 0) != 0);
    if (!hasDelta) return;
    final row = ctx.rowFor(spec, op.key);
    if (row == null) return;
    final updates = <String, Object?>{};
    for (final counter in spec.counters) {
      final current = (row[counter] as num?)?.toInt() ?? 0;
      final value = current + (op.delta[counter] ?? 0);
      updates[counter] = value;
      row[counter] = value;
    }
    ctx.queueUpdate(spec, op.key, updates);
  }

  static Future<void> _applyDelete(
    DatabaseExecutor txn,
    _ApplyContext ctx,
    SyncTableSpec spec,
    SyncOp op,
  ) async {
    ctx.removeRow(spec, op.key);
    switch (spec.entity) {
      case 'word_book_entries':
        ctx.queueDelete(spec, op.key);
        return;
      case 'word_books':
        final bookUuid = op.key['uuid'];
        ctx.removeWritesWhere(
          (write) =>
              write.spec.entity == 'word_book_entries' &&
              write.key['book_uuid'] == bookUuid,
        );
        ctx.removeRowsWhere('word_book_entries', 'book_uuid', bookUuid);
        await txn.delete(
          'word_book_entries',
          where: 'book_uuid = ?',
          whereArgs: [bookUuid],
        );
        ctx.queueDelete(spec, op.key);
        return;
      case 'sentences':
        final id = op.key['id'];
        // 先给级联删除的子表写墓碑，再删除；这样乱序到达的旧子表 op
        // 不会在句子/句式集重建后复活。
        final attemptedRows = await txn.query(
          'attempted_sentence_ids',
          columns: ['set_id'],
          where: 'sentence_id = ?',
          whereArgs: [id],
        );
        for (final row in attemptedRows) {
          _recordChildTombstone(ctx, 'attempted_sentence_ids', {
            'set_id': row['set_id'],
            'sentence_id': id,
          }, op);
        }
        final practicedRows = await txn.query(
          'practiced_sentence_ids',
          columns: ['set_id'],
          where: 'sentence_id = ?',
          whereArgs: [id],
        );
        for (final row in practicedRows) {
          _recordChildTombstone(ctx, 'practiced_sentence_ids', {
            'set_id': row['set_id'],
            'sentence_id': id,
          }, op);
        }
        _recordChildTombstone(ctx, 'wrong_sentences', {'sentence_id': id}, op);
        ctx.removeWritesWhere(
          (write) =>
              (write.spec.entity == 'attempted_sentence_ids' ||
                  write.spec.entity == 'practiced_sentence_ids' ||
                  write.spec.entity == 'wrong_sentences') &&
              write.key['sentence_id'] == id,
        );
        for (final entity in const [
          'attempted_sentence_ids',
          'practiced_sentence_ids',
          'wrong_sentences',
        ]) {
          ctx.removeRowsWhere(entity, 'sentence_id', id);
        }
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
        ctx.queueDelete(spec, op.key);
        return;
      case 'sentence_sets':
        final setId = op.key['id'];
        final sentenceRows = await txn.query(
          'sentences',
          columns: ['id'],
          where: 'set_id = ?',
          whereArgs: [setId],
        );
        for (final row in sentenceRows) {
          _recordChildTombstone(ctx, 'sentences', {'id': row['id']}, op);
        }
        final attemptedRows = await txn.query(
          'attempted_sentence_ids',
          columns: ['sentence_id'],
          where: 'set_id = ?',
          whereArgs: [setId],
        );
        for (final row in attemptedRows) {
          _recordChildTombstone(ctx, 'attempted_sentence_ids', {
            'set_id': setId,
            'sentence_id': row['sentence_id'],
          }, op);
        }
        final practicedRows = await txn.query(
          'practiced_sentence_ids',
          columns: ['sentence_id'],
          where: 'set_id = ?',
          whereArgs: [setId],
        );
        for (final row in practicedRows) {
          _recordChildTombstone(ctx, 'practiced_sentence_ids', {
            'set_id': setId,
            'sentence_id': row['sentence_id'],
          }, op);
        }
        final wrongRows = await txn.query(
          'wrong_sentences',
          columns: ['sentence_id'],
          where: 'set_id = ?',
          whereArgs: [setId],
        );
        for (final row in wrongRows) {
          _recordChildTombstone(ctx, 'wrong_sentences', {
            'sentence_id': row['sentence_id'],
          }, op);
        }
        ctx.removeWritesWhere(
          (write) =>
              (write.spec.entity == 'sentences' ||
                  write.spec.entity == 'attempted_sentence_ids' ||
                  write.spec.entity == 'practiced_sentence_ids' ||
                  write.spec.entity == 'wrong_sentences') &&
              write.key['set_id'] == setId,
        );
        for (final entity in const [
          'sentences',
          'attempted_sentence_ids',
          'practiced_sentence_ids',
          'wrong_sentences',
        ]) {
          ctx.removeRowsWhere(entity, 'set_id', setId);
        }
        await txn.delete('sentences', where: 'set_id = ?', whereArgs: [setId]);
        await txn.delete(
          'attempted_sentence_ids',
          where: 'set_id = ?',
          whereArgs: [setId],
        );
        await txn.delete(
          'practiced_sentence_ids',
          where: 'set_id = ?',
          whereArgs: [setId],
        );
        await txn.delete(
          'wrong_sentences',
          where: 'set_id = ?',
          whereArgs: [setId],
        );
        ctx.queueDelete(spec, op.key);
        return;
      default:
        ctx.queueDelete(spec, op.key);
    }
  }

  static Future<_UpsertOutcome> _applyUpsert(
    DatabaseExecutor txn,
    _ApplyContext ctx,
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

    // 墓碑优先于行版本：父级删除时会给子表写墓碑，阻止迟到的旧 op
    // 在父级不存在（或已被重建）后重新插入孤儿数据。
    final tombstone = ctx.tombstones['${op.entity}\u0000${op.keyFingerprint}'];
    if (tombstone != null && tombstone.compareTo(op.hlc) >= 0) {
      return _UpsertOutcome.skipped;
    }

    // 父级已被删除且当前不存在时，晚到的句子 op 直接丢弃，避免孤儿行。
    if (spec.entity == 'sentences') {
      final setId = op.data['set_id'] ?? op.key['set_id'];
      if (setId != null) {
        final parentTombstone = ctx
            .tombstones['sentence_sets\u0000${_keyFingerprint({'id': setId})}'];
        if (parentTombstone != null) {
          final parentRows = await txn.query(
            'sentence_sets',
            columns: ['id'],
            where: 'id = ?',
            whereArgs: [setId],
            limit: 1,
          );
          if (parentRows.isEmpty) return _UpsertOutcome.skipped;
        }
      }
    }

    if (spec.entity == 'word_book_entries') {
      final bookUuid = op.key['book_uuid'];
      final word = op.key['word'];
      final parentTombstone = ctx
          .tombstones['word_books\u0000${_keyFingerprint({'uuid': bookUuid})}'];
      if (parentTombstone != null && parentTombstone.compareTo(op.hlc) >= 0) {
        return _UpsertOutcome.skipped;
      }
      var bookId = ctx.bookIdFor(bookUuid);
      if (bookId == null) {
        final books = await txn.query(
          'word_books',
          columns: ['id'],
          where: 'uuid = ?',
          whereArgs: [bookUuid],
          limit: 1,
        );
        if (books.isEmpty) {
          // 父级被删除且尚未重建：丢弃子表 op，而不是每轮 pending 重试。
          return parentTombstone != null
              ? _UpsertOutcome.skipped
              : _UpsertOutcome.pendingParent;
        }
        bookId = books.first['id'];
        ctx.putBookId(bookUuid, bookId);
      }
      if (ctx.rowFor(spec, op.key) != null) {
        return _UpsertOutcome.applied;
      }
      final values = <String, Object?>{
        'book_id': bookId,
        'book_uuid': bookUuid,
        'word': word,
        'added_at': op.data['added_at'] ?? DateTime.now().toIso8601String(),
      };
      ctx.queueInsert(spec, op.key, values);
      ctx.putRow(spec, op.key, values);
      return _UpsertOutcome.applied;
    }

    final row = ctx.rowFor(spec, op.key);

    final data = <String, Object?>{
      for (final column in spec.dataColumns.keys)
        if (op.data.containsKey(column)) column: op.data[column],
    };

    // 自然时间戳冲突检查：远端较早时保留本地字段；计数增量仍然应用。
    var allowData = true;
    if (row != null && spec.lwwColumn != null) {
      final localTs = _parseTs(row[spec.lwwColumn!]);
      final remoteTs = _parseTs(data[spec.lwwColumn!]);
      if (localTs != null && remoteTs != null && remoteTs.isBefore(localTs)) {
        allowData = false;
        result.conflicts++;
        result.conflictDetails.add(
          '${spec.entity} ${op.keyFingerprint} 远端字段较旧，保留本地值',
        );
        result.conflictItems.add(
          SyncConflict(
            entity: spec.entity,
            key: op.key,
            localData: {
              for (final column in spec.dataColumns.keys)
                if (row.containsKey(column)) column: row[column],
            },
            remoteData: data,
            localTimestamp: row[spec.lwwColumn!] as String?,
            remoteTimestamp: data[spec.lwwColumn!] as String?,
          ),
        );
      }
    }

    if (row == null) {
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
      if (spec.entity == 'word_books') {
        final id = await txn.insert(
          spec.table,
          values,
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        values['id'] = id;
        ctx.putRow(spec, op.key, values);
      } else {
        ctx.queueInsert(spec, op.key, values);
        ctx.putRow(spec, op.key, values);
      }
      return _UpsertOutcome.applied;
    }

    final updates = <String, Object?>{};
    if (allowData) updates.addAll(data);
    for (final counter in spec.counters) {
      final current = (row[counter] as num?)?.toInt() ?? 0;
      updates[counter] = current + (op.delta[counter] ?? 0);
    }
    // 主键保持不变，避免远端 id 与本地其它行冲突
    if (spec.entity == 'wrong_sentences') updates.remove('id');
    if (updates.isNotEmpty) {
      ctx.queueUpdate(spec, op.key, updates);
      row.addAll(updates);
    }
    return _UpsertOutcome.applied;
  }
}

/// 一次 chunk 应用期间的内存索引。
///
/// 预载 + 事务末尾批量写回，避免逐条 SELECT / INSERT 占用 SQLite 写锁。
class _ApplyContext {
  /// deviceId → entity → 已应用的 seq。
  final Map<String, Map<String, Set<int>>> applied = {};

  /// `entity\u0000keyFingerprint` → 最新 HLC。
  final Map<String, SyncHlc> versions = {};

  /// 同上 → 墓碑 HLC。
  final Map<String, SyncHlc> tombstones = {};

  final List<Map<String, Object?>> appliedRows = [];
  final Map<String, Map<String, Object?>> versionRows = {};
  final Map<String, Map<String, Object?>> tombstoneRows = {};

  /// entity + keyFingerprint → 当前行（预载 + 本批次虚拟更新）。
  final Map<String, Map<String, Object?>> rows = {};

  /// word_books.uuid → id，供词书条目快速解析父级。
  final Map<Object?, Object?> bookIds = {};

  /// entity + key → 待写入的行（事务末尾一次 batch 提交）。
  final Map<String, _RowWrite> writes = {};

  static String _rowKey(String entity, Map<String, dynamic> key) {
    return '$entity\u0000${SyncOp(deviceId: 'local', seq: 1, hlc: const SyncHlc(0, 0), entity: entity, key: key, op: 'upsert').keyFingerprint}';
  }

  static String _keyFingerprint(Map<String, dynamic> key) => SyncOp(
    deviceId: 'local',
    seq: 1,
    hlc: const SyncHlc(0, 0),
    entity: 'local',
    key: key,
    op: 'upsert',
  ).keyFingerprint;

  Map<String, Object?>? rowFor(SyncTableSpec spec, Map<String, dynamic> key) =>
      rows[_rowKey(spec.entity, key)];

  void putRow(
    SyncTableSpec spec,
    Map<String, dynamic> key,
    Map<String, Object?> values,
  ) {
    rows[_rowKey(spec.entity, key)] = Map<String, Object?>.from(values);
  }

  void removeRow(SyncTableSpec spec, Map<String, dynamic> key) {
    rows.remove(_rowKey(spec.entity, key));
  }

  Object? bookIdFor(Object? uuid) => bookIds[uuid];

  void putBookId(Object? uuid, Object? id) {
    if (uuid != null) bookIds[uuid] = id;
  }

  void queueInsert(
    SyncTableSpec spec,
    Map<String, dynamic> key,
    Map<String, Object?> values,
  ) {
    writes[_rowKey(spec.entity, key)] = _RowWrite(
      spec: spec,
      key: Map<String, dynamic>.from(key),
      values: Map<String, Object?>.from(values),
      insert: true,
    );
  }

  void queueUpdate(
    SyncTableSpec spec,
    Map<String, dynamic> key,
    Map<String, Object?> updates,
  ) {
    final id = _rowKey(spec.entity, key);
    final existing = writes[id];
    if (existing != null && existing.insert) {
      existing.values.addAll(updates);
      return;
    }
    if (existing != null && existing.delete) {
      writes[id] = _RowWrite(
        spec: spec,
        key: Map<String, dynamic>.from(key),
        values: Map<String, Object?>.from(updates),
        insert: true,
      );
      return;
    }
    final write =
        existing ??
        _RowWrite(
          spec: spec,
          key: Map<String, dynamic>.from(key),
          values: <String, Object?>{},
        );
    write.values.addAll(updates);
    writes[id] = write;
  }

  void queueDelete(SyncTableSpec spec, Map<String, dynamic> key) {
    final id = _rowKey(spec.entity, key);
    writes[id] = _RowWrite(
      spec: spec,
      key: Map<String, dynamic>.from(key),
      values: const {},
      delete: true,
    );
    rows.remove(id);
  }

  /// 删除父级时移除同一小批中尚未 flush 的子级写入，避免级联后再复活。
  void removeWritesWhere(bool Function(_RowWrite write) test) {
    final keys = writes.entries
        .where((entry) => test(entry.value))
        .map((entry) => entry.key)
        .toList();
    for (final key in keys) {
      writes.remove(key);
      rows.remove(key);
    }
  }

  /// 级联删除时同步移除已预载的虚拟行。
  void removeRowsWhere(String entity, String column, Object? value) {
    final prefix = '$entity\u0000';
    final keys = rows.entries
        .where(
          (entry) =>
              entry.key.startsWith(prefix) && entry.value[column] == value,
        )
        .map((entry) => entry.key)
        .toList();
    for (final key in keys) {
      rows.remove(key);
    }
  }

  Future<void> flushWrites(DatabaseExecutor txn) async {
    if (writes.isEmpty) return;
    final batch = txn.batch();
    for (final write in writes.values) {
      final spec = write.spec;
      final where = spec.keyColumns.keys
          .map((column) => '"$column" = ?')
          .join(' AND ');
      final args = [
        for (final column in spec.keyColumns.keys) write.key[column],
      ];
      if (write.delete) {
        batch.delete(spec.table, where: where, whereArgs: args);
      } else if (write.insert) {
        batch.insert(
          spec.table,
          write.values,
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      } else {
        batch.update(spec.table, write.values, where: where, whereArgs: args);
      }
    }
    await batch.commit(noResult: true);
    writes.clear();
  }

  static Future<_ApplyContext> load(
    DatabaseExecutor txn,
    List<SyncOp> ops,
  ) async {
    final ctx = _ApplyContext();
    if (ops.isEmpty) return ctx;

    // 已应用 seq：按 (device, entity) 一次查询。
    final appliedGroups = <String, Set<int>>{};
    for (final op in ops) {
      appliedGroups
          .putIfAbsent('${op.deviceId}\u0000${op.entity}', () => <int>{})
          .add(op.seq);
    }
    for (final entry in appliedGroups.entries) {
      final parts = entry.key.split('\u0000');
      final seqs = entry.value.toList();
      for (var i = 0; i < seqs.length; i += 400) {
        final slice = seqs.sublist(i, (i + 400).clamp(0, seqs.length));
        final placeholders = List.filled(slice.length, '?').join(',');
        final rows = await txn.rawQuery(
          'SELECT seq FROM sync_applied '
          'WHERE device_id = ? AND entity = ? AND seq IN ($placeholders)',
          [parts[0], parts[1], ...slice],
        );
        final byEntity = ctx.applied.putIfAbsent(parts[0], () => {});
        final set = byEntity.putIfAbsent(parts[1], () => <int>{});
        for (final row in rows) {
          final seq = row['seq'];
          if (seq is int) set.add(seq);
        }
      }
    }

    // 行版本：按 entity 分组，key 列表分批查询。
    // bulk op 的实体键在 items 里，必须展开，否则 bulk 无法读取既有版本，
    // 会绕过版本门禁覆盖更新的行。
    final keysByEntity = <String, Set<String>>{};
    for (final op in ops) {
      if (op.isBulk) {
        for (final item in op.items) {
          keysByEntity
              .putIfAbsent(item.entity, () => <String>{})
              .add(_keyFingerprint(item.key));
        }
      } else {
        keysByEntity
            .putIfAbsent(op.entity, () => <String>{})
            .add(op.keyFingerprint);
      }
    }
    for (final entry in keysByEntity.entries) {
      final keys = entry.value.toList();
      for (var i = 0; i < keys.length; i += 400) {
        final slice = keys.sublist(i, (i + 400).clamp(0, keys.length));
        final placeholders = List.filled(slice.length, '?').join(',');
        final rows = await txn.rawQuery(
          'SELECT key, hlc FROM sync_row_versions '
          'WHERE entity = ? AND key IN ($placeholders)',
          [entry.key, ...slice],
        );
        for (final row in rows) {
          final key = row['key'];
          final hlc = row['hlc'];
          if (key is String && hlc is String) {
            try {
              ctx.versions['${entry.key}\u0000$key'] = SyncHlc.parse(hlc);
            } on FormatException {
              // 损坏的行版本忽略：后续按 HLC 正常比较
            }
          }
        }
      }
    }

    // 墓碑：普通 upsert / delete / bulk item 都预载，防止父级删除后旧子表
    // op 重新插入孤儿数据。
    final tombstoneKeysByEntity = <String, Set<String>>{};
    void addTombstoneKey(
      String entity,
      Map<String, dynamic> key, [
      Map<String, dynamic> data = const {},
    ]) {
      tombstoneKeysByEntity
          .putIfAbsent(entity, () => <String>{})
          .add(_keyFingerprint(key));
      // 词书条目需要父级墓碑：父词书删除后，迟到的旧条目 op 应被丢弃，
      // 而不是在父级重建后重新插入。
      if (entity == 'word_book_entries') {
        final bookUuid = key['book_uuid'];
        if (bookUuid != null) {
          tombstoneKeysByEntity
              .putIfAbsent('word_books', () => <String>{})
              .add(_keyFingerprint({'uuid': bookUuid}));
        }
      }
      // 句子需要父级句式集墓碑：父级删除后，晚到的句子 op 不能成为孤儿。
      if (entity == 'sentences') {
        final setId = data['set_id'] ?? key['set_id'];
        if (setId != null) {
          tombstoneKeysByEntity
              .putIfAbsent('sentence_sets', () => <String>{})
              .add(_keyFingerprint({'id': setId}));
        }
      }
    }

    for (final op in ops) {
      if (op.isBulk) {
        for (final item in op.items) {
          addTombstoneKey(item.entity, item.key, item.data);
        }
      } else {
        addTombstoneKey(op.entity, op.key, op.data);
      }
    }
    for (final entry in tombstoneKeysByEntity.entries) {
      final keys = entry.value.toList();
      for (var i = 0; i < keys.length; i += 400) {
        final slice = keys.sublist(i, (i + 400).clamp(0, keys.length));
        final placeholders = List.filled(slice.length, '?').join(',');
        final rows = await txn.rawQuery(
          'SELECT key, deleted_hlc FROM sync_tombstones '
          'WHERE entity = ? AND key IN ($placeholders)',
          [entry.key, ...slice],
        );
        for (final row in rows) {
          final key = row['key'];
          final hlc = row['deleted_hlc'];
          if (key is String && hlc is String) {
            try {
              ctx.tombstones['${entry.key}\u0000$key'] = SyncHlc.parse(hlc);
            } on FormatException {
              // 忽略损坏的墓碑
            }
          }
        }
      }
    }
    // 预载业务行：把逐 op SELECT 收敛为每个实体几次批量查询。
    final rowKeysByEntity = <String, Map<String, Map<String, dynamic>>>{};
    void addRowKey(String entity, Map<String, dynamic> key) {
      rowKeysByEntity
          .putIfAbsent(entity, () => {})
          .putIfAbsent(_rowKey(entity, key), () => key);
    }

    for (final op in ops) {
      if (op.isBulk) {
        for (final item in op.items) {
          addRowKey(item.entity, item.key);
        }
      } else {
        addRowKey(op.entity, op.key);
      }
    }
    final entryBookUuids = <Object?>{};
    for (final entry in rowKeysByEntity.entries) {
      final spec = SyncSpecs.byEntity[entry.key];
      if (spec == null) continue;
      final keys = entry.value.values.toList();
      for (var i = 0; i < keys.length; i += 200) {
        final end = (i + 200) > keys.length ? keys.length : i + 200;
        final slice = keys.sublist(i, end);
        final clauses = <String>[];
        final args = <Object?>[];
        for (final key in slice) {
          final columns = spec.keyColumns.keys.toList();
          final parts = <String>[];
          for (final column in columns) {
            parts.add('"$column" = ?');
            args.add(key[column]);
          }
          clauses.add('(${parts.join(' AND ')})');
        }
        if (clauses.isEmpty) continue;
        final rows = await txn.query(
          spec.table,
          where: clauses.join(' OR '),
          whereArgs: args,
        );
        for (final row in rows) {
          final keyMap = <String, dynamic>{
            for (final column in spec.keyColumns.keys) column: row[column],
          };
          ctx.putRow(spec, keyMap, row);
          if (spec.entity == 'word_book_entries') {
            final uuid = row['book_uuid'];
            if (uuid != null) entryBookUuids.add(uuid);
          }
        }
      }
    }

    if (entryBookUuids.isNotEmpty) {
      final uuids = entryBookUuids.toList();
      for (var i = 0; i < uuids.length; i += 400) {
        final end = (i + 400) > uuids.length ? uuids.length : i + 400;
        final slice = uuids.sublist(i, end);
        final placeholders = List.filled(slice.length, '?').join(',');
        final rows = await txn.rawQuery(
          'SELECT id, uuid FROM word_books WHERE uuid IN ($placeholders)',
          slice,
        );
        for (final row in rows) {
          ctx.putBookId(row['uuid'], row['id']);
        }
      }
    }

    return ctx;
  }

  Future<void> flush(DatabaseExecutor txn) async {
    await flushWrites(txn);
    if (appliedRows.isEmpty && versionRows.isEmpty && tombstoneRows.isEmpty) {
      return;
    }
    final batch = txn.batch();
    for (final row in appliedRows) {
      batch.insert(
        'sync_applied',
        row,
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    for (final row in versionRows.values) {
      batch.insert(
        'sync_row_versions',
        row,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    for (final row in tombstoneRows.values) {
      batch.insert(
        'sync_tombstones',
        row,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }
}

class _RowWrite {
  final SyncTableSpec spec;
  final Map<String, dynamic> key;
  final Map<String, Object?> values;
  final bool insert;
  final bool delete;

  const _RowWrite({
    required this.spec,
    required this.key,
    required this.values,
    this.insert = false,
    this.delete = false,
  });
}

enum _UpsertOutcome { applied, skipped, pendingParent }
