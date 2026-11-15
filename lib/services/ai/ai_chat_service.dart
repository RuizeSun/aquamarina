import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../../models/ai_chat.dart';
import '../data/database_service.dart';
import '../system/log_service.dart';

/// AI 对话的会话与消息持久化服务。
///
/// 读写失败只记录日志、不抛出到 UI：对话本身仍然可用，只是本次内容未能保存。
/// 消息参与云同步（见 `SyncSpecs`），因此这里只负责业务层的建删改查。
class AiChatService {
  AiChatService._(this._openDatabase);

  /// 全局单例：使用应用业务数据库。
  static final AiChatService instance = AiChatService._(
    () => DatabaseService.database,
  );

  /// 测试专用：注入自定义数据库（例如 sqflite ffi 内存库）。
  @visibleForTesting
  AiChatService.withDatabase(Future<Database> Function() openDatabase)
    : _openDatabase = openDatabase;

  final Future<Database> Function() _openDatabase;

  static const String sessionsTable = 'ai_chat_sessions';
  static const String messagesTable = 'ai_chat_messages';

  /// 会话标题最大长度（超出截断，避免列表被撑开）。
  static const int titleMaxChars = 24;

  // ── 纯函数 ────────────────────────────────────────

  /// 由首条用户消息生成会话标题：折叠空白后取前 [titleMaxChars] 个字符。
  static String suggestTitle(String firstUserText) {
    final normalized = firstUserText.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (normalized.isEmpty) return AiChatSession.defaultTitle;
    if (normalized.length <= titleMaxChars) return normalized;
    return normalized.substring(0, titleMaxChars);
  }

  // ── 会话 ──────────────────────────────────────────

  /// 列出会话（按最近更新倒序）。
  Future<List<AiChatSession>> listSessions({int limit = 100}) async {
    try {
      final db = await _openDatabase();
      final rows = await db.query(
        sessionsTable,
        orderBy: 'updated_at DESC',
        limit: limit,
      );
      return rows.map(AiChatSession.fromRow).toList();
    } catch (e, stackTrace) {
      logError('AiChatService', '读取会话列表失败: $e', stackTrace);
      return const [];
    }
  }

  /// 创建会话并返回它。
  Future<AiChatSession> createSession({
    String? title,
    String? profileId,
  }) async {
    final session = AiChatSession.create(title: title, profileId: profileId);
    await insertSession(session);
    return session;
  }

  /// 插入一条已构造好的会话（测试与同步回放用）。
  Future<void> insertSession(AiChatSession session) async {
    try {
      final db = await _openDatabase();
      await db.insert(
        sessionsTable,
        session.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (e, stackTrace) {
      logError('AiChatService', '保存会话失败: $e', stackTrace);
    }
  }

  /// 读取单个会话。
  Future<AiChatSession?> getSession(String id) async {
    try {
      final db = await _openDatabase();
      final rows = await db.query(
        sessionsTable,
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      return AiChatSession.fromRow(rows.first);
    } catch (e, stackTrace) {
      logError('AiChatService', '读取会话失败: $e', stackTrace);
      return null;
    }
  }

  /// 重命名会话。
  Future<void> renameSession(String id, String title) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return;
    final safe = trimmed.length > titleMaxChars
        ? trimmed.substring(0, titleMaxChars)
        : trimmed;
    try {
      final db = await _openDatabase();
      await db.update(
        sessionsTable,
        {'title': safe, 'updated_at': DateTime.now().toIso8601String()},
        where: 'id = ?',
        whereArgs: [id],
      );
    } catch (e, stackTrace) {
      logError('AiChatService', '重命名会话失败: $e', stackTrace);
    }
  }

  /// 删除会话（含其全部消息）。
  ///
  /// 事务内先删消息再删会话；即使外键级联被关闭也不会留下孤儿消息。
  Future<void> deleteSession(String id) async {
    try {
      final db = await _openDatabase();
      await db.transaction((txn) async {
        await txn.delete(messagesTable, where: 'session_id = ?', whereArgs: [id]);
        await txn.delete(sessionsTable, where: 'id = ?', whereArgs: [id]);
      });
    } catch (e, stackTrace) {
      logError('AiChatService', '删除会话失败: $e', stackTrace);
    }
  }

  /// 清空当前会话的消息（保留会话本身，标题与创建时间不变）。
  Future<void> clearSessionMessages(String id) async {
    try {
      final db = await _openDatabase();
      await db.transaction((txn) async {
        await txn.delete(messagesTable, where: 'session_id = ?', whereArgs: [id]);
        await txn.update(
          sessionsTable,
          {'updated_at': DateTime.now().toIso8601String()},
          where: 'id = ?',
          whereArgs: [id],
        );
      });
    } catch (e, stackTrace) {
      logError('AiChatService', '清空会话失败: $e', stackTrace);
    }
  }

  // ── 消息 ──────────────────────────────────────────

  /// 读取会话的全部消息（按 sort_index 升序）。
  Future<List<AiChatMessage>> loadMessages(String sessionId) async {
    try {
      final db = await _openDatabase();
      final rows = await db.query(
        messagesTable,
        where: 'session_id = ?',
        whereArgs: [sessionId],
        orderBy: 'sort_index ASC, created_at ASC',
      );
      return rows.map(AiChatMessage.fromRow).toList();
    } catch (e, stackTrace) {
      logError('AiChatService', '读取消息失败: $e', stackTrace);
      return const [];
    }
  }

  /// 追加一条消息。
  ///
  /// 流式期间消息只驻留内存，结束后才调用本方法一次性写入，因此不会产生
  /// 「每帧一行 oplog」的同步风暴。`sort_index` 在事务内取 MAX+1，保证顺序稳定。
  Future<AiChatMessage?> appendMessage(AiChatMessage message) async {
    try {
      final db = await _openDatabase();
      late AiChatMessage saved;
      await db.transaction((txn) async {
        final rows = await txn.rawQuery(
          'SELECT MAX(sort_index) AS max_index FROM $messagesTable '
          'WHERE session_id = ?',
          [message.sessionId],
        );
        final maxIndex = (rows.first['max_index'] as num?)?.toDouble() ?? 0;
        saved = message.copyWith(sortIndex: maxIndex + 1);
        await txn.insert(
          messagesTable,
          saved.toRow(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        await txn.update(
          sessionsTable,
          {'updated_at': DateTime.now().toIso8601String()},
          where: 'id = ?',
          whereArgs: [message.sessionId],
        );
      });
      return saved;
    } catch (e, stackTrace) {
      logError('AiChatService', '保存消息失败: $e', stackTrace);
      return null;
    }
  }

  /// 仅更新消息状态（错误 / 取消收尾用，不参与流式增量）。
  Future<void> updateMessageStatus(
    String id,
    AiChatMessageStatus status, {
    String? errorMessage,
  }) async {
    try {
      final db = await _openDatabase();
      await db.update(
        messagesTable,
        {
          'status': status.name,
          'error_message': ?errorMessage,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
    } catch (e, stackTrace) {
      logError('AiChatService', '更新消息状态失败: $e', stackTrace);
    }
  }

  Future<void> deleteMessage(String id) async {
    try {
      final db = await _openDatabase();
      await db.delete(messagesTable, where: 'id = ?', whereArgs: [id]);
    } catch (e, stackTrace) {
      logError('AiChatService', '删除消息失败: $e', stackTrace);
    }
  }

  // ── 统计与清空 ────────────────────────────────────

  /// 会话数量（设置页展示）。
  Future<int> countSessions() async => _count(sessionsTable);

  /// 消息数量（设置页展示）。
  Future<int> countMessages() async => _count(messagesTable);

  Future<int> _count(String table) async {
    try {
      final db = await _openDatabase();
      final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM $table');
      return (rows.first['c'] as int?) ?? 0;
    } catch (e, stackTrace) {
      logError('AiChatService', '统计 $table 失败: $e', stackTrace);
      return 0;
    }
  }

  /// 清空全部对话（设置页「清空全部对话」）。
  Future<void> clearAll() async {
    try {
      final db = await _openDatabase();
      await db.transaction((txn) async {
        await txn.delete(messagesTable);
        await txn.delete(sessionsTable);
      });
    } catch (e, stackTrace) {
      logError('AiChatService', '清空全部对话失败: $e', stackTrace);
    }
  }
}
