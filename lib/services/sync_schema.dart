import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/sync_op.dart';
import 'sync_table_spec.dart';

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
      "capture_enabled" INTEGER NOT NULL DEFAULT 0
    )
    ''',
    '''
    CREATE TABLE IF NOT EXISTS "sync_applied" (
      "device_id" TEXT NOT NULL,
      "entity" TEXT NOT NULL,
      "seq" INTEGER NOT NULL,
      "applied_at" TEXT NOT NULL,
      PRIMARY KEY ("device_id", "entity", "seq")
    )
    ''',
    '''
    CREATE TABLE IF NOT EXISTS "sync_state" (
      "device_id" TEXT PRIMARY KEY,
      "last_seq" INTEGER NOT NULL DEFAULT 0,
      "last_hlc" TEXT,
      "updated_at" TEXT NOT NULL
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
      "applied_at" TEXT NOT NULL,
      PRIMARY KEY ("device_id", "chunk_key")
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
      for (final trigger in spec.triggerDdls) {
        await db.execute(trigger);
      }
    }
  }

  /// 清理本机 oplog 中已上传的记录（按实体）。
  static Future<int> clearUploaded(Database db, String entity) async {
    final spec = SyncSpecs.byEntity[entity];
    if (spec == null) return 0;
    return db.delete(spec.oplogTable, where: 'hlc_ms IS NOT NULL');
  }

  /// 备份恢复后重置同步运行时状态。
  ///
  /// 快照来自另一台设备：
  /// - 其 oplog 是本机的待上传变更，必须清空，避免被当作本机操作重复上传；
  /// - 其 `sync_applied` / `sync_chunks` / 行版本 / 墓碑代表快照已经包含的历史，
  ///   必须保留，否则会重复应用历史增量（计数类会翻倍）；
  /// - 以 [baseline]（备份创建时间）为基线，拉取时跳过基线之前的 chunk。
  static Future<void> resetRuntimeState(
    Database db, {
    DateTime? baseline,
  }) async {
    final baselineHlc = baseline == null
        ? ''
        : SyncHlc(baseline.toUtc().millisecondsSinceEpoch, 0).value;
    await db.transaction((txn) async {
      for (final spec in SyncSpecs.all) {
        await txn.delete(spec.oplogTable);
      }
      await txn.update('sync_meta', {
        'device_id': '',
        'applying': 0,
        'hlc_ms': 0,
        'hlc_counter': 0,
        'baseline_hlc': baselineHlc,
      }, where: 'id = 1');
    });
  }
}
