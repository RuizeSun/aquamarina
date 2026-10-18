import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/sync_op.dart';
import 'sync_table_spec.dart';

/// 快照中携带的“来源设备已应用到哪个 HLC”。
///
/// 新格式备份会把同步水位写入 `backup_meta.json` 后再删除 `sync_*` 表。
/// 恢复时据此重建 `sync_state`，比单一“备份创建时间”更准确地判断
/// 哪些 chunk 已经包含在快照中。
class SyncWatermark {
  final String deviceId;
  final String lastHlc;
  final String lastChunkKey;

  const SyncWatermark({
    required this.deviceId,
    required this.lastHlc,
    required this.lastChunkKey,
  });

  Map<String, dynamic> toJson() => {
    'device_id': deviceId,
    'last_hlc': lastHlc,
    'last_chunk_key': lastChunkKey,
  };

  /// 解析并校验；无效条目返回 null（旧备份兼容）。
  static SyncWatermark? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final deviceId = raw['device_id'];
    final lastHlc = raw['last_hlc'];
    final lastChunkKey = raw['last_chunk_key'];
    if (deviceId is! String ||
        !RegExp(r'^[a-fA-F0-9-]{8,64}$').hasMatch(deviceId) ||
        lastHlc is! String ||
        lastHlc.isEmpty) {
      return null;
    }
    try {
      SyncHlc.parse(lastHlc);
    } on FormatException {
      return null;
    }
    return SyncWatermark(
      deviceId: deviceId,
      lastHlc: lastHlc,
      lastChunkKey: lastChunkKey is String ? lastChunkKey : '',
    );
  }
}

/// 同步系统表与触发器安装入口。
///
/// 该 schema 与业务 schema 同库，但只保存同步元数据：
/// - `sync_meta`：本机设备 ID、远端应用抑制标记、HLC 状态；
/// - `sync_applied`：已应用的远端 (device_id, seq)，用于恰好一次；
/// - `sync_state`：各设备已应用到的最新 seq；
/// - `sync_tombstones`：删除墓碑，防止旧数据“复活”。
class SyncSchema {
  SyncSchema._();

  static const List<String> systemTableDdl = [
    '''
    CREATE TABLE IF NOT EXISTS "sync_meta" (
      "id" INTEGER PRIMARY KEY CHECK ("id" = 1),
      "device_id" TEXT NOT NULL DEFAULT '',
      "applying" INTEGER NOT NULL DEFAULT 0,
      "hlc_ms" INTEGER NOT NULL DEFAULT 0,
      "hlc_counter" INTEGER NOT NULL DEFAULT 0,
      "baseline_hlc" TEXT NOT NULL DEFAULT '',
      "capture_enabled" INTEGER NOT NULL DEFAULT 0,
      "head_hlc" TEXT NOT NULL DEFAULT '',
      "head_key" TEXT NOT NULL DEFAULT '',
      "head_chunk_count" INTEGER NOT NULL DEFAULT 0,
      "head_dirty" INTEGER NOT NULL DEFAULT 0,
      "total_ops" INTEGER NOT NULL DEFAULT 0,
      "backend_id" TEXT NOT NULL DEFAULT '',
      "restored_watermarks" INTEGER NOT NULL DEFAULT 0
    )
    ''',
    '''
    CREATE TABLE IF NOT EXISTS "sync_applied" (
      "device_id" TEXT NOT NULL,
      "entity" TEXT NOT NULL,
      "seq" INTEGER NOT NULL,
      "hlc" TEXT,
      "applied_at" TEXT NOT NULL,
      PRIMARY KEY ("device_id", "entity", "seq")
    )
    ''',
    '''
    CREATE TABLE IF NOT EXISTS "sync_state" (
      "device_id" TEXT PRIMARY KEY,
      "last_seq" INTEGER NOT NULL DEFAULT 0,
      "last_hlc" TEXT,
      "last_chunk_key" TEXT,
      "updated_at" TEXT NOT NULL
    )
    ''',
    '''
    CREATE TABLE IF NOT EXISTS "sync_backend_watermarks" (
      "backend_id" TEXT NOT NULL,
      "device_id" TEXT NOT NULL,
      "last_hlc" TEXT NOT NULL,
      "last_chunk_key" TEXT,
      "saved_at" TEXT NOT NULL,
      PRIMARY KEY ("backend_id", "device_id")
    )
    ''',
    '''
    CREATE TABLE IF NOT EXISTS "sync_row_versions" (
      "entity" TEXT NOT NULL,
      "key" TEXT NOT NULL,
      "hlc" TEXT NOT NULL,
      PRIMARY KEY ("entity", "key")
    )
    ''',
    '''
    CREATE TABLE IF NOT EXISTS "sync_chunks" (
      "device_id" TEXT NOT NULL,
      "chunk_key" TEXT NOT NULL,
      "sha256" TEXT NOT NULL,
      "min_hlc" TEXT,
      "max_hlc" TEXT,
      "applied_at" TEXT NOT NULL,
      PRIMARY KEY ("device_id", "chunk_key")
    )
    ''',
    '''
    CREATE TABLE IF NOT EXISTS "oplog_bulk" (
      "seq" INTEGER PRIMARY KEY AUTOINCREMENT,
      "op" TEXT NOT NULL,
      "payload" TEXT NOT NULL,
      "item_count" INTEGER NOT NULL,
      "hlc_ms" INTEGER,
      "hlc_counter" INTEGER,
      "captured_at_ms" INTEGER
    )
    ''',
    '''
    CREATE TABLE IF NOT EXISTS "sync_conflicts" (
      "id" INTEGER PRIMARY KEY AUTOINCREMENT,
      "entity" TEXT NOT NULL,
      "key" TEXT NOT NULL,
      "local_json" TEXT,
      "remote_json" TEXT,
      "local_time" TEXT,
      "remote_time" TEXT,
      "created_at" TEXT NOT NULL,
      "resolved" INTEGER NOT NULL DEFAULT 0,
      "resolution" TEXT
    )
    ''',
    '''
    CREATE TABLE IF NOT EXISTS "sync_tombstones" (
      "entity" TEXT NOT NULL,
      "key" TEXT NOT NULL,
      "deleted_hlc" TEXT NOT NULL,
      "deleted_at" TEXT NOT NULL,
      PRIMARY KEY ("entity", "key")
    )
    ''',
  ];

  static const String seedMetaSql =
      'INSERT OR IGNORE INTO "sync_meta" ("id") VALUES (1)';

  /// 开启 / 关闭变更捕获。
  ///
  /// 未配置云同步时默认关闭，避免 oplog 无限增长；
  /// 首次执行同步时由引擎开启（此前历史数据建议用完整快照引导）。
  static Future<void> setCaptureEnabled(Database db, bool enabled) async {
    await db.update('sync_meta', {
      'capture_enabled': enabled ? 1 : 0,
    }, where: 'id = 1');
  }

  /// 幂等安装：系统表 → oplog 表 → 索引 → 触发器。
  ///
  /// 必须在业务表（含 v13 新增列）就绪后调用。
  static Future<void> ensure(Database db) async {
    for (final sql in systemTableDdl) {
      await db.execute(sql);
    }
    await db.execute(seedMetaSql);

    for (final spec in SyncSpecs.all) {
      await db.execute(spec.oplogDdl);
      await db.execute(spec.pendingIndexDdl);
      // v16：为已存在的 oplog 表补捕获时间列（CREATE TABLE IF NOT EXISTS 不补列）。
      await _ensureColumn(db, spec.oplogTable, 'captured_at_ms', 'INTEGER');
      for (final trigger in spec.triggerDdls) {
        await db.execute(trigger);
      }
    }

    // v15：为已存在的数据库补列（CREATE TABLE IF NOT EXISTS 不会新增列）。
    await _ensureColumn(
      db,
      'sync_meta',
      'head_hlc',
      "TEXT NOT NULL DEFAULT ''",
    );
    await _ensureColumn(
      db,
      'sync_meta',
      'head_key',
      "TEXT NOT NULL DEFAULT ''",
    );
    await _ensureColumn(
      db,
      'sync_meta',
      'head_chunk_count',
      'INTEGER NOT NULL DEFAULT 0',
    );
    await _ensureColumn(
      db,
      'sync_meta',
      'head_dirty',
      'INTEGER NOT NULL DEFAULT 0',
    );
    await _ensureColumn(
      db,
      'sync_meta',
      'total_ops',
      'INTEGER NOT NULL DEFAULT 0',
    );
    await _ensureColumn(
      db,
      'sync_meta',
      'backend_id',
      "TEXT NOT NULL DEFAULT ''",
    );
    await _ensureColumn(
      db,
      'sync_meta',
      'restored_watermarks',
      'INTEGER NOT NULL DEFAULT 0',
    );
    await _ensureColumn(db, 'sync_applied', 'hlc', 'TEXT');
    await _ensureColumn(db, 'sync_state', 'last_chunk_key', 'TEXT');
    await _ensureColumn(db, 'sync_chunks', 'min_hlc', 'TEXT');
    await _ensureColumn(db, 'sync_chunks', 'max_hlc', 'TEXT');

    for (final sql in systemIndexDdl) {
      await db.execute(sql);
    }
  }

  /// 每条备份 / 恢复水位对应一个来源设备。
  static const List<String> systemIndexDdl = [
    'CREATE INDEX IF NOT EXISTS idx_sync_applied_device_hlc '
        'ON sync_applied(device_id, hlc)',
    'CREATE INDEX IF NOT EXISTS idx_sync_chunks_device_hlc '
        'ON sync_chunks(device_id, min_hlc)',
    'CREATE INDEX IF NOT EXISTS idx_sync_tombstones_hlc '
        'ON sync_tombstones(deleted_hlc)',
    'CREATE INDEX IF NOT EXISTS idx_sync_row_versions_hlc '
        'ON sync_row_versions(hlc)',
    'CREATE INDEX IF NOT EXISTS idx_sync_conflicts_resolved '
        'ON sync_conflicts(resolved, created_at)',
    'CREATE INDEX IF NOT EXISTS idx_oplog_bulk_pending '
        'ON oplog_bulk(hlc_ms)',
  ];

  /// SQLite 没有 `ADD COLUMN IF NOT EXISTS`，先查 `PRAGMA table_info`。
  static Future<void> _ensureColumn(
    Database db,
    String table,
    String column,
    String definition,
  ) async {
    final rows = await db.rawQuery('PRAGMA table_info("$table")');
    for (final row in rows) {
      if (row['name'] == column) return;
    }
    await db.execute('ALTER TABLE "$table" ADD COLUMN "$column" $definition');
  }

  /// v16：重建触发器，使新数据在写入时记录 `captured_at_ms`。
  ///
  /// SQLite 的 `CREATE TRIGGER IF NOT EXISTS` 不会更新已存在的触发器，
  /// 必须显式 DROP 后再按最新规格创建。
  static Future<void> reinstallTriggers(Database db) async {
    for (final spec in SyncSpecs.all) {
      for (final sql in spec.dropTriggerDdls) {
        await db.execute(sql);
      }
    }
    await ensure(db);
  }

  /// 清理本机 oplog 中已上传的记录（按实体）。
  static Future<int> clearUploaded(Database db, String entity) async {
    final spec = SyncSpecs.byEntity[entity];
    if (spec == null) return 0;
    return db.delete(spec.oplogTable, where: 'hlc_ms IS NOT NULL');
  }

  /// 删除某台设备在本机的同步记录（云端设备删除 / 接管后调用）。
  ///
  /// 只清理与该设备相关的行，不影响本机 oplog、业务数据或其它设备水位。
  static Future<void> deleteDeviceRecords(Database db, String deviceId) async {
    await db.transaction((txn) async {
      await txn.delete(
        'sync_state',
        where: 'device_id = ?',
        whereArgs: [deviceId],
      );
      await txn.delete(
        'sync_applied',
        where: 'device_id = ?',
        whereArgs: [deviceId],
      );
      await txn.delete(
        'sync_chunks',
        where: 'device_id = ?',
        whereArgs: [deviceId],
      );
      await txn.delete(
        'sync_backend_watermarks',
        where: 'device_id = ?',
        whereArgs: [deviceId],
      );
    });
  }

  /// 合并快照后采纳来源水位。
  ///
  /// 与 [resetRuntimeState] 不同：不清空本机 oplog、`sync_applied`、`sync_chunks`
  /// 或其它设备的水位，只把快照已经包含的来源进度合并进来。
  static Future<void> adoptSnapshotWatermarks(
    Database db, {
    required List<SyncWatermark> watermarks,
    DateTime? baseline,
    String? backendId,
  }) async {
    var baselineTime = baseline;
    for (final watermark in watermarks) {
      try {
        final hlc = SyncHlc.parse(watermark.lastHlc);
        final at = DateTime.fromMillisecondsSinceEpoch(hlc.ms, isUtc: true);
        if (baselineTime == null || at.isAfter(baselineTime)) {
          baselineTime = at;
        }
      } catch (_) {
        // 忽略损坏水位
      }
    }
    final baselineHlc = baselineTime == null
        ? ''
        : SyncHlc(baselineTime.toUtc().millisecondsSinceEpoch, 0).value;
    await db.transaction((txn) async {
      final now = DateTime.now().toUtc().toIso8601String();
      for (final watermark in watermarks) {
        final rows = await txn.query(
          'sync_state',
          columns: ['last_hlc'],
          where: 'device_id = ?',
          whereArgs: [watermark.deviceId],
          limit: 1,
        );
        final existing = rows.isEmpty
            ? ''
            : (rows.first['last_hlc'] as String? ?? '');
        if (existing.isNotEmpty &&
            _compareHlc(existing, watermark.lastHlc) >= 0) {
          continue;
        }
        await txn.insert('sync_state', {
          'device_id': watermark.deviceId,
          'last_seq': 0,
          'last_hlc': watermark.lastHlc,
          'last_chunk_key': watermark.lastChunkKey.isEmpty
              ? null
              : watermark.lastChunkKey,
          'updated_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await txn.update('sync_meta', {
        'baseline_hlc': baselineHlc,
        'restored_watermarks': 1,
        if (backendId != null && backendId.isNotEmpty) 'backend_id': backendId,
      }, where: 'id = 1');
    });
  }

  /// “以本机为准”时建立新的同步起点：忽略当前所有云端历史，只接收之后
  /// 新产生的 chunk。保留本机 oplog / head，确保本机历史仍能上传。
  static Future<void> resetForNewBaseline(
    Database db, {
    required DateTime cutoff,
    String? backendId,
  }) async {
    final baselineHlc = SyncHlc(cutoff.toUtc().millisecondsSinceEpoch, 0).value;
    await db.transaction((txn) async {
      await txn.delete('sync_state');
      await txn.update('sync_meta', {
        'baseline_hlc': baselineHlc,
        'restored_watermarks': 1,
        if (backendId != null && backendId.isNotEmpty) 'backend_id': backendId,
      }, where: 'id = 1');
    });
  }

  static int _compareHlc(String a, String b) {
    try {
      return SyncHlc.parse(a).compareTo(SyncHlc.parse(b));
    } catch (_) {
      return 1;
    }
  }

  /// 备份恢复后重置同步运行时状态。
  ///
  /// 快照来自另一台设备：
  /// - 其 oplog 是本机的待上传变更，必须清空，避免被当作本机操作重复上传；
  /// - 其 `sync_applied` / `sync_chunks` / 行版本 / 墓碑代表快照已经包含的历史，
  ///   必须保留，否则会重复应用历史增量（计数类会翻倍）；
  /// - [watermarks] 非空时按“来源设备水位”重建 `sync_state`，并忽略
  ///   [baseline] 的粗粒度过滤；为空时退回旧行为（按备份创建时间基线）。
  static Future<void> resetRuntimeState(
    Database db, {
    DateTime? baseline,
    List<SyncWatermark>? watermarks,
    String? backendId,
  }) async {
    final baselineHlc = baseline == null
        ? ''
        : SyncHlc(baseline.toUtc().millisecondsSinceEpoch, 0).value;
    await db.transaction((txn) async {
      for (final spec in SyncSpecs.all) {
        await txn.delete(spec.oplogTable);
      }
      await txn.delete('oplog_bulk');
      // 快照可能携带旧冲突记录；恢复后应以当前数据为准。
      await txn.delete('sync_conflicts');
      if (watermarks != null) {
        await txn.delete('sync_state');
        await txn.delete('sync_chunks');
        await txn.delete('sync_applied');
        final now = DateTime.now().toUtc().toIso8601String();
        for (final watermark in watermarks) {
          await txn.insert('sync_state', {
            'device_id': watermark.deviceId,
            'last_seq': 0,
            'last_hlc': watermark.lastHlc,
            'last_chunk_key': watermark.lastChunkKey.isEmpty
                ? null
                : watermark.lastChunkKey,
            'updated_at': now,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
      await txn.update('sync_meta', {
        'device_id': '',
        'applying': 0,
        'hlc_ms': 0,
        'hlc_counter': 0,
        'baseline_hlc': baselineHlc,
        'head_hlc': '',
        'head_key': '',
        'head_chunk_count': 0,
        'head_dirty': 0,
        'total_ops': 0,
        'restored_watermarks': watermarks == null ? 0 : 1,
        'backend_id': ?backendId,
      }, where: 'id = 1');
    });
  }
}
