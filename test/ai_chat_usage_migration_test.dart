import 'package:aquamarina/models/ai_chat.dart';
import 'package:aquamarina/services/ai/ai_chat_service.dart';
import 'package:aquamarina/services/cloud/sync_schema.dart';
import 'package:aquamarina/services/cloud/sync_table_spec.dart';
import 'package:aquamarina/services/data/database_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sync_test_support.dart';

/// v21 → v22 迁移：给消息表与 oplog 补 usage 列，并重建触发器。
///
/// 这是同步链路上最容易出事的一步：触发器按 SyncSpecs 的 dataColumns 生成，
/// 只补业务表不补 oplog 会让「写消息」直接报错，因此两条路径都要覆盖。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('补齐 usage 列后，写入消息仍能正常捕获 oplog', () async {
    final db = await openSyncTestDb();
    addTearDown(db.close);

    // 模拟 v21 的 oplog：缺少 usage 列
    await db.execute('DROP TABLE oplog_ai_chat_messages');
    final oldColumns = <String>[
      '"seq" INTEGER PRIMARY KEY AUTOINCREMENT',
      '"op" TEXT NOT NULL',
      '"id" TEXT',
      for (final entry
          in SyncSpecs.byEntity['ai_chat_messages']!.dataColumns.entries)
        if (entry.key != 'usage') '"${entry.key}" ${entry.value}',
      '"hlc_ms" INTEGER',
      '"hlc_counter" INTEGER',
      '"captured_at_ms" INTEGER',
    ];
    await db.execute(
      'CREATE TABLE oplog_ai_chat_messages (${oldColumns.join(', ')})',
    );

    await DatabaseService.migrateToV22(db);

    Future<Set<String>> columnsOf(String table) async {
      final rows = await db.rawQuery('PRAGMA table_info($table)');
      return rows.map((row) => row['name'].toString()).toSet();
    }

    expect(
      await columnsOf('ai_chat_messages'),
      contains('usage'),
      reason: '业务表缺少 usage 列',
    );
    expect(
      await columnsOf('oplog_ai_chat_messages'),
      contains('usage'),
      reason: 'oplog 缺少 usage 列，触发器会写入失败',
    );

    // 触发器必须已按新规格重建：写入一条带用量的消息后 oplog 应可读
    await SyncSchema.setCaptureEnabled(db, true);
    final service = AiChatService.withDatabase(() async => db);
    final session = await service.createSession(title: '迁移验证');
    await service.appendMessage(
      AiChatMessage.create(
        sessionId: session.id,
        role: AiChatRole.assistant,
        content: '好的',
        usage: const AiMessageUsage(
          promptTokens: 12,
          completionTokens: 3,
          totalTokens: 15,
        ),
      ),
    );

    final rows = await db.query(
      SyncSpecs.byEntity['ai_chat_messages']!.oplogTable,
      where: "op = 'upsert'",
    );
    expect(rows, isNotEmpty);
    expect(rows.last['usage'], contains('"total_tokens":15'));
  });
}
