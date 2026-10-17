import 'package:aquamarina/models/sync_op.dart';
import 'package:aquamarina/services/sync_apply_service.dart';
import 'package:aquamarina/services/sync_capture_service.dart';
import 'package:aquamarina/services/sync_schema.dart';
import 'package:aquamarina/services/sync_table_spec.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'sync_test_support.dart';

void main() {
  late Database db;

  setUp(() async {
    db = await openSyncTestDb();
  });

  tearDown(() async {
    await db.close();
  });

  group('SyncCaptureService', () {
    test('按批次导出、HLC 单调、上传成功后清理且不重复', () async {
      await db.insert('user_word_records', {
        'word': 'apple',
        'stage': 1,
        'review_count': 2,
        'created_at': '2026-10-01T00:00:00Z',
      });
      await db.insert('user_word_records', {
        'word': 'banana',
        'stage': 0,
        'review_count': 0,
        'created_at': '2026-10-01T00:00:00Z',
      });
      await db.insert('daily_activity', {
        'date': '2026-10-01',
        'words_learned': 5,
      });

      expect(await SyncCaptureService.pendingCount(db: db), 3);

      final first = await SyncCaptureService.takePendingBatch(
        db: db,
        deviceId: 'device-a',
        maxOps: 2,
      );
      expect(first, isNotNull);
      expect(first!.ops.length, 2);
      expect(first.ops.every((op) => op.deviceId == 'device-a'), isTrue);
      expect(
        first.ops.map((op) => op.entity),
        everyElement('user_word_records'),
      );
      expect(first.ops.map((op) => op.hlc.ms), everyElement(greaterThan(0)));

      final decoded = SyncChunkCodec.decodeAuto(first.bytes);
      expect(decoded.length, 2);
      expect(decoded.first.key['word'], first.ops.first.key['word']);
      expect(decoded.first.delta['review_count'], 2);
      // gzip + 完整 SHA-256（P1-4）
      expect(SyncChunkCodec.isGzip(first.bytes), isTrue);
      expect(first.sha256.length, 64);

      await SyncCaptureService.markUploaded(first, db: db);
      expect(await SyncCaptureService.pendingCount(db: db), 1);

      final second = await SyncCaptureService.takePendingBatch(
        db: db,
        deviceId: 'device-a',
        maxOps: 10,
      );
      expect(second, isNotNull);
      expect(second!.ops.length, 1);
      expect(second.ops.single.entity, 'daily_activity');
      expect(
        second.ops.single.hlc.compareTo(first.ops.last.hlc),
        greaterThan(0),
      );

      await SyncCaptureService.markUploaded(second, db: db);
      expect(await SyncCaptureService.pendingCount(db: db), 0);
      expect(
        await SyncCaptureService.takePendingBatch(db: db, deviceId: 'device-a'),
        isNull,
      );
    });

    test('HLC 以写入时的 captured_at_ms 为基准，晚导出不会变晚', () async {
      await db.insert('word_notes', {
        'word': 'apple',
        'note': 'local',
        'is_favorited': 0,
        'updated_at': '2026-10-02T00:00:00Z',
      });
      // 模拟业务写入发生在很久以前，今天才导出
      await db.update('oplog_word_notes', {
        'captured_at_ms': 1000,
      }, where: 'hlc_ms IS NULL');
      await db.update('sync_meta', {
        'hlc_ms': 0,
        'hlc_counter': 0,
      }, where: 'id = 1');

      final batch = await SyncCaptureService.takePendingBatch(
        db: db,
        deviceId: 'device-a',
      );
      expect(batch, isNotNull);
      expect(batch!.ops.single.hlc.ms, 1000);
    });

    test('未来墙钟超过 5 分钟时按当前时间生成 HLC', () async {
      await db.insert('word_notes', {
        'word': 'apple',
        'note': 'local',
        'is_favorited': 0,
        'updated_at': '2026-10-02T00:00:00Z',
      });
      final future = DateTime.now()
          .add(const Duration(days: 1))
          .millisecondsSinceEpoch;
      await db.update('oplog_word_notes', {
        'captured_at_ms': future,
      }, where: 'hlc_ms IS NULL');
      await db.update('sync_meta', {
        'hlc_ms': 0,
        'hlc_counter': 0,
      }, where: 'id = 1');
      final before = DateTime.now().millisecondsSinceEpoch;
      final batch = await SyncCaptureService.takePendingBatch(
        db: db,
        deviceId: 'device-a',
      );
      expect(batch, isNotNull);
      expect(
        batch!.ops.single.hlc.ms,
        lessThanOrEqualTo(before + 5 * 60 * 1000),
      );
    });

    test('批量回填 oplog 使用单条 INSERT SELECT', () async {
      await db.insert('word_books', {
        'uuid': 'book-1',
        'title': 'Book',
        'word_count': 0,
      });
      final book = await db.query('word_books', limit: 1);
      final bookId = book.first['id'];
      for (var i = 0; i < 20; i++) {
        await db.insert('word_book_entries', {
          'book_id': bookId,
          'book_uuid': 'book-1',
          'word': 'word$i',
          'added_at': '2026-10-01T00:00:00Z',
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      // 触发器会先写 20 条；清空后验证回填 SQL。
      await db.delete('oplog_word_book_entries');
      await SyncSchema.setCaptureEnabled(db, false);
      final inserted = await SyncCaptureService.backfillOps(
        db,
        SyncSpecs.byEntity['word_book_entries']!,
        where: 'book_id = ?',
        whereArgs: [bookId],
      );
      expect(inserted, greaterThan(0));
      await SyncSchema.setCaptureEnabled(db, true);
      // 1 条 word_books op + 回填的 20 条 word_book_entries
      expect(await SyncCaptureService.pendingCount(db: db), 21);
    });

    test('批量 op 导出、应用并幂等重试', () async {
      await SyncCaptureService.recordBulk(db, const [
        SyncBulkItem(
          entity: 'word_book_entries',
          key: {'book_uuid': 'book-bulk', 'word': 'apple'},
          data: {'added_at': '2026-10-01T00:00:00Z'},
        ),
        SyncBulkItem(
          entity: 'word_book_entries',
          key: {'book_uuid': 'book-bulk', 'word': 'banana'},
          data: {'added_at': '2026-10-01T00:00:00Z'},
        ),
      ]);

      final batch = await SyncCaptureService.takePendingBatch(
        db: db,
        deviceId: 'device-a',
      );
      expect(batch, isNotNull);
      expect(batch!.ops.single.isBulk, isTrue);
      expect(batch.ops.single.items.length, 2);

      final decoded = SyncChunkCodec.decodeAuto(batch.bytes);
      expect(decoded.single.isBulk, isTrue);
      expect(decoded.single.items.length, 2);

      final target = await openSyncTestDb();
      try {
        await target.insert('word_books', {
          'uuid': 'book-bulk',
          'title': 'Bulk Book',
          'word_count': 0,
        });
        var applied = await SyncApplyService.applyOps(decoded, db: target);
        expect(applied.applied, 2);
        expect((await target.query('word_book_entries')).length, 2);

        applied = await SyncApplyService.applyOps(decoded, db: target);
        expect(applied.duplicates, 1);
        expect((await target.query('word_book_entries')).length, 2);
      } finally {
        await target.close();
      }
    });

    test('导出后立即写入本地版本，旧远端 op 无法覆盖', () async {
      await db.insert('word_notes', {
        'word': 'apple',
        'note': 'local',
        'is_favorited': 0,
        'updated_at': '2026-10-02T00:00:00Z',
      });

      final batch = await SyncCaptureService.takePendingBatch(
        db: db,
        deviceId: 'device-a',
      );
      expect(batch, isNotNull);

      final rows = await db.query('sync_row_versions');
      expect(rows.length, 1);
      expect(rows.first['entity'], 'word_notes');
      expect(rows.first['key'], contains('apple'));
    });

    test('备份恢复重置：清空 oplog、保留历史版本并写入基线', () async {
      await db.insert('word_notes', {
        'word': 'apple',
        'note': 'local',
        'is_favorited': 0,
        'updated_at': '2026-10-02T00:00:00Z',
      });
      expect(
        await SyncCaptureService.takePendingBatch(db: db, deviceId: 'device-a'),
        isNotNull,
      );
      await db.insert('sync_applied', {
        'device_id': 'device-a',
        'entity': 'word_notes',
        'seq': 1,
        'applied_at': '2026-10-02T00:00:00Z',
      });

      await SyncSchema.resetRuntimeState(
        db,
        baseline: DateTime.utc(2026, 10, 2),
      );

      expect(await SyncCaptureService.pendingCount(db: db), 0);
      expect((await db.query('sync_applied')).length, 1);
      expect((await db.query('sync_row_versions')).length, 1);
      final meta = (await db.query('sync_meta')).single;
      expect(meta['device_id'], '');
      expect(meta['baseline_hlc'], isNotEmpty);
    });
  });

  group('SyncApplyService', () {
    test('幂等、版本门禁、计数增量与墓碑/复活', () async {
      final op = makeOp(
        entity: 'user_word_records',
        seq: 1,
        hlcMs: 1000,
        key: {'word': 'apple'},
        data: {
          'stage': 1,
          'last_reviewed_at': '2026-10-01T00:00:00Z',
          'created_at': '2026-10-01T00:00:00Z',
        },
        delta: {'review_count': 2},
      );
      var result = await SyncApplyService.applyOps([op], db: db);
      expect(result.applied, 1);
      var rows = await db.query('user_word_records');
      expect(rows.single['review_count'], 2);
      expect(rows.single['stage'], 1);

      // 重复应用同一 (device, entity, seq)
      result = await SyncApplyService.applyOps([op], db: db);
      expect(result.duplicates, 1);
      rows = await db.query('user_word_records');
      expect(rows.single['review_count'], 2);

      // 较新的计数增量累加
      result = await SyncApplyService.applyOps([
        makeOp(
          entity: 'user_word_records',
          seq: 2,
          hlcMs: 2000,
          key: {'word': 'apple'},
          data: {'stage': 2, 'last_reviewed_at': '2026-10-02T00:00:00Z'},
          delta: {'review_count': 3},
        ),
      ], db: db);
      expect(result.applied, 1);
      rows = await db.query('user_word_records');
      expect(rows.single['review_count'], 5);
      expect(rows.single['stage'], 2);

      // 迟到的更旧 op：整条跳过，不重复计数
      result = await SyncApplyService.applyOps([
        makeOp(
          entity: 'user_word_records',
          seq: 3,
          hlcMs: 1500,
          key: {'word': 'apple'},
          data: {'stage': 9},
          delta: {'review_count': 1},
        ),
      ], db: db);
      expect(result.skippedByVersion, 1);
      rows = await db.query('user_word_records');
      // 计数增量代表真实复习事件，即使整行较旧也要累加
      expect(rows.single['review_count'], 6);
      expect(rows.single['stage'], 2);

      // 删除 + 墓碑：更旧 upsert 不能复活，更新 upsert 可以
      result = await SyncApplyService.applyOps([
        makeOp(
          entity: 'user_word_records',
          seq: 4,
          hlcMs: 3000,
          key: {'word': 'apple'},
          op: 'delete',
        ),
      ], db: db);
      expect(result.applied, 1);
      expect(await db.query('user_word_records'), isEmpty);
      expect(await db.query('sync_tombstones'), isNotEmpty);

      result = await SyncApplyService.applyOps([
        makeOp(
          entity: 'user_word_records',
          seq: 5,
          hlcMs: 2500,
          key: {'word': 'apple'},
          data: {'stage': 1},
        ),
      ], db: db);
      expect(result.skippedByVersion, 1);
      expect(await db.query('user_word_records'), isEmpty);

      result = await SyncApplyService.applyOps([
        makeOp(
          entity: 'user_word_records',
          seq: 6,
          hlcMs: 4000,
          key: {'word': 'apple'},
          data: {'stage': 1},
          delta: {'review_count': 1},
        ),
      ], db: db);
      expect(result.applied, 1);
      rows = await db.query('user_word_records');
      expect(rows.single['review_count'], 1);
    });

    test('自然时间戳较旧的远端字段不覆盖本地笔记', () async {
      await db.insert('word_notes', {
        'word': 'apple',
        'note': 'local newer',
        'is_favorited': 1,
        'updated_at': '2026-10-02T00:00:00Z',
      });

      final result = await SyncApplyService.applyOps([
        makeOp(
          entity: 'word_notes',
          seq: 1,
          hlcMs: 2000,
          key: {'word': 'apple'},
          data: {
            'note': 'remote older',
            'is_favorited': 0,
            'updated_at': '2026-10-01T00:00:00Z',
          },
        ),
      ], db: db);

      expect(result.applied, 1);
      expect(result.conflicts, 1);
      expect(result.conflictItems, hasLength(1));
      expect(result.conflictItems.single.entity, 'word_notes');
      final row = (await db.query('word_notes')).single;
      expect(row['note'], 'local newer');
      expect(row['is_favorited'], 1);

      final conflicts = await db.query('sync_conflicts');
      expect(conflicts, hasLength(1));
      expect(conflicts.single['resolved'], 0);
      expect('${conflicts.single['remote_json']}', contains('remote older'));
    });

    test('词书条目依赖父级：同批次重试后解析 book_id', () async {
      final result = await SyncApplyService.applyOps([
        makeOp(
          entity: 'word_book_entries',
          seq: 1,
          hlcMs: 900,
          key: {'book_uuid': 'book-uuid-1', 'word': 'apple'},
          data: {'added_at': '2026-10-01T00:00:00Z'},
        ),
        makeOp(
          entity: 'word_books',
          seq: 1,
          hlcMs: 1000,
          key: {'uuid': 'book-uuid-1'},
          data: {
            'title': 'Book',
            'word_count': 1,
            'created_at': '2026-10-01T00:00:00Z',
            'updated_at': '2026-10-01T00:00:00Z',
          },
        ),
      ], db: db);

      expect(result.skippedMissingParent, 0);
      final books = await db.query('word_books');
      final entries = await db.query('word_book_entries');
      expect(books.length, 1);
      expect(entries.length, 1);
      expect(entries.single['book_id'], books.single['id']);
      expect(entries.single['book_uuid'], 'book-uuid-1');
    });

    test('句式集删除会级联清理句子、练习进度与错题', () async {
      await db.insert('sentence_sets', {
        'id': 'set-1',
        'name': 'Set',
        'sentence_count': 1,
        'created_at': '2026-10-01T00:00:00Z',
        'updated_at': '2026-10-01T00:00:00Z',
      });
      await db.insert('sentences', {
        'id': 'sentence-1',
        'set_id': 'set-1',
        'english': 'Hello.',
        'chinese': '你好。',
        'sort_index': 1.0,
      });
      await db.insert('attempted_sentence_ids', {
        'set_id': 'set-1',
        'sentence_id': 'sentence-1',
      });
      await db.insert('practiced_sentence_ids', {
        'set_id': 'set-1',
        'sentence_id': 'sentence-1',
      });
      await db.insert('wrong_sentences', {
        'id': 'wrong-1',
        'sentence_id': 'sentence-1',
        'set_id': 'set-1',
        'english': 'Hello.',
        'chinese': '你好。',
        'score': 1,
        'user_answer': 'x',
        'created_at': '2026-10-01T00:00:00Z',
        'wrong_count': 1,
      });

      final result = await SyncApplyService.applyOps([
        makeOp(
          entity: 'sentence_sets',
          seq: 1,
          hlcMs: 3000,
          key: {'id': 'set-1'},
          op: 'delete',
        ),
      ], db: db);
      expect(result.applied, 1);
      expect(await db.query('sentence_sets'), isEmpty);
      expect(await db.query('sentences'), isEmpty);
      expect(await db.query('attempted_sentence_ids'), isEmpty);
      expect(await db.query('practiced_sentence_ids'), isEmpty);
      expect(await db.query('wrong_sentences'), isEmpty);
    });

    test('时间预算按小批提交，下一次从已应用位置继续', () async {
      final ops = [
        for (var i = 0; i < 120; i++)
          makeOp(
            entity: 'word_notes',
            seq: i + 1,
            hlcMs: 10000 + i,
            key: {'word': 'word$i'},
            data: {
              'note': 'n$i',
              'is_favorited': 0,
              'updated_at': '2026-10-02T00:00:00Z',
            },
          ),
      ];

      final first = await SyncApplyService.applyOps(
        ops,
        db: db,
        deadline: DateTime.now().subtract(const Duration(seconds: 1)),
        sliceSize: 50,
      );
      expect(first.deferred, isTrue);
      expect(first.applied, 50);
      expect((await db.query('word_notes')).length, 50);

      final resumed = await SyncApplyService.applyOps(ops, db: db);
      expect(resumed.deferred, isFalse);
      expect(resumed.duplicates, 50);
      expect(resumed.applied, 70);
      expect((await db.query('word_notes')).length, 120);
    });

    test('每日统计的计数增量可累加', () async {
      await SyncApplyService.applyOps([
        makeOp(
          entity: 'daily_activity',
          seq: 1,
          hlcMs: 1000,
          key: {'date': '2026-10-01'},
          delta: {'words_learned': 2, 'correct_count': 1},
        ),
        makeOp(
          entity: 'daily_activity',
          seq: 2,
          hlcMs: 2000,
          key: {'date': '2026-10-01'},
          delta: {'words_learned': 3, 'correct_count': 2},
        ),
      ], db: db);

      final row = (await db.query('daily_activity')).single;
      expect(row['words_learned'], 5);
      expect(row['correct_count'], 3);
    });
  });
}
