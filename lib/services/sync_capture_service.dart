import 'dart:convert';
import 'dart:typed_data';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/cloud_sync_manifest.dart';
import '../models/sync_op.dart';
import 'database_service.dart';
import 'sync_schema.dart';
import 'sync_table_spec.dart';

/// 一批待上传的本地操作。
class SyncBatch {
  final List<SyncOp> ops;

  /// 实际上传的字节（gzip 压缩后的 JSONL）。
  final Uint8List bytes;

  const SyncBatch({required this.ops, required this.bytes});

  /// 对上传字节计算完整 SHA-256，用于对象键与下载校验。
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
    final bulkRows = await database.rawQuery(
      'SELECT COUNT(*) AS c FROM oplog_bulk',
    );
    total += (bulkRows.first['c'] as int?) ?? 0;
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
      final hlcBatch = txn.batch();

      // 批量 op 与普通 oplog 一样在导出时分配 HLC。
      final bulkRows = await txn.query(
        'oplog_bulk',
        columns: ['seq', 'captured_at_ms'],
        where: 'hlc_ms IS NULL',
        orderBy: 'captured_at_ms ASC, seq ASC',
        limit: maxOps,
      );
      for (final row in bulkRows) {
        final captured = _clampCapturedAt(row['captured_at_ms'] as int?, nowMs);
        final baseMs = captured > lastMs ? captured : lastMs;
        final hlc = SyncHlc.next(
          nowMs: baseMs,
          lastMs: lastMs,
          lastCounter: lastCounter,
        );
        lastMs = hlc.ms;
        lastCounter = hlc.counter;
        hlcBatch.update(
          'oplog_bulk',
          {'hlc_ms': hlc.ms, 'hlc_counter': hlc.counter},
          where: 'seq = ?',
          whereArgs: [row['seq']],
        );
        assigned++;
      }

      for (final spec in SyncSpecs.all) {
        if (assigned >= maxOps) break;
        final rows = await txn.query(
          spec.oplogTable,
          columns: ['seq', 'captured_at_ms'],
          where: 'hlc_ms IS NULL',
          orderBy: 'captured_at_ms ASC, seq ASC',
          limit: maxOps - assigned,
        );
        for (final row in rows) {
          if (assigned >= maxOps) break;
          // 以业务写入时的墙钟为基准：即使很晚才导出，也不会凭空获得
          // 比实际编辑时间更晚的 HLC（P2-9）。若本机已有更晚的 HLC，
          // 则用 lastMs 保证单调性。
          final captured = _clampCapturedAt(
            row['captured_at_ms'] as int?,
            nowMs,
          );
          final baseMs = captured > lastMs ? captured : lastMs;
          final hlc = SyncHlc.next(
            nowMs: baseMs,
            lastMs: lastMs,
            lastCounter: lastCounter,
          );
          lastMs = hlc.ms;
          lastCounter = hlc.counter;
          hlcBatch.update(
            spec.oplogTable,
            {'hlc_ms': hlc.ms, 'hlc_counter': hlc.counter},
            where: 'seq = ?',
            whereArgs: [row['seq']],
          );
          assigned++;
        }
      }

      if (assigned > 0) {
        // 一次提交所有 HLC 更新，避免每行一次平台通道往返。
        await hlcBatch.commit(noResult: true);
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
    final bulkRows = await database.query(
      'oplog_bulk',
      where: 'hlc_ms IS NOT NULL',
      orderBy: 'hlc_ms ASC, hlc_counter ASC, seq ASC',
      limit: maxOps,
    );
    for (final row in bulkRows) {
      ops.add(_bulkRowToOp(row, resolvedDeviceId));
    }
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
      bytes: SyncChunkCodec.encodeCompressed(selected),
    );

    // 先记录本地版本：即使上传失败，也能阻止更旧的远端操作覆盖本地数据。
    await database.transaction((txn) async {
      await _rememberVersions(txn, selected);
    });
    return batch;
  }

  /// 墙钟异常保护：设备时间若比当前时间超前超过 5 分钟，按当前时间处理，
  /// 避免一次时钟错误把所有后续 HLC 推到未来。
  static int _clampCapturedAt(int? captured, int nowMs) {
    if (captured == null) return nowMs;
    const maxSkewMs = 5 * 60 * 1000;
    return captured > nowMs + maxSkewMs ? nowMs : captured;
  }

  /// 记录一条批量 op（大批量导入用）。调用前应关闭逐行触发器。
  static Future<void> recordBulk(
    DatabaseExecutor txn,
    List<SyncBulkItem> items,
  ) async {
    if (items.isEmpty) return;
    final payload = jsonEncode(items.map((e) => e.toJson()).toList());
    await txn.insert('oplog_bulk', {
      'op': 'bulk',
      'payload': payload,
      'item_count': items.length,
      'captured_at_ms': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// 批量记住行版本：按实体预载一次，再用 batch 写回。
  static Future<void> _rememberVersions(
    DatabaseExecutor txn,
    List<SyncOp> ops,
  ) async {
    if (ops.isEmpty) return;
    final keysByEntity = <String, Set<String>>{};
    for (final op in ops) {
      keysByEntity
          .putIfAbsent(op.entity, () => <String>{})
          .add(op.keyFingerprint);
    }
    final existing = <String, SyncHlc>{};
    for (final entry in keysByEntity.entries) {
      final keys = entry.value.toList();
      for (var i = 0; i < keys.length; i += 400) {
        final end = (i + 400) > keys.length ? keys.length : i + 400;
        final slice = keys.sublist(i, end);
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
              existing['${entry.key}\u0000$key'] = SyncHlc.parse(hlc);
            } on FormatException {
              // 损坏的行版本按不存在处理，用本次 HLC 覆盖
            }
          }
        }
      }
    }

    final batch = txn.batch();
    final seen = <String, SyncHlc>{};
    for (final op in ops) {
      final key = op.keyFingerprint;
      final mapKey = '${op.entity}\u0000$key';
      final current = existing[mapKey];
      final pending = seen[mapKey];
      final newest = pending != null && pending.compareTo(op.hlc) > 0
          ? pending
          : op.hlc;
      if (current != null && current.compareTo(newest) >= 0) continue;
      if (pending != null && pending.compareTo(newest) >= 0) continue;
      seen[mapKey] = newest;
      batch.insert('sync_row_versions', {
        'entity': op.entity,
        'key': key,
        'hlc': newest.value,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  /// 上传成功后删除对应 oplog 行（幂等）。
  ///
  /// [ownChunkDeviceId] / [ownChunkKey] 非空时，同时把本机刚上传的 chunk
  /// 记入 `sync_chunks`。本机 chunk 的内容已经存在于本地数据库，不需要
  /// 再通过 pull 应用一次；记录后 `_pull` 的 `appliedKeys` 会跳过它。
  /// 这对恢复快照后的 `baseline` 重放尤其重要：否则本机新 chunk 会在
  /// 下一轮同步被自己拉回，计数增量被重复累加。
  static Future<void> markUploaded(
    SyncBatch batch, {
    Database? db,
    String? ownChunkDeviceId,
    String? ownChunkKey,
  }) async {
    final database = await _db(db);
    await database.transaction((txn) async {
      var uploaded = 0;
      for (final op in batch.ops) {
        if (op.isBulk) {
          final removed = await txn.delete(
            'oplog_bulk',
            where: 'seq = ? AND hlc_ms IS NOT NULL',
            whereArgs: [op.seq],
          );
          if (removed > 0) uploaded += op.items.length;
          continue;
        }
        final spec = SyncSpecs.byEntity[op.entity];
        if (spec == null) continue;
        uploaded += await txn.delete(
          spec.oplogTable,
          where: 'seq = ? AND hlc_ms IS NOT NULL',
          whereArgs: [op.seq],
        );
      }
      if (uploaded > 0) {
        await txn.rawUpdate(
          'UPDATE sync_meta SET total_ops = total_ops + ? WHERE id = 1',
          [uploaded],
        );
      }
      if (ownChunkDeviceId != null &&
          ownChunkDeviceId.isNotEmpty &&
          ownChunkKey != null &&
          ownChunkKey.isNotEmpty) {
        final bounds = _hlcBounds(batch.ops);
        await txn.insert('sync_chunks', {
          'device_id': ownChunkDeviceId,
          'chunk_key': ownChunkKey,
          'sha256': batch.sha256,
          'min_hlc': bounds.$1,
          'max_hlc': bounds.$2,
          'applied_at': DateTime.now().toUtc().toIso8601String(),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        // head 必须与「删除 oplog / 记录本机 chunk」在同一事务里推进。
        // 否则进程在上传成功后、写 head 前退出，chunk 已上传但其它设备
        // 会因为 head 未变化而永远不会 LIST 到它。
        if (batch.ops.isNotEmpty) {
          await txn.rawUpdate(
            'UPDATE sync_meta SET head_hlc = ?, head_key = ?, '
            'head_chunk_count = head_chunk_count + 1, head_dirty = 1 '
            'WHERE id = 1',
            [batch.ops.first.hlc.value, ownChunkKey],
          );
        }
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
      await txn.delete('oplog_bulk');
    });
  }

  /// 当前是否开启变更捕获。
  static Future<bool> isCaptureEnabled({Database? db}) async {
    final database = await _db(db);
    final rows = await database.query(
      'sync_meta',
      columns: ['capture_enabled'],
      where: 'id = 1',
      limit: 1,
    );
    return rows.isNotEmpty && (rows.first['capture_enabled'] as int?) == 1;
  }

  /// 批量导入快速路径：为已存在的业务行一次性回填 oplog。
  ///
  /// 调用前应临时关闭 `capture_enabled`，避免每行触发器各写一条 op；
  /// 本方法用单条 `INSERT ... SELECT` 生成与触发器等价的 oplog 行，
  /// 导出与上传逻辑仍然完全复用。
  static Future<int> backfillOps(
    DatabaseExecutor txn,
    SyncTableSpec spec, {
    required String where,
    List<Object?> whereArgs = const [],
  }) async {
    final columns = <String>['"op"', '"captured_at_ms"'];
    final values = <String>["'upsert'", SyncTableSpec.capturedAtSql];
    for (final key in spec.keyColumns.keys) {
      columns.add('"$key"');
      values.add('"$key"');
    }
    for (final data in spec.dataColumns.keys) {
      columns.add('"$data"');
      values.add('"$data"');
    }
    for (final counter in spec.counters) {
      columns.add('"delta_$counter"');
      values.add('COALESCE("$counter", 0)');
    }
    return txn.rawInsert(
      'INSERT INTO "${spec.oplogTable}" (${columns.join(', ')}) '
      'SELECT ${values.join(', ')} FROM "${spec.table}" WHERE $where',
      whereArgs,
    );
  }

  /// 开启 / 关闭本地变更捕获。
  ///
  /// 关闭时同时清空 oplog：未配置云同步时不保留无处可去的变更记录。
  static Future<void> setCaptureEnabled({
    required bool enabled,
    Database? db,
  }) async {
    final database = await _db(db);
    await SyncSchema.setCaptureEnabled(database, enabled);
    if (!enabled) {
      await clearAll(db: database);
    }
  }

  /// chunk 内 op 的 HLC 范围；空批次返回空字符串。
  static (String, String) _hlcBounds(List<SyncOp> ops) {
    if (ops.isEmpty) return ('', '');
    var min = ops.first.hlc;
    var max = ops.first.hlc;
    for (final op in ops) {
      if (op.hlc.compareTo(min) < 0) min = op.hlc;
      if (op.hlc.compareTo(max) > 0) max = op.hlc;
    }
    return (min.value, max.value);
  }

  static SyncOp _bulkRowToOp(Map<String, Object?> row, String deviceId) {
    final decoded = jsonDecode((row['payload'] as String?) ?? '[]');
    final items = <SyncBulkItem>[];
    if (decoded is List) {
      for (final item in decoded) {
        if (item is Map) {
          items.add(SyncBulkItem.fromJson(item.cast<String, dynamic>()));
        }
      }
    }
    return SyncOp(
      version: SyncOp.currentVersion,
      deviceId: deviceId,
      seq: (row['seq'] as int?) ?? 0,
      hlc: SyncHlc(
        (row['hlc_ms'] as int?) ?? 0,
        (row['hlc_counter'] as int?) ?? 0,
      ),
      entity: 'bulk',
      key: const {},
      op: 'bulk',
      items: items,
    );
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
