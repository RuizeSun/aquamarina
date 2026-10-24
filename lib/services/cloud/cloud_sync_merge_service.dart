import 'dart:convert';
import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../data/backup_service.dart';
import '../data/database_service.dart';
import '../system/log_service.dart';
import 'sync_conflict_store.dart';
import 'sync_schema.dart';
import 'sync_table_spec.dart';

/// 一次快照合并的统计结果。
class CloudSyncMergeResult {
  int inserted = 0;
  int updated = 0;
  int skipped = 0;
  int conflicts = 0;
  final List<String> notes = [];
  final List<SyncConflict> conflictItems = [];

  DateTime? snapshotCreatedAt;
  List<SyncWatermark> watermarks = const [];
  String backendId = '';

  bool get isEmpty => inserted == 0 && updated == 0;
}

/// 把云端统一快照非覆盖合并进本机数据库。
///
/// 规则（宁可保留，不可误删）：
/// - 本机没有的行：插入；
/// - 本机已有的行：按 `updated_at` / `last_reviewed_at` 等 LWW 列取较新；
///   没有 LWW 列的表保留本机值；
/// - 计数器取两边较大值，避免重复累加；
/// - 集合型数据（词书条目、已练句子）取并集；
/// - 不删除本机任何行。
class CloudSyncMergeService {
  CloudSyncMergeService._();

  static const int _chunkSize = 100;
  static const Set<String> _minTimestampColumns = {'created_at'};

  /// 从备份 ZIP 合并到本机数据库；临时文件会在结束后删除。
  static Future<CloudSyncMergeResult> mergeBackupFile(
    File backupFile, {
    Database? localDb,
    void Function(int done, int total)? onProgress,
  }) async {
    final source = await BackupService.extractDatabaseForMerge(backupFile);
    Database? remote;
    try {
      remote = await databaseFactory.openDatabase(
        source.databaseFile.path,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      final result = await mergeDatabases(
        remote: remote,
        localDb: localDb,
        onProgress: onProgress,
      );
      result.snapshotCreatedAt = source.createdAt;
      result.watermarks = source.watermarks;
      result.backendId = source.backendId;
      return result;
    } finally {
      await remote?.close();
      await source.delete();
    }
  }

  /// 合并两个已打开的数据库（便于测试）。
  static Future<CloudSyncMergeResult> mergeDatabases({
    required Database remote,
    Database? localDb,
    void Function(int done, int total)? onProgress,
  }) async {
    final local = localDb ?? await DatabaseService.database;
    final result = CloudSyncMergeResult();
    final bookIds = <String, int>{};
    for (final row in await local.query(
      'word_books',
      columns: ['uuid', 'id'],
    )) {
      final uuid = row['uuid'];
      final id = row['id'];
      if (uuid is String && uuid.isNotEmpty && id is int) {
        bookIds[uuid] = id;
      }
    }

    var total = 0;
    for (final spec in SyncSpecs.all) {
      if (!await _tableExists(remote, spec.table)) continue;
      final remoteColumns = await _columnsOf(remote, spec.table);
      final localColumns = await _columnsOf(local, spec.table);
      final columns = _mergeColumns(spec, remoteColumns, localColumns);
      if (columns.isEmpty) continue;
      total += (await remote.query(spec.table, columns: columns)).length;
    }

    var done = 0;
    for (final spec in SyncSpecs.all) {
      if (!await _tableExists(remote, spec.table)) continue;
      final remoteColumns = await _columnsOf(remote, spec.table);
      final localColumns = await _columnsOf(local, spec.table);
      final columns = _mergeColumns(spec, remoteColumns, localColumns);
      if (columns.isEmpty) continue;

      final rows = await remote.query(spec.table, columns: columns);
      for (var start = 0; start < rows.length; start += _chunkSize) {
        final end = (start + _chunkSize > rows.length)
            ? rows.length
            : start + _chunkSize;
        final chunk = rows.sublist(start, end);
        await local.transaction((txn) async {
          final localRows = await _queryLocalByKeys(txn, spec, chunk);
          final localByKey = {
            for (final row in localRows) _keyFingerprint(spec, row): row,
          };
          for (final remoteRow in chunk) {
            final key = _keyFingerprint(spec, remoteRow);
            final localRow = localByKey[key];
            if (localRow == null) {
              await _insertRemoteRow(
                txn,
                spec,
                remoteRow,
                columns,
                bookIds,
                result,
              );
            } else {
              await _mergeExistingRow(
                txn,
                spec,
                remoteRow,
                localRow,
                columns,
                result,
              );
            }
          }
        });
        done += chunk.length;
        onProgress?.call(done, total);
      }
    }

    if (result.conflictItems.isNotEmpty) {
      try {
        await SyncConflictStore.save(local, result.conflictItems);
      } catch (e) {
        logWarning('CloudSyncMerge', '保存合并冲突记录失败: $e');
      }
    }

    logInfo(
      'CloudSyncMerge',
      '快照合并完成 inserted=${result.inserted} updated=${result.updated} '
          'skipped=${result.skipped} conflicts=${result.conflicts}',
    );
    return result;
  }

  static List<String> _mergeColumns(
    SyncTableSpec spec,
    Set<String> remoteColumns,
    Set<String> localColumns,
  ) {
    return <String>{
          ...spec.keyColumns.keys,
          ...spec.dataColumns.keys,
          ...spec.counters,
        }
        .where((c) => remoteColumns.contains(c) && localColumns.contains(c))
        .toList();
  }

  static Future<bool> _tableExists(Database db, String table) async {
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      [table],
    );
    return rows.isNotEmpty;
  }

  static Future<Set<String>> _columnsOf(Database db, String table) async {
    final rows = await db.rawQuery('PRAGMA table_info("$table")');
    return {
      for (final row in rows)
        if (row['name'] is String) row['name'] as String,
    };
  }

  static String _keyFingerprint(SyncTableSpec spec, Map<String, Object?> row) {
    return jsonEncode([for (final key in spec.keyColumns.keys) row[key]]);
  }

  static Future<List<Map<String, Object?>>> _queryLocalByKeys(
    DatabaseExecutor txn,
    SyncTableSpec spec,
    List<Map<String, Object?>> rows,
  ) async {
    final keys = spec.keyColumns.keys.toList();
    if (keys.isEmpty || rows.isEmpty) return const [];
    final whereParts = <String>[];
    final args = <Object?>[];
    for (final row in rows) {
      final parts = <String>[];
      for (final key in keys) {
        final value = row[key];
        if (value == null) {
          parts.add('"$key" IS NULL');
        } else {
          parts.add('"$key" = ?');
          args.add(value);
        }
      }
      whereParts.add('(${parts.join(' AND ')})');
    }
    return txn.query(
      spec.table,
      where: whereParts.join(' OR '),
      whereArgs: args,
    );
  }

  static Future<void> _insertRemoteRow(
    DatabaseExecutor txn,
    SyncTableSpec spec,
    Map<String, Object?> remoteRow,
    List<String> columns,
    Map<String, int> bookIds,
    CloudSyncMergeResult result,
  ) async {
    final values = <String, Object?>{
      for (final column in columns) column: remoteRow[column],
    };
    // 自增主键不跨设备复制；本地重新分配。
    if (spec.entity == 'word_books' ||
        spec.entity == 'learning_sessions' ||
        spec.entity == 'vocab_test_history' ||
        spec.entity == 'word_book_entries') {
      values.remove('id');
    }
    if (spec.entity == 'wrong_sentences') {
      values.remove('id');
      values['id'] = const Uuid().v4();
    }
    if (spec.entity == 'word_book_entries') {
      values.remove('book_id');
      final bookUuid = values['book_uuid'];
      final bookId = bookUuid is String ? bookIds[bookUuid] : null;
      if (bookId == null) {
        result.skipped++;
        result.notes.add('词书条目缺少父级词书：$bookUuid');
        return;
      }
      values['book_id'] = bookId;
    }

    if (spec.entity == 'word_books') {
      final id = await txn.insert(
        spec.table,
        values,
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      if (id > 0) {
        final uuid = values['uuid'];
        if (uuid is String && uuid.isNotEmpty) bookIds[uuid] = id;
        result.inserted++;
      } else {
        result.skipped++;
      }
      return;
    }

    final id = await txn.insert(
      spec.table,
      values,
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    if (id > 0) {
      result.inserted++;
    } else {
      result.skipped++;
    }
  }

  static Future<void> _mergeExistingRow(
    DatabaseExecutor txn,
    SyncTableSpec spec,
    Map<String, Object?> remoteRow,
    Map<String, Object?> localRow,
    List<String> columns,
    CloudSyncMergeResult result,
  ) async {
    final updates = <String, Object?>{};
    final dataColumns = spec.dataColumns.keys
        .where(columns.contains)
        .where((c) => c != 'id')
        .toList();
    final shouldUpdateData = _shouldUpdateData(spec, remoteRow, localRow);
    var differing = false;

    for (final column in dataColumns) {
      final remoteValue = remoteRow[column];
      final localValue = localRow[column];
      if (!_valuesEqual(remoteValue, localValue)) differing = true;
      if (!shouldUpdateData) continue;
      if (column == 'created_at' &&
          _minTimestampColumns.contains(spec.entity)) {
        if (!_isEarlier(remoteValue, localValue)) continue;
      }
      updates[column] = remoteValue;
    }

    for (final counter in spec.counters.where(columns.contains)) {
      final remoteValue = (remoteRow[counter] as num?)?.toInt() ?? 0;
      final localValue = (localRow[counter] as num?)?.toInt() ?? 0;
      if (remoteValue > localValue) {
        updates[counter] = remoteValue;
      }
    }

    if (updates.isEmpty) {
      if (differing) {
        result.conflicts++;
        _recordConflict(result, spec, remoteRow, localRow, columns);
      }
      result.skipped++;
      return;
    }
    await txn.update(
      spec.table,
      updates,
      where: _whereForKeys(spec, localRow),
      whereArgs: _argsForKeys(spec, localRow),
    );
    result.updated++;
    if (differing && !shouldUpdateData) {
      result.conflicts++;
      _recordConflict(result, spec, remoteRow, localRow, columns);
    }
  }

  static void _recordConflict(
    CloudSyncMergeResult result,
    SyncTableSpec spec,
    Map<String, Object?> remoteRow,
    Map<String, Object?> localRow,
    List<String> columns,
  ) {
    if (result.conflictItems.length >= 200) return;
    final dataColumns = spec.dataColumns.keys.where(columns.contains).toList();
    final lww = spec.lwwColumn;
    result.conflictItems.add(
      SyncConflict(
        entity: spec.entity,
        key: {for (final key in spec.keyColumns.keys) key: localRow[key]},
        localData: {for (final c in dataColumns) c: localRow[c]},
        remoteData: {for (final c in dataColumns) c: remoteRow[c]},
        localTimestamp: lww == null ? null : localRow[lww] as String?,
        remoteTimestamp: lww == null ? null : remoteRow[lww] as String?,
      ),
    );
  }

  static bool _shouldUpdateData(
    SyncTableSpec spec,
    Map<String, Object?> remoteRow,
    Map<String, Object?> localRow,
  ) {
    final lww = spec.lwwColumn;
    if (lww == null) return false;
    return _isRemoteNewer(remoteRow[lww], localRow[lww]);
  }

  static bool _isRemoteNewer(Object? remote, Object? local) {
    if (local == null) return remote != null;
    final remoteTime = _parseTime(remote);
    final localTime = _parseTime(local);
    if (remoteTime != null && localTime != null) {
      return remoteTime.isAfter(localTime);
    }
    return false;
  }

  static bool _isEarlier(Object? remote, Object? local) {
    final remoteTime = _parseTime(remote);
    final localTime = _parseTime(local);
    if (remoteTime == null) return false;
    if (localTime == null) return true;
    return remoteTime.isBefore(localTime);
  }

  static DateTime? _parseTime(Object? value) {
    if (value is! String || value.isEmpty) return null;
    return DateTime.tryParse(value);
  }

  static bool _valuesEqual(Object? a, Object? b) {
    if (a is num && b is num) return a == b;
    return a == b;
  }

  static String _whereForKeys(SyncTableSpec spec, Map<String, Object?> row) {
    return spec.keyColumns.keys
        .map((key) {
          return row[key] == null ? '"$key" IS NULL' : '"$key" = ?';
        })
        .join(' AND ');
  }

  static List<Object?> _argsForKeys(
    SyncTableSpec spec,
    Map<String, Object?> row,
  ) {
    return [
      for (final key in spec.keyColumns.keys)
        if (row[key] != null) row[key],
    ];
  }
}
