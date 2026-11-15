import 'package:aquamarina/models/ai_chat.dart';
import 'package:aquamarina/models/sync_op.dart';
import 'package:aquamarina/services/ai/ai_chat_service.dart';
import 'package:aquamarina/services/cloud/sync_apply_service.dart';
import 'package:aquamarina/services/cloud/sync_table_spec.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'sync_test_support.dart';

/// 从本地库读取 chat 的待上传 oplog，转换成远端 op。
Future<List<SyncOp>> _drainOps(Database db, int baseHlcMs) async {
  final ops = <SyncOp>[];
  var hlcMs = baseHlcMs;
  for (final spec in SyncSpecs.all) {
    if (spec.entity != 'ai_chat_sessions' &&
        spec.entity != 'ai_chat_messages') {
      continue;
    }
    final rows = await db.query(spec.oplogTable, orderBy: 'seq ASC');
    for (final row in rows) {
      hlcMs += 1;
      final key = <String, dynamic>{
        for (final column in spec.keyColumns.keys) column: row[column],
      };
      final data = <String, dynamic>{
        for (final column in spec.dataColumns.keys) column: row[column],
      };
      ops.add(
        SyncOp(
          deviceId: '11111111-1111-4111-8111-111111111111',
          seq: row['seq'] as int,
          hlc: SyncHlc(hlcMs, 0),
          entity: spec.entity,
          key: key,
          op: row['op'] as String,
          data: data,
        ),
      );
    }
  }
  return ops;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('SyncSchema 为对话实体安装了 oplog 表与触发器', () async {
    final db = await openSyncTestDb();
    addTearDown(db.close);

    for (final entity in ['ai_chat_sessions', 'ai_chat_messages']) {
      final spec = SyncSpecs.byEntity[entity]!;
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
        [spec.oplogTable],
      );
      expect(tables, hasLength(1), reason: '$entity oplog 表缺失');

      final triggers = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE ?",
        ['trg_${entity}_%'],
      );
      expect(triggers, hasLength(3), reason: '$entity 触发器数量不对');
    }
  });

  test('会话与消息写入会进入 oplog', () async {
    final db = await openSyncTestDb();
    addTearDown(db.close);
    final service = AiChatService.withDatabase(() async => db);

    final session = await service.createSession(title: '同步测试');
    await service.appendMessage(
      AiChatMessage.create(
        sessionId: session.id,
        role: AiChatRole.user,
        content: '你好',
      ),
    );

    final sessionOps = await db.query('oplog_ai_chat_sessions');
    final messageOps = await db.query('oplog_ai_chat_messages');
    expect(sessionOps, isNotEmpty);
    expect(messageOps, isNotEmpty);
    expect(sessionOps.first['op'], 'upsert');
    expect(messageOps.first['session_id'], session.id);
  });

  test('消息先于父会话到达时会挂起，随后同批重试成功', () async {
    final source = await openSyncTestDb();
    final target = await openSyncTestDb();
    addTearDown(source.close);
    addTearDown(target.close);

    final sourceService = AiChatService.withDatabase(() async => source);
    final session = await sourceService.createSession(title: '顺序测试');
    await sourceService.appendMessage(
      AiChatMessage.create(
        sessionId: session.id,
        role: AiChatRole.user,
        content: '第一条',
      ),
    );

    final ops = await _drainOps(source, 1000);
    // 故意打乱：把 message op 排到 session op 之前
    ops.sort((a, b) => a.entity == 'ai_chat_messages' ? -1 : 1);

    final result = await SyncApplyService.applyOps(ops, db: target);
    expect(result.applied, greaterThanOrEqualTo(2));
    expect(result.skippedMissingParent, 0);

    final targetSessions = await target.query('ai_chat_sessions');
    final targetMessages = await target.query('ai_chat_messages');
    expect(targetSessions, hasLength(1));
    expect(targetMessages, hasLength(1));
    expect(targetMessages.first['content'], '第一条');
  });

  test('父会话缺失时消息挂起而不是丢弃', () async {
    final source = await openSyncTestDb();
    final target = await openSyncTestDb();
    addTearDown(source.close);
    addTearDown(target.close);

    final sourceService = AiChatService.withDatabase(() async => source);
    final session = await sourceService.createSession(title: '孤儿测试');
    await sourceService.appendMessage(
      AiChatMessage.create(
        sessionId: session.id,
        role: AiChatRole.user,
        content: '孤立消息',
      ),
    );

    final all = await _drainOps(source, 2000);
    final messageOnly = all.where((op) => op.entity == 'ai_chat_messages').toList();

    final result = await SyncApplyService.applyOps(messageOnly, db: target);
    expect(result.skippedMissingParent, 1);
    expect(await target.query('ai_chat_messages'), isEmpty);
  });

  test('删除会话会把消息一并删除并写墓碑', () async {
    final source = await openSyncTestDb();
    final target = await openSyncTestDb();
    addTearDown(source.close);
    addTearDown(target.close);

    final sourceService = AiChatService.withDatabase(() async => source);
    final targetService = AiChatService.withDatabase(() async => target);

    final session = await sourceService.createSession(title: '删除测试');
    await sourceService.appendMessage(
      AiChatMessage.create(
        sessionId: session.id,
        role: AiChatRole.user,
        content: '会被删',
      ),
    );

    // 先同步一次，让目标端拥有会话与消息
    final firstBatch = await _drainOps(source, 3000);
    await SyncApplyService.applyOps(firstBatch, db: target);
    expect(await targetService.countMessages(), 1);

    // 再在源端删除会话并同步
    await SyncCaptureHelper.clearOpLog(source);
    await sourceService.deleteSession(session.id);
    final secondBatch = await _drainOps(source, 4000);
    final apply2 = await SyncApplyService.applyOps(secondBatch, db: target);
    expect(apply2.applied, greaterThanOrEqualTo(1));

    expect(await target.query('ai_chat_sessions'), isEmpty);
    expect(await target.query('ai_chat_messages'), isEmpty);
  });

  test('会话被删除后，迟到的旧消息 op 会被墓碑拦截', () async {
    final target = await openSyncTestDb();
    addTearDown(target.close);

    const sessionId = 'session-x';
    const messageId = 'message-x';

    // 1) 会话 + 消息先落地
    await SyncApplyService.applyOps([
      SyncOp(
        deviceId: '22222222-2222-4222-8222-222222222222',
        seq: 1,
        hlc: const SyncHlc(1000, 0),
        entity: 'ai_chat_sessions',
        key: {'id': sessionId},
        op: 'upsert',
        data: {
          'title': '会话',
          'created_at': '2026-01-01T00:00:00.000',
          'updated_at': '2026-01-01T00:00:00.000',
        },
      ),
      SyncOp(
        deviceId: '22222222-2222-4222-8222-222222222222',
        seq: 2,
        hlc: const SyncHlc(1001, 0),
        entity: 'ai_chat_messages',
        key: {'id': messageId},
        op: 'upsert',
        data: {
          'session_id': sessionId,
          'role': 'user',
          'content': '旧消息',
          'status': 'complete',
          'created_at': '2026-01-01T00:00:00.000',
          'sort_index': 1.0,
        },
      ),
    ], db: target);
    expect(await target.query('ai_chat_messages'), hasLength(1));

    // 2) 删除会话
    await SyncApplyService.applyOps([
      SyncOp(
        deviceId: '22222222-2222-4222-8222-222222222222',
        seq: 3,
        hlc: const SyncHlc(1002, 0),
        entity: 'ai_chat_sessions',
        key: {'id': sessionId},
        op: 'delete',
      ),
    ], db: target);
    expect(await target.query('ai_chat_sessions'), isEmpty);
    expect(await target.query('ai_chat_messages'), isEmpty);

    // 3) 迟到的旧消息 op（HLC 更小）不应复活
    await SyncApplyService.applyOps([
      SyncOp(
        deviceId: '22222222-2222-4222-8222-222222222222',
        seq: 2,
        hlc: const SyncHlc(1001, 0),
        entity: 'ai_chat_messages',
        key: {'id': messageId},
        op: 'upsert',
        data: {
          'session_id': sessionId,
          'role': 'user',
          'content': '旧消息',
          'status': 'complete',
          'created_at': '2026-01-01T00:00:00.000',
          'sort_index': 1.0,
        },
      ),
    ], db: target);
    expect(await target.query('ai_chat_messages'), isEmpty);
  });
}

/// 测试辅助：清空本机 oplog，便于只导出「删除之后」的增量。
class SyncCaptureHelper {
  static Future<void> clearOpLog(Database db) async {
    for (final spec in SyncSpecs.all) {
      await db.delete(spec.oplogTable);
    }
  }
}
