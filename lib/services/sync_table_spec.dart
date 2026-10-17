/// 同步表规格：单一事实来源，用于生成 oplog 表与 SQLite 触发器。
///
/// 设计要点：
/// - 触发器与业务写入在同一事务内，保证「数据落库 ⇒ 变更已记录」；
/// - 触发器写入类型化 oplog 表，不依赖 SQLite JSON1；
/// - 计数类字段单独记录增量（`delta_<column>`），避免跨设备合并时丢计数；
/// - `sync_meta.applying = 1` 时触发器静默，防止应用远端操作时回环。
///
/// 不在此列表中的业务表视为「不同步」（缓存 / 本机诊断 / Prefs）。
class SyncTableSpec {
  /// oplog 实体名（同时作为 `oplog_<entity>` 表后缀）。
  final String entity;

  /// 源表名。
  final String table;

  /// 业务唯一键（跨设备稳定）：列名 → SQLite 类型。
  final Map<String, String> keyColumns;

  /// 普通数据列：列名 → SQLite 类型。
  final Map<String, String> dataColumns;

  /// 计数列（源表列名），oplog 中记录为 `delta_<column>`。
  final Set<String> counters;

  /// 冲突判定用的本地时间列（如 updated_at / last_reviewed_at）。
  ///
  /// 远端数据的时间戳早于本地时跳过字段覆盖；为 null 时按 HLC 顺序应用。
  final String? lwwColumn;

  const SyncTableSpec({
    required this.entity,
    required this.table,
    required this.keyColumns,
    this.dataColumns = const {},
    this.counters = const {},
    this.lwwColumn,
  });

  String get oplogTable => 'oplog_$entity';

  String get pendingIndex => 'idx_${oplogTable}_pending';

  String get _keysSql =>
      keyColumns.entries.map((e) => '"${e.key}" ${e.value}').join(', ');

  String get _dataSql =>
      dataColumns.entries.map((e) => '"${e.key}" ${e.value}').join(', ');

  String get _countersSql =>
      counters.map((c) => '"delta_$c" INTEGER').join(', ');

  String get _columnsSql {
    final parts = <String>[
      '"seq" INTEGER PRIMARY KEY AUTOINCREMENT',
      '"op" TEXT NOT NULL',
    ];
    if (keyColumns.isNotEmpty) parts.add(_keysSql);
    if (dataColumns.isNotEmpty) parts.add(_dataSql);
    if (counters.isNotEmpty) parts.add(_countersSql);
    parts.add('"hlc_ms" INTEGER');
    parts.add('"hlc_counter" INTEGER');
    return parts.join(',\n  ');
  }

  String get oplogDdl =>
      'CREATE TABLE IF NOT EXISTS "$oplogTable" (\n  $_columnsSql\n)';

  String get pendingIndexDdl =>
      'CREATE INDEX IF NOT EXISTS "$pendingIndex" ON "$oplogTable"("hlc_ms")';

  /// 生成 3 个触发器（INSERT / UPDATE / DELETE）。
  List<String> get triggerDdls => [
    _trigger(
      name: 'trg_${entity}_insert',
      event: 'INSERT',
      body: _insertStatement(row: 'NEW', deltaPrefix: 'NEW'),
    ),
    _trigger(
      name: 'trg_${entity}_update',
      event: 'UPDATE',
      body: _insertStatement(row: 'NEW', deltaPrefix: 'NEW-OLD'),
    ),
    _trigger(
      name: 'trg_${entity}_delete',
      event: 'DELETE',
      body: _deleteStatement(),
    ),
  ];

  String _trigger({
    required String name,
    required String event,
    required String body,
  }) {
    return 'CREATE TRIGGER IF NOT EXISTS "$name" '
        'AFTER $event ON "$table" '
        'WHEN (SELECT "applying" FROM "sync_meta" WHERE "id" = 1) = 0 '
        'AND (SELECT "capture_enabled" FROM "sync_meta" WHERE "id" = 1) = 1 '
        'BEGIN\n  $body;\nEND';
  }

  String _insertStatement({required String row, required String deltaPrefix}) {
    final columns = <String>['"op"'];
    final values = <String>["'upsert'"];
    for (final key in keyColumns.keys) {
      columns.add('"$key"');
      values.add('$row."$key"');
    }
    for (final data in dataColumns.keys) {
      columns.add('"$data"');
      values.add('$row."$data"');
    }
    for (final counter in counters) {
      columns.add('"delta_$counter"');
      if (deltaPrefix == 'NEW') {
        values.add('$row."$counter"');
      } else {
        values.add('$row."$counter" - COALESCE(OLD."$counter", 0)');
      }
    }
    return 'INSERT INTO "$oplogTable" (${columns.join(', ')}) '
        'VALUES (${values.join(', ')})';
  }

  String _deleteStatement() {
    final columns = <String>['"op"'];
    final values = <String>["'delete'"];
    for (final key in keyColumns.keys) {
      columns.add('"$key"');
      values.add('OLD."$key"');
    }
    return 'INSERT INTO "$oplogTable" (${columns.join(', ')}) '
        'VALUES (${values.join(', ')})';
  }
}

/// 所有参与同步的表（顺序即创建顺序，便于阅读）。
class SyncSpecs {
  SyncSpecs._();

  static const List<SyncTableSpec> all = [
    SyncTableSpec(
      entity: 'user_word_records',
      table: 'user_word_records',
      keyColumns: {'word': 'TEXT'},
      dataColumns: {
        'stage': 'INTEGER',
        'is_weak': 'INTEGER',
        'is_mastered': 'INTEGER',
        'next_review_date': 'TEXT',
        'last_reviewed_at': 'TEXT',
        'created_at': 'TEXT',
      },
      counters: {'review_count'},
      lwwColumn: 'last_reviewed_at',
    ),
    SyncTableSpec(
      entity: 'wrong_words',
      table: 'wrong_words',
      keyColumns: {'word': 'TEXT'},
      dataColumns: {'scheduled_date': 'TEXT', 'created_at': 'TEXT'},
    ),
    SyncTableSpec(
      entity: 'word_notes',
      table: 'word_notes',
      keyColumns: {'word': 'TEXT'},
      dataColumns: {
        'note': 'TEXT',
        'is_favorited': 'INTEGER',
        'created_at': 'TEXT',
        'updated_at': 'TEXT',
      },
      lwwColumn: 'updated_at',
    ),
    SyncTableSpec(
      entity: 'sentence_notes',
      table: 'sentence_notes',
      keyColumns: {'sentence_id': 'TEXT'},
      dataColumns: {
        'set_id': 'TEXT',
        'english': 'TEXT',
        'chinese': 'TEXT',
        'note': 'TEXT',
        'is_favorited': 'INTEGER',
        'created_at': 'TEXT',
        'updated_at': 'TEXT',
      },
      lwwColumn: 'updated_at',
    ),
    SyncTableSpec(
      entity: 'daily_activity',
      table: 'daily_activity',
      keyColumns: {'date': 'TEXT'},
      dataColumns: {'completed': 'INTEGER', 'daily_goal': 'INTEGER'},
      counters: {
        'words_learned',
        'words_reviewed',
        'correct_count',
        'wrong_count',
      },
    ),
    SyncTableSpec(
      entity: 'word_books',
      table: 'word_books',
      keyColumns: {'uuid': 'TEXT'},
      dataColumns: {
        'title': 'TEXT',
        'description': 'TEXT',
        'cover_path': 'TEXT',
        'cover_color': 'INTEGER',
        'author': 'TEXT',
        'word_count': 'INTEGER',
        'is_builtin': 'INTEGER',
        'created_at': 'TEXT',
        'updated_at': 'TEXT',
      },
      lwwColumn: 'updated_at',
    ),
    SyncTableSpec(
      entity: 'word_book_entries',
      table: 'word_book_entries',
      keyColumns: {'book_uuid': 'TEXT', 'word': 'TEXT'},
      dataColumns: {'added_at': 'TEXT'},
    ),
    SyncTableSpec(
      entity: 'sentences',
      table: 'sentences',
      keyColumns: {'id': 'TEXT'},
      dataColumns: {
        'set_id': 'TEXT',
        'english': 'TEXT',
        'chinese': 'TEXT',
        'extra_words': 'TEXT',
        'created_at': 'TEXT',
        'sort_index': 'REAL',
      },
    ),
    SyncTableSpec(
      entity: 'attempted_sentence_ids',
      table: 'attempted_sentence_ids',
      keyColumns: {'set_id': 'TEXT', 'sentence_id': 'TEXT'},
    ),
    SyncTableSpec(
      entity: 'practiced_sentence_ids',
      table: 'practiced_sentence_ids',
      keyColumns: {'set_id': 'TEXT', 'sentence_id': 'TEXT'},
    ),
    SyncTableSpec(
      entity: 'wrong_sentences',
      table: 'wrong_sentences',
      keyColumns: {'sentence_id': 'TEXT'},
      dataColumns: {
        'id': 'TEXT',
        'set_id': 'TEXT',
        'english': 'TEXT',
        'chinese': 'TEXT',
        'score': 'INTEGER',
        'user_answer': 'TEXT',
        'mode': 'INTEGER',
        'created_at': 'TEXT',
        'last_wrong_at': 'TEXT',
      },
      counters: {'wrong_count'},
      lwwColumn: 'last_wrong_at',
    ),
    SyncTableSpec(
      entity: 'learning_sessions',
      table: 'learning_sessions',
      keyColumns: {'uuid': 'TEXT'},
      dataColumns: {
        'session_type': 'TEXT',
        'started_at': 'TEXT',
        'ended_at': 'TEXT',
        'duration_seconds': 'INTEGER',
        'date': 'TEXT',
      },
    ),
    SyncTableSpec(
      entity: 'vocab_test_history',
      table: 'vocab_test_history',
      keyColumns: {'uuid': 'TEXT'},
      dataColumns: {
        'date': 'TEXT',
        'total_count': 'INTEGER',
        'correct_count': 'INTEGER',
        'accuracy': 'REAL',
        'book_id': 'INTEGER',
        'book_title': 'TEXT',
      },
    ),
  ];

  static final Map<String, SyncTableSpec> byEntity = {
    for (final spec in all) spec.entity: spec,
  };
}
