import 'dart:typed_data';

import 'package:aquamarina/models/cloud_sync_device_state.dart';
import 'package:aquamarina/models/cloud_sync_manifest.dart';
import 'package:aquamarina/models/sync_op.dart';
import 'package:aquamarina/services/cloud_sync_device_meta_service.dart';
import 'package:aquamarina/services/cloud_sync_engine.dart';
import 'package:aquamarina/services/cloud_sync_settings.dart';
import 'package:aquamarina/services/sync_capture_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
    SharedPreferences.setMockInitialValues({});
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
    expect(chunkKeys.single, endsWith('.jsonl.gz'));
    expect(
      RegExp(
        r'/[0-9a-f]{16}-[0-9a-f]{8}-[0-9a-f]{64}\.jsonl\.gz$',
      ).hasMatch(chunkKeys.single),
      isTrue,
    );
    final ops = SyncChunkCodec.decodeAuto(storage.objects[chunkKeys.single]!);
    expect(ops.single.key['word'], 'banana');

    result = await engine().run(pull: false);
    expect(result.pushedChunks, 0);
  });

  test('时间预算耗尽时停止，下一次 run 继续处理', () async {
    final ops = [
      makeOp(
        entity: 'word_notes',
        seq: 1,
        hlcMs: 1000,
        key: {'word': 'apple'},
        data: {
          'note': 'from B',
          'is_favorited': 0,
          'updated_at': '2026-10-01T00:00:00Z',
        },
        deviceId: _deviceB,
      ),
    ];
    storage.objects[_chunkKey(config, _deviceB, ops)] = SyncChunkCodec.encode(
      ops,
    );

    final budgeted = await engine().run(
      push: false,
      maxDuration: Duration.zero,
    );
    expect(budgeted.budgetExhausted, isTrue);
    expect(budgeted.pulledChunks, 0);
    expect((await db.query('word_notes')).length, 0);

    final resumed = await engine().run(push: false);
    expect(resumed.pulledChunks, 1);
    expect((await db.query('word_notes')).single['note'], 'from B');
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

  test('上传失败保留 oplog，下次同步重试成功', () async {
    await db.insert('word_notes', {
      'word': 'apple',
      'note': 'retry me',
      'is_favorited': 0,
      'updated_at': '2026-10-02T00:00:00Z',
    });

    storage.failPuts = 1;
    var result = await engine().run(pull: false);
    expect(result.pushedChunks, 0);
    expect(result.errors, isNotEmpty);
    expect(result.remainingLocalOps, 1);
    expect(await SyncCaptureService.pendingCount(db: db), 1);

    result = await engine().run(pull: false);
    expect(result.pushedChunks, 1);
    expect(result.remainingLocalOps, 0);
    expect(await SyncCaptureService.pendingCount(db: db), 0);
  });

  test('损坏的 chunk 不会标记已应用，修正后可重试', () async {
    final ops = [
      makeOp(
        entity: 'word_notes',
        seq: 1,
        hlcMs: 1000,
        key: {'word': 'banana'},
        data: {
          'note': 'from B',
          'is_favorited': 0,
          'updated_at': '2026-10-01T00:00:00Z',
        },
        deviceId: _deviceB,
      ),
    ];
    final goodBytes = SyncChunkCodec.encode(ops);
    final key = _chunkKey(config, _deviceB, ops);
    final corrupted = Uint8List.fromList(goodBytes);
    corrupted[0] = corrupted[0] ^ 0xFF;
    storage.objects[key] = corrupted;

    var result = await engine().run(push: false);
    expect(result.errors, isNotEmpty);
    expect(await db.query('sync_chunks'), isEmpty);
    expect(await db.query('word_notes'), isEmpty);
    var state = await CloudSyncSettings.loadState();
    expect(state.lastError, isNotNull);
    expect(state.lastSuccessAt, isNull);

    storage.objects[key] = goodBytes;
    result = await engine().run(push: false);
    expect(result.pulledChunks, 1);
    expect((await db.query('word_notes')).single['note'], 'from B');
    state = await CloudSyncSettings.loadState();
    expect(state.lastError, isNull);
    expect(state.lastSuccessAt, isNotNull);
  });

  test('推送成功后写 head.json 并清理 dirty 标记', () async {
    await db.insert('word_notes', {
      'word': 'banana',
      'note': 'from A',
      'is_favorited': 0,
      'updated_at': '2026-10-02T00:00:00Z',
    });

    final result = await engine().run(pull: false);
    expect(result.pushedChunks, 1);
    final headKey = config.headKey(_deviceA);
    expect(storage.objects.containsKey(headKey), isTrue);
    final head = CloudDeviceMetaCodec.parseHead(storage.objects[headKey]!);
    expect(head.deviceId, _deviceA);
    expect(head.chunkCount, 1);
    expect(head.latestChunkKey, contains('/chunks/'));
    expect(head.latestHlc, isNotEmpty);

    final meta = await db.query('sync_meta', where: 'id = 1');
    expect(meta.single['head_dirty'], 0);
  });

  test('head 水位未变化时不列举该设备的 chunk', () async {
    final ops = [
      makeOp(
        entity: 'word_notes',
        seq: 1,
        hlcMs: 1000,
        key: {'word': 'apple'},
        data: {
          'note': 'from B',
          'is_favorited': 0,
          'updated_at': '2026-10-01T00:00:00Z',
        },
        deviceId: _deviceB,
      ),
    ];
    final key = _chunkKey(config, _deviceB, ops);
    storage.objects[key] = SyncChunkCodec.encode(ops);
    final meta = CloudSyncDeviceMetaService(config: config, storage: storage);
    await meta.saveHead(
      CloudDeviceHead(
        deviceId: _deviceB,
        deviceName: '设备 B',
        latestChunkKey: key,
        latestHlc: ops.first.hlc.value,
        chunkCount: 1,
        updatedAt: DateTime.now(),
      ),
    );
    await db.insert('sync_state', {
      'device_id': _deviceB,
      'last_seq': 0,
      'last_hlc': ops.first.hlc.value,
      'last_chunk_key': key,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });

    storage.chunkListCalls = 0;
    final result = await engine().run(pull: true, push: false);
    expect(result.skippedByHead, 1);
    expect(storage.chunkListCalls, 0);
    expect(await db.query('word_notes'), isEmpty);
  });

  test('startAfter 只拉取本地水位之后的 chunk', () async {
    final first = makeOp(
      entity: 'word_notes',
      seq: 1,
      hlcMs: 1000,
      key: {'word': 'apple'},
      data: {
        'note': 'old',
        'is_favorited': 0,
        'updated_at': '2026-10-01T00:00:00Z',
      },
      deviceId: _deviceB,
    );
    final second = makeOp(
      entity: 'word_notes',
      seq: 2,
      hlcMs: 2000,
      key: {'word': 'banana'},
      data: {
        'note': 'new',
        'is_favorited': 0,
        'updated_at': '2026-10-02T00:00:00Z',
      },
      deviceId: _deviceB,
    );
    final firstKey = _chunkKey(config, _deviceB, [first]);
    final secondKey = _chunkKey(config, _deviceB, [second]);
    storage.objects[firstKey] = SyncChunkCodec.encode([first]);
    storage.objects[secondKey] = SyncChunkCodec.encode([second]);
    final meta = CloudSyncDeviceMetaService(config: config, storage: storage);
    await meta.saveHead(
      CloudDeviceHead(
        deviceId: _deviceB,
        deviceName: '设备 B',
        latestChunkKey: secondKey,
        latestHlc: second.hlc.value,
        chunkCount: 2,
        updatedAt: DateTime.now(),
      ),
    );
    await db.insert('sync_state', {
      'device_id': _deviceB,
      'last_seq': 0,
      'last_hlc': first.hlc.value,
      'last_chunk_key': firstKey,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });

    final result = await engine().run(pull: true, push: false);
    expect(result.pulledChunks, 1);
    final rows = await db.query('word_notes');
    expect(rows.single['word'], 'banana');
  });

  test('拉取后发布 state.json 水位', () async {
    final ops = [
      makeOp(
        entity: 'word_notes',
        seq: 1,
        hlcMs: 1000,
        key: {'word': 'apple'},
        data: {
          'note': 'from B',
          'is_favorited': 0,
          'updated_at': '2026-10-01T00:00:00Z',
        },
        deviceId: _deviceB,
      ),
    ];
    storage.objects[_chunkKey(config, _deviceB, ops)] = SyncChunkCodec.encode(
      ops,
    );

    final result = await engine().run(pull: true, push: false);
    expect(result.stateUpdated, isTrue);
    final stateKey = config.stateKey(_deviceA);
    expect(storage.objects.containsKey(stateKey), isTrue);
    final state = CloudDeviceMetaCodec.parseState(storage.objects[stateKey]!);
    expect(state.deviceId, _deviceA);
    expect(state.appliedFor(_deviceB), ops.first.hlc);
  });

  test('恢复基线后重放本机在基线之后上传的 chunk', () async {
    final ops = [
      makeOp(
        entity: 'word_notes',
        seq: 1,
        hlcMs: 2000,
        key: {'word': 'apple'},
        data: {
          'note': 'after baseline',
          'is_favorited': 0,
          'updated_at': '2026-10-01T00:00:00Z',
        },
        deviceId: _deviceA,
      ),
    ];
    storage.objects[_chunkKey(config, _deviceA, ops)] = SyncChunkCodec.encode(
      ops,
    );
    await db.update('sync_meta', {
      'device_id': '',
      'baseline_hlc': SyncHlc(1000, 0).value,
    }, where: 'id = 1');

    final result = await engine().run(pull: true, push: false);
    expect(result.pulledChunks, 1);
    expect((await db.query('word_notes')).single['note'], 'after baseline');
  });

  test('没有恢复基线时不重放本机 chunk', () async {
    final ops = [
      makeOp(
        entity: 'word_notes',
        seq: 1,
        hlcMs: 2000,
        key: {'word': 'apple'},
        data: {
          'note': 'own chunk',
          'is_favorited': 0,
          'updated_at': '2026-10-01T00:00:00Z',
        },
        deviceId: _deviceA,
      ),
    ];
    storage.objects[_chunkKey(config, _deviceA, ops)] = SyncChunkCodec.encode(
      ops,
    );

    final result = await engine().run(pull: true, push: false);
    expect(result.pulledChunks, 0);
    expect(await db.query('word_notes'), isEmpty);
  });

  test('head 写失败保留 dirty，下次同步补写', () async {
    await db.insert('word_notes', {
      'word': 'banana',
      'note': 'from A',
      'is_favorited': 0,
      'updated_at': '2026-10-02T00:00:00Z',
    });
    storage.failPutKeyContains = '/head.json';

    var result = await engine().run(pull: false);
    expect(result.errors, isNotEmpty);
    expect(storage.objects.containsKey(config.headKey(_deviceA)), isFalse);
    var meta = await db.query('sync_meta', where: 'id = 1');
    expect(meta.single['head_dirty'], 1);

    storage.failPutKeyContains = null;
    result = await engine().run(pull: false, push: false);
    expect(storage.objects.containsKey(config.headKey(_deviceA)), isTrue);
    meta = await db.query('sync_meta', where: 'id = 1');
    expect(meta.single['head_dirty'], 0);
    expect(result.pushedChunks, 0);
  });

  test('恢复基线后本机新 chunk 不会被自己重放，计数不翻倍', () async {
    await db.update('sync_meta', {
      'baseline_hlc': const SyncHlc(1, 0).value,
    }, where: 'id = 1');
    await db.insert('user_word_records', {
      'word': 'apple',
      'stage': 1,
      'review_count': 1,
      'created_at': '2026-10-01T00:00:00Z',
    });

    // 第一轮：pull 无可拉取内容，push 本机 chunk。
    var result = await engine().run();
    expect(result.pushedChunks, 1);
    expect((await db.query('sync_chunks')).length, 1);
    expect((await db.query('user_word_records')).single['review_count'], 1);

    await db.update(
      'user_word_records',
      {'review_count': 2},
      where: 'word = ?',
      whereArgs: ['apple'],
    );

    // 第二轮：pull 必须先跳过已标记的本机 chunk，再推送新 chunk。
    result = await engine().run();
    expect(result.pushedChunks, 1);
    expect((await db.query('user_word_records')).single['review_count'], 2);

    // 第三轮：两个本机 chunk 都已标记，pull 不应再应用任何计数增量。
    result = await engine().run();
    expect(result.pulledChunks, 0);
    expect((await db.query('user_word_records')).single['review_count'], 2);
  });

  test('已重置的旧设备 ID 不参与拉取', () async {
    SharedPreferences.setMockInitialValues({
      'cloud_sync_ignored_devices_v1': [_deviceB],
    });
    final ops = [
      makeOp(
        entity: 'user_word_records',
        seq: 1,
        hlcMs: 5000,
        key: {'word': 'banana'},
        data: {
          'stage': 1,
          'review_count': 5,
          'created_at': '2026-10-01T00:00:00Z',
        },
        delta: {'review_count': 5},
        deviceId: _deviceB,
      ),
    ];
    storage.objects[_chunkKey(config, _deviceB, ops)] = SyncChunkCodec.encode(
      ops,
    );

    final result = await engine().run(pull: true, push: false);
    expect(result.pulledChunks, 0);
    expect(await db.query('user_word_records'), isEmpty);
  });

  test('按来源水位拉取：水位之前的 chunk 跳过，之后的继续应用', () async {
    final oldOps = [
      makeOp(
        entity: 'word_notes',
        seq: 1,
        hlcMs: 1000,
        key: {'word': 'apple'},
        data: {
          'note': 'already in snapshot',
          'is_favorited': 0,
          'updated_at': '2026-10-01T00:00:00Z',
        },
        deviceId: _deviceB,
      ),
    ];
    final newOps = [
      makeOp(
        entity: 'word_notes',
        seq: 2,
        hlcMs: 3000,
        key: {'word': 'banana'},
        data: {
          'note': 'after snapshot',
          'is_favorited': 0,
          'updated_at': '2026-10-02T00:00:00Z',
        },
        deviceId: _deviceB,
      ),
    ];
    storage.objects[_chunkKey(config, _deviceB, oldOps)] =
        SyncChunkCodec.encode(oldOps);
    storage.objects[_chunkKey(config, _deviceB, newOps)] =
        SyncChunkCodec.encode(newOps);
    await db.update('sync_meta', {
      'baseline_hlc': const SyncHlc(9000, 0).value,
      'restored_watermarks': 1,
    }, where: 'id = 1');
    await db.insert('sync_state', {
      'device_id': _deviceB,
      'last_seq': 0,
      'last_hlc': const SyncHlc(1000, 0).value,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });

    final result = await engine().run(pull: true, push: false);
    expect(result.pulledChunks, 1);
    final rows = await db.query('word_notes');
    expect(rows.single['word'], 'banana');
    expect(rows.single['note'], 'after snapshot');
  });

  test('切换对象存储配置会清理旧后端的同步水位', () async {
    await db.update('sync_meta', {
      'backend_id': 'old-backend',
    }, where: 'id = 1');
    await db.insert('sync_state', {
      'device_id': _deviceB,
      'last_seq': 0,
      'last_hlc': const SyncHlc(1000, 0).value,
      'last_chunk_key': 'old/devices/$_deviceB/chunks/a.jsonl.gz',
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
    await db.insert('sync_chunks', {
      'device_id': _deviceB,
      'chunk_key': 'old/devices/$_deviceB/chunks/a.jsonl.gz',
      'sha256': 'a' * 64,
      'applied_at': DateTime.now().toUtc().toIso8601String(),
    });
    await db.insert('sync_applied', {
      'device_id': _deviceB,
      'entity': 'word_notes',
      'seq': 1,
      'applied_at': DateTime.now().toUtc().toIso8601String(),
    });
    await db.insert('sync_row_versions', {
      'entity': 'word_notes',
      'key': '{"word":"apple"}',
      'hlc': const SyncHlc(1000, 0).value,
    });
    await db.insert('sync_tombstones', {
      'entity': 'word_notes',
      'key': '{"word":"gone"}',
      'deleted_hlc': const SyncHlc(1000, 0).value,
      'deleted_at': DateTime.now().toUtc().toIso8601String(),
    });

    final nextConfig = CloudSyncConfig.create(
      endpointInput: 'https://cn-nb1.rains3.com',
      bucket: 'aquamarina-test',
      region: 'cn-nb1',
      prefix: 'another-prefix',
    );
    final nextEngine = CloudSyncEngine.forTesting(
      config: nextConfig,
      deviceId: _deviceA,
      deviceName: '设备 A',
      storage: FakeS3Storage(nextConfig),
      database: db,
    );
    await nextEngine.run(pull: true, push: false);

    for (final table in const [
      'sync_state',
      'sync_chunks',
      'sync_applied',
      'sync_row_versions',
      'sync_tombstones',
      'sync_conflicts',
    ]) {
      expect(await db.query(table), isEmpty, reason: table);
    }
    final meta = (await db.query('sync_meta')).single;
    expect(meta['backend_id'], nextConfig.backendIdentity);
    expect(meta['restored_watermarks'], 0);
  });

  test('接管前的完整性判断覆盖预算/错误/缺失父级', () {
    final result = CloudSyncRunResult();
    expect(result.hasIncompleteWork, isFalse);

    result.budgetExhausted = true;
    expect(result.hasIncompleteWork, isTrue);

    result
      ..budgetExhausted = false
      ..errors.add('chunk 下载失败');
    expect(result.hasIncompleteWork, isTrue);

    result
      ..errors.clear()
      ..skippedMissingParent = 1;
    expect(result.hasIncompleteWork, isTrue);
  });
}
