import 'package:aquamarina/services/cloud/sync_table_spec.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sync_test_support.dart';

/// 待上传/待拉取查询所用索引必须真正被 SQLite 采用。
///
/// 捕获按 `hlc_ms IS NULL ORDER BY captured_at_ms, seq` 扫描；之前只有
/// 单列 `hlc_ms` 索引，对该谓词完全无效（NULL 在索引里是特殊值，且
/// 排序键不匹配），oplog 增长后每轮同步都会退化为全表扫描。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('oplog 存在待上传与已上传的分区索引', () async {
    final db = await openSyncTestDb();
    addTearDown(db.close);

    final spec = SyncSpecs.byEntity['wrong_words']!;
    final indexes = await db.rawQuery(
      'PRAGMA index_list("${spec.oplogTable}")',
    );
    final names = indexes.map((r) => r['name'].toString()).toSet();

    expect(
      names,
      contains('${spec.pendingIndex}_pending'),
      reason: '缺少待上传分区索引',
    );
    expect(
      names,
      contains('${spec.pendingIndex}_uploaded'),
      reason: '缺少已上传分区索引',
    );
    expect(
      names,
      isNot(contains(spec.pendingIndex)),
      reason: '旧的单列 hlc_ms 索引应被移除',
    );
  });

  test('待上传查询确实命中分区索引', () async {
    final db = await openSyncTestDb();
    addTearDown(db.close);

    final spec = SyncSpecs.byEntity['wrong_words']!;
    final plan = await db.rawQuery(
      'EXPLAIN QUERY PLAN SELECT seq FROM "${spec.oplogTable}" '
      'WHERE hlc_ms IS NULL ORDER BY captured_at_ms ASC, seq ASC LIMIT 10',
    );
    final detail = plan.map((r) => r['detail'].toString()).join(' | ');
    expect(
      detail,
      contains('${spec.pendingIndex}_pending'),
      reason: '查询计划未使用待上传分区索引：$detail',
    );
  });
}
