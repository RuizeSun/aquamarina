import 'dart:convert';
import 'dart:typed_data';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/cloud_sync_manifest.dart';
import '../models/sync_op.dart';
import 'database_service.dart';
import 'sync_table_spec.dart';

/// 一批待上传的本地操作。
class SyncBatch {
  final List<SyncOp> ops;
  final Uint8List bytes;

  const SyncBatch({required this.ops, required this.bytes});

  String get sha256 => CloudSyncUtils.sha256Hex(bytes);

  bool get isEmpty => ops.isEmpty;
}

/// 本地变更捕获服务：把 SQLite oplog 转成不可变的 JSONL chunk。
///
/// 流程：
/// 1. 在事务内为待导出 oplog 行分配持久化 HLC（重试时保持同一顺序）；
/// 2. 按 (hlc, entity, seq) 排序并切分为不超过 [maxOps] / [maxBytes] 的批次；
/// 3. 上传成功后调用 [markUploaded] 删除对应 oplog 行。
class SyncCaptureService {
  SyncCaptureService._();

  static const int defaultMaxOps = 500;
  static const int defaultMaxBytes = 900 * 1024;

  static Future<Database> _db(Database? db) async =>
      db ?? await DatabaseService.database;

  /// 本地待上传的操作总数。
  static Future<int> pendingCount({Database? db}) async {
    final database = await _db(db);
    var total = 0;
    for (final spec in SyncSpecs.all) {
      final rows = await database.rawQuery(
        'SELECT COUNT(*) AS c FROM "${spec.oplogTable}"',
      );
      total += (rows.first['c'] as int?) ?? 0;
    }
    return total;
  }

  /// 取出下一批待上传操作；没有待上传内容时返回 null。
  ///
  /// [deviceId] 在 `sync_meta` 尚未初始化时写入；为空且 meta 也未初始化时抛错。
  static Future<SyncBatch?> takePendingBatch({
    Database? db,
    String? deviceId,
    int maxOps = defaultMaxOps,
    int maxBytes = defaultMaxBytes,
  }) async {
    final database = await _db(db);
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    await database.transaction((txn) async {
      final metaRows = await txn.query('sync_meta', where: 'id = 1', limit: 1);
      final meta = metaRows.isEmpty
          ? const <String, Object?>{}
          : metaRows.first;
      final metaDeviceId = (meta['device_id'] as String?) ?? '';
      if (metaDeviceId.isEmpty) {
        if (deviceId == null || deviceId.isEmpty) {
          throw const CloudSyncException('同步设备标识尚未初始化');
        }
        await txn.update('sync_meta', {'device_id': deviceId}, where: 'id = 1');
      }

      var lastMs = (meta['hlc_ms'] as int?) ?? 0;
      var lastCounter = (meta['hlc_counter'] as int?) ?? 0;
      var assigned = 0;

      for (final spec in SyncSpecs.all) {
        if (assigned >= maxOps) break;
        final rows = await txn.query(
          spec.oplogTable,
          columns: ['seq'],
          where: 'hlc_ms IS NULL',
          orderBy: 'seq ASC',
          limit: maxOps - assigned,
        );
        for (final row in rows) {
          final hlc = SyncHlc.next(
            nowMs: nowMs,
            lastMs: lastMs,
            lastCounter: lastCounter,
          );
          lastMs = hlc.ms;
          lastCounter = hlc.counter;
          await txn.update(
            spec.oplogTable,
            {'hlc_ms': hlc.ms, 'hlc_counter': hlc.counter},
            where: 'seq = ?',
            whereArgs: [row['seq']],
          );
          assigned++;
        }
      }

      if (assigned > 0) {
        await txn.update('sync_meta', {
          'hlc_ms': lastMs,
          'hlc_counter': lastCounter,
        }, where: 'id = 1');
      }
    });

    final metaRows = await database.query(
      'sync_meta',
      where: 'id = 1',
      limit: 1,
    );
    final resolvedDeviceId = metaRows.isEmpty
        ? ''
        : (metaRows.first['device_id'] as String? ?? '');
    if (resolvedDeviceId.isEmpty) {
      throw const CloudSyncException('同步设备标识尚未初始化');
    }

    final ops = <SyncOp>[];
    for (final spec in SyncSpecs.all) {
      final rows = await database.query(
        spec.oplogTable,
        where: 'hlc_ms IS NOT NULL',
        orderBy: 'hlc_ms ASC, hlc_counter ASC, seq ASC',
        limit: maxOps,
      );
      for (final row in rows) {
        ops.add(_rowToOp(spec, row, resolvedDeviceId));
      }
    }
    if (ops.isEmpty) return null;

    ops.sort((a, b) {
      final byHlc = a.hlc.compareTo(b.hlc);
      if (byHlc != 0) return byHlc;
      final byEntity = a.entity.compareTo(b.entity);
      if (byEntity != 0) return byEntity;
      return a.seq.compareTo(b.seq);
    });

    // 按字节上限截断，避免单个 chunk 过大
    final selected = <SyncOp>[];
    var bytes = 0;
    for (final op in ops) {
      final lineBytes = utf8.encode(jsonEncode(op.toJson())).length + 1;
      if (selected.isNotEmpty && bytes + lineBytes > maxBytes) break;
      selected.add(op);
      bytes += lineBytes;
      if (selected.length >= maxOps) break;
    }
    if (selected.isEmpty) return null;

    final batch = SyncBatch(
      ops: selected,
      bytes: SyncChunkCodec.encode(selected),
    );

    // 先记录本地版本：即使上传失败，也能阻止更旧的远端操作覆盖本地数据。
    await database.transaction((txn) async {
      for (final op in selected) {
        await _rememberVersion(txn, op);
      }
    });
    return batch;
  }

  static Future<void> _rememberVersion(DatabaseExecutor txn, SyncOp op) async {
    final key = op.keyFingerprint;
    final rows = await txn.query(
      'sync_row_versions',
      columns: ['hlc'],
      where: 'entity = ? AND key = ?',
      whereArgs: [op.entity, key],
      limit: 1,
    );
    if (rows.isEmpty) {
      await txn.insert('sync_row_versions', {
        'entity': op.entity,
        'key': key,
        'hlc': op.hlc.value,
      });
      return;
    }
    final existing = SyncHlc.parse(rows.first['hlc'] as String);
    if (op.hlc.compareTo(existing) > 0) {
      await txn.update(
        'sync_row_versions',
        {'hlc': op.hlc.value},
        where: 'entity = ? AND key = ?',
        whereArgs: [op.entity, key],
      );
    }
  }

  /// 上传成功后删除对应 oplog 行（幂等）。
  static Future<void> markUploaded(SyncBatch batch, {Database? db}) async {
    final database = await _db(db);
    await database.transaction((txn) async {
      for (final op in batch.ops) {
        final spec = SyncSpecs.byEntity[op.entity];
        if (spec == null) continue;
        await txn.delete(
          spec.oplogTable,
          where: 'seq = ? AND hlc_ms IS NOT NULL',
          whereArgs: [op.seq],
        );
      }
    });
  }

  /// 测试 / 修复用：清空本机 oplog。
  static Future<void> clearAll({Database? db}) async {
    final database = await _db(db);
    await database.transaction((txn) async {
      for (final spec in SyncSpecs.all) {
        await txn.delete(spec.oplogTable);
      }
    });
  }

  static SyncOp _rowToOp(
    SyncTableSpec spec,
    Map<String, Object?> row,
    String deviceId,
  ) {
    final hlc = SyncHlc(
      (row['hlc_ms'] as int?) ?? 0,
      (row['hlc_counter'] as int?) ?? 0,
    );
    final op = (row['op'] as String?) ?? 'upsert';
    final key = <String, dynamic>{
      for (final column in spec.keyColumns.keys) column: row[column],
    };
    if (op == 'delete') {
      return SyncOp(
        deviceId: deviceId,
        seq: (row['seq'] as int?) ?? 0,
        hlc: hlc,
        entity: spec.entity,
        key: key,
        op: op,
        deletedAt: DateTime.fromMillisecondsSinceEpoch(
          hlc.ms,
          isUtc: true,
        ).toIso8601String(),
      );
    }
    return SyncOp(
      deviceId: deviceId,
      seq: (row['seq'] as int?) ?? 0,
      hlc: hlc,
      entity: spec.entity,
      key: key,
      op: op,
      data: {for (final column in spec.dataColumns.keys) column: row[column]},
      delta: {
        for (final counter in spec.counters)
          counter: (row['delta_$counter'] as int?) ?? 0,
      },
    );
  }
}
