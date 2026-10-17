import 'package:aquamarina/models/cloud_sync_manifest.dart';
import 'package:aquamarina/models/sync_op.dart';
import 'package:aquamarina/services/cloud_sync_engine.dart';
import 'package:aquamarina/services/cloud_sync_settings.dart';
import 'package:aquamarina/services/sync_capture_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fake_s3_storage.dart';
import 'sync_test_support.dart';

const String _deviceA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const String _deviceB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

CloudSyncConfig _config() => CloudSyncConfig.create(
  endpointInput: 'https://cn-nb1.rains3.com',
  bucket: 'aquamarina-test',
  region: 'cn-nb1',
  prefix: 'aquamarina',
);

String _chunkKey(CloudSyncConfig config, String deviceId, List<SyncOp> ops) {
  final bytes = SyncChunkCodec.encode(ops);
  final sha = CloudSyncUtils.sha256Hex(bytes);
  final hlc = ops.first.hlc.value.replaceAll(':', '-');
  return '${config.devicePrefix(deviceId)}/chunks/$hlc-'
      '${sha.substring(0, 16)}.jsonl';
}

void main() {
  late Database db;
  late FakeS3Storage storage;
  late CloudSyncConfig config;

  setUp(() async {
    db = await openSyncTestDb();
    config = _config();
    storage = FakeS3Storage(config);
  });

  tearDown(() async {
    await db.close();
  });

  CloudSyncEngine engine() => CloudSyncEngine.forTesting(
    config: config,
    deviceId: _deviceA,
    deviceName: '设备 A',
    storage: storage,
    database: db,
  );

  test('拉取其它设备 chunk 并应用，重复运行不重复应用', () async {
    final ops = [
      makeOp(
        entity: 'word_notes',
        seq: 1,
        hlcMs: 1000,
        key: {'word': 'apple'},
        data: {
          'note': 'from B',
          'is_favorited': 1,
          'updated_at': '2026-10-01T00:00:00Z',
        },
        deviceId: _deviceB,
      ),
    ];
    storage.objects[_chunkKey(config, _deviceB, ops)] = SyncChunkCodec.encode(
      ops,
    );

    var result = await engine().run(push: false);
    expect(result.pulledChunks, 1);
    expect(result.pulledOps, 1);
    var rows = await db.query('word_notes');
    expect(rows.single['note'], 'from B');

    result = await engine().run(push: false);
    expect(result.pulledChunks, 0);
    expect(result.pulledOps, 0);
    rows = await db.query('word_notes');
    expect(rows.length, 1);
  });

  test('推送本机 oplog 为不可变 chunk，成功后清空待上传', () async {
    await db.insert('word_notes', {
      'word': 'banana',
      'note': 'from A',
      'is_favorited': 0,
      'updated_at': '2026-10-02T00:00:00Z',
    });

    var result = await engine().run(pull: false);
    expect(result.pushedChunks, 1);
    expect(result.pushedOps, 1);
    expect(result.remainingLocalOps, 0);
    expect(await SyncCaptureService.pendingCount(db: db), 0);

    final chunkKeys = storage.objects.keys
        .where((k) => k.contains('/devices/$_deviceA/chunks/'))
        .toList();
    expect(chunkKeys.length, 1);
    final ops = SyncChunkCodec.decode(storage.objects[chunkKeys.single]!);
    expect(ops.single.key['word'], 'banana');

    result = await engine().run(pull: false);
    expect(result.pushedChunks, 0);
  });

  test('缺失父级的 chunk 不记为已应用，父级到达后自动重试', () async {
    final entryOp = makeOp(
      entity: 'word_book_entries',
      seq: 1,
      hlcMs: 900,
      key: {'book_uuid': 'book-1', 'word': 'apple'},
      data: {'added_at': '2026-10-01T00:00:00Z'},
      deviceId: _deviceB,
    );
    storage.objects[_chunkKey(config, _deviceB, [entryOp])] =
        SyncChunkCodec.encode([entryOp]);

    var result = await engine().run(push: false);
    expect(result.skippedMissingParent, 1);
    expect(await db.query('sync_chunks'), isEmpty);
    expect(await db.query('word_book_entries'), isEmpty);

    // 父级（词书）在后续 chunk 到达
    final bookOp = makeOp(
      entity: 'word_books',
      seq: 1,
      hlcMs: 1000,
      key: {'uuid': 'book-1'},
      data: {
        'title': 'Book',
        'word_count': 1,
        'created_at': '2026-10-01T00:00:00Z',
        'updated_at': '2026-10-01T00:00:00Z',
      },
      deviceId: _deviceB,
    );
    storage.objects[_chunkKey(config, _deviceB, [bookOp])] =
        SyncChunkCodec.encode([bookOp]);

    await engine().run(push: false);
    // 条目 chunk 会再次排到词书 chunk 之前，因此还需下一轮
    await engine().run(push: false);

    final entries = await db.query('word_book_entries');
    expect(entries.length, 1);
    expect(entries.single['book_uuid'], 'book-1');
    expect(await db.query('sync_chunks'), isNotEmpty);
  });
}
