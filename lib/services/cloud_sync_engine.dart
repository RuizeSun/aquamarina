import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/cloud_sync_device_state.dart';
import '../models/cloud_sync_manifest.dart';
import '../models/sync_op.dart';
import 'cloud_sync_device_meta_service.dart';
import 'cloud_sync_maintenance_service.dart';
import 'cloud_sync_run_lock.dart';
import 'cloud_sync_service.dart';
import 'cloud_sync_settings.dart';
import 'database_service.dart';
import 'log_service.dart';
import 's3_storage_service.dart';
import 'sync_apply_service.dart';
import 'sync_capture_service.dart';

/// 同步进度阶段。
enum CloudSyncRunPhase { pull, push }

/// 一次增量同步的结果摘要。
class CloudSyncRunResult {
  int pushedChunks = 0;
  int pushedOps = 0;
  int pulledChunks = 0;
  int pulledOps = 0;
  int duplicates = 0;
  int conflicts = 0;
  int skippedMissingParent = 0;
  int skippedByHead = 0;
  int remainingLocalOps = 0;

  /// 本次 run 是否写入了设备水位（head / state）。
  bool stateUpdated = false;

  /// 达到时间预算，剩余工作留给下一次 run（chunk 级可恢复）。
  bool budgetExhausted = false;

  /// 调用方主动取消。
  bool cancelled = false;

  /// 本次 run 是否还有未完成/不可安全接管的工作。
  ///
  /// 用于“接管并合并旧设备”等会删除云端数据的操作：只要拉取因预算、
  /// 取消、父级缺失或任何 chunk 错误而中断，就不能删除旧设备数据。
  bool get hasIncompleteWork =>
      budgetExhausted ||
      cancelled ||
      errors.isNotEmpty ||
      skippedMissingParent > 0;

  final List<String> errors = [];
  final List<String> conflictDetails = [];

  bool get hasErrors => errors.isNotEmpty;
}

/// 增量同步编排：拉取其它设备的 chunk → 应用；再推送本机 oplog。
///
/// - chunk 不可变，键中包含首个 op 的 HLC 与内容哈希，重传天然幂等；
/// - 拉取按 HLC 字典序进行，配合行版本 / 墓碑保证乱序到达也收敛；
/// - `sync_chunks` 记录已应用 chunk，避免重复下载；
/// - 缺失父级的 chunk 不记为已应用，下次同步重试。
class CloudSyncEngine {
  final CloudSyncConfig config;
  final String deviceId;
  final String deviceName;
  final S3StorageService storage;
  final Database? _testDatabase;

  CloudSyncEngine._({
    required this.config,
    required this.deviceId,
    required this.deviceName,
    required this.storage,
    Database? database,
  }) : _testDatabase = database;

  /// 使用已保存配置创建引擎（复用 CloudSyncService 的配置与 S3 客户端）。
  static Future<CloudSyncEngine> create() async {
    final service = await CloudSyncService.create();
    return CloudSyncEngine._(
      config: service.config,
      deviceId: service.deviceId,
      deviceName: service.deviceName,
      storage: service.storage,
    );
  }

  /// 仅用于测试：注入内存数据库与假对象存储。
  factory CloudSyncEngine.forTesting({
    required CloudSyncConfig config,
    required String deviceId,
    required String deviceName,
    required S3StorageService storage,
    required Database database,
  }) {
    return CloudSyncEngine._(
      config: config,
      deviceId: deviceId,
      deviceName: deviceName,
      storage: storage,
      database: database,
    );
  }

  Future<Database> _db() async =>
      _testDatabase ?? await DatabaseService.database;

  Future<CloudSyncRunResult> run({
    bool pull = true,
    bool push = true,
    int maxPushBatches = 20,
    Duration maxDuration = const Duration(seconds: 25),
    bool Function()? isCancelled,
    void Function(CloudSyncRunPhase phase, int done, int total)? onProgress,
  }) {
    return CloudSyncRunLock.runExclusive(
      () => _run(
        pull: pull,
        push: push,
        maxPushBatches: maxPushBatches,
        maxDuration: maxDuration,
        isCancelled: isCancelled,
        onProgress: onProgress,
      ),
    );
  }

  Future<CloudSyncRunResult> _run({
    required bool pull,
    required bool push,
    required int maxPushBatches,
    required Duration maxDuration,
    bool Function()? isCancelled,
    void Function(CloudSyncRunPhase phase, int done, int total)? onProgress,
  }) async {
    final db = await _db();
    final result = CloudSyncRunResult();
    final deadline = DateTime.now().add(maxDuration);
    await _ensureBackend(db);
    await db.update('sync_meta', {
      'device_id': deviceId,
      'capture_enabled': 1,
    }, where: 'id = 1');

    final metaRows = await db.query(
      'sync_meta',
      columns: ['baseline_hlc', 'restored_watermarks'],
      where: 'id = 1',
      limit: 1,
    );
    final baseline = metaRows.isEmpty
        ? ''
        : (metaRows.first['baseline_hlc'] as String? ?? '');
    final restoredWatermarks =
        metaRows.isNotEmpty &&
        ((metaRows.first['restored_watermarks'] as int?) ?? 0) == 1;

    if (pull && !_shouldStop(result, deadline, isCancelled)) {
      await _pull(
        db,
        result,
        baseline,
        restoredWatermarks: restoredWatermarks,
        deadline: deadline,
        isCancelled: isCancelled,
        onProgress: onProgress,
      );
    }
    if (push &&
        !result.cancelled &&
        !result.budgetExhausted &&
        !_shouldStop(result, deadline, isCancelled)) {
      await _push(
        db,
        result,
        maxPushBatches,
        deadline,
        isCancelled,
        onProgress,
      );
    }
    // 即使本次没有新推送，也要补写上次失败的 head
    await _flushHead(db, result);
    // 时间预算耗尽时跳过 GC，避免把一次前台同步拖得过长。
    if (!result.budgetExhausted && !result.cancelled) {
      // 保守清理历史 chunk（内部有 7 天冷却，失败不影响同步）
      await CloudSyncMaintenanceService.maybePruneOldChunks(
        config: config,
        storage: storage,
        db: db,
      );
    }

    result.remainingLocalOps = await SyncCaptureService.pendingCount(db: db);
    try {
      final state = await CloudSyncSettings.loadState();
      if (result.errors.isEmpty) {
        await CloudSyncSettings.saveState(
          state.copyWith(lastSuccessAt: DateTime.now(), clearError: true),
        );
      } else {
        // 有 chunk 失败/损坏/缺失父级时不要伪装成成功：保留 lastError，
        // 让设置页可见，并让自动同步按失败进入退避而不是等完整间隔。
        await CloudSyncSettings.saveState(
          state.copyWith(lastError: result.errors.first),
        );
      }
    } catch (_) {
      // 状态展示失败不影响同步结果
    }
    logInfo(
      'CloudSyncEngine',
      '增量同步完成：pull=${result.pulledChunks} chunks / '
          '${result.pulledOps} ops（跳过 ${result.skippedByHead} 个无变化设备），'
          'push=${result.pushedChunks} chunks / '
          '${result.pushedOps} ops，pending=${result.remainingLocalOps}，'
          'conflicts=${result.conflicts}',
    );
    return result;
  }

  CloudSyncDeviceMetaService get _meta =>
      CloudSyncDeviceMetaService(config: config, storage: storage);

  /// 配置（endpoint / bucket / prefix 等）切换后，旧后端的同步水位、
  /// 已应用记录、行版本与墓碑都不再适用。保留 oplog（本地待上传变更）
  /// 与设备标识，但清空后端相关的运行时状态，避免 `startAfter` 使用旧键、
  /// `sync_applied` 误判重复或旧 HLC 门禁跳过新数据。
  Future<void> _ensureBackend(Database db) async {
    final identity = config.backendIdentity;
    final rows = await db.query(
      'sync_meta',
      columns: ['backend_id'],
      where: 'id = 1',
      limit: 1,
    );
    final current = rows.isEmpty
        ? ''
        : (rows.first['backend_id'] as String? ?? '');
    if (current == identity) return;
    await db.transaction((txn) async {
      if (current.isNotEmpty) {
        await _saveBackendWatermarks(txn, current);
        await txn.delete('sync_state');
        await txn.delete('sync_chunks');
        await txn.delete('sync_applied');
        await txn.delete('sync_row_versions');
        await txn.delete('sync_tombstones');
        await txn.delete('sync_conflicts');
        logWarning('CloudSyncEngine', '检测到对象存储配置已切换，已清理旧后端的同步水位与去重记录');
        final restored = await _restoreBackendWatermarks(txn, identity);
        await txn.update('sync_meta', {
          'backend_id': identity,
          'baseline_hlc': '',
          'restored_watermarks': restored ? 1 : 0,
          'head_hlc': '',
          'head_key': '',
          'head_chunk_count': 0,
          'head_dirty': 0,
          'total_ops': 0,
        }, where: 'id = 1');
      } else {
        // 首次记录后端身份（含从旧版本升级）：保留现有水位与恢复基线。
        await txn.update('sync_meta', {
          'backend_id': identity,
        }, where: 'id = 1');
      }
    });
  }

  /// 离开一个后端前，把它当前的应用水位存到本地缓存。
  ///
  /// 只保存 `sync_state`（外加本机 head），不保存 `sync_applied` /
  /// `sync_row_versions`；切回来时靠 HLC 水位跳过历史 chunk，不再重新应用。
  Future<void> _saveBackendWatermarks(
    DatabaseExecutor txn,
    String backendId,
  ) async {
    final byDevice = <String, Map<String, String?>>{};
    final stateRows = await txn.query(
      'sync_state',
      columns: ['device_id', 'last_hlc', 'last_chunk_key'],
    );
    for (final row in stateRows) {
      final device = row['device_id'];
      final hlc = row['last_hlc'];
      if (device is! String ||
          device.isEmpty ||
          hlc is! String ||
          hlc.isEmpty) {
        continue;
      }
      byDevice[device] = {
        'last_hlc': hlc,
        'last_chunk_key': row['last_chunk_key'] as String?,
      };
    }
    final metaRows = await txn.query(
      'sync_meta',
      columns: ['device_id', 'head_hlc', 'head_key'],
      where: 'id = 1',
      limit: 1,
    );
    if (metaRows.isNotEmpty) {
      final row = metaRows.first;
      final ownId = row['device_id'] as String? ?? '';
      final headHlc = row['head_hlc'] as String? ?? '';
      if (ownId.isNotEmpty && headHlc.isNotEmpty) {
        final existing = byDevice[ownId]?['last_hlc'];
        if (existing == null || headHlc.compareTo(existing) > 0) {
          byDevice[ownId] = {
            'last_hlc': headHlc,
            'last_chunk_key': row['head_key'] as String?,
          };
        }
      }
    }
    if (byDevice.isEmpty) return;
    final now = DateTime.now().toUtc().toIso8601String();
    final batch = txn.batch();
    for (final entry in byDevice.entries) {
      batch.insert('sync_backend_watermarks', {
        'backend_id': backendId,
        'device_id': entry.key,
        'last_hlc': entry.value['last_hlc'],
        'last_chunk_key': entry.value['last_chunk_key'],
        'saved_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  /// 切回一个用过的后端时，恢复它上次离开时的来源水位。
  Future<bool> _restoreBackendWatermarks(
    DatabaseExecutor txn,
    String backendId,
  ) async {
    final rows = await txn.query(
      'sync_backend_watermarks',
      where: 'backend_id = ?',
      whereArgs: [backendId],
    );
    if (rows.isEmpty) return false;
    final now = DateTime.now().toUtc().toIso8601String();
    final batch = txn.batch();
    var restored = false;
    for (final row in rows) {
      final device = row['device_id'];
      final hlc = row['last_hlc'];
      if (device is! String || device.isEmpty || hlc is! String) continue;
      try {
        SyncHlc.parse(hlc);
      } on FormatException {
        continue;
      }
      batch.insert('sync_state', {
        'device_id': device,
        'last_seq': 0,
        'last_hlc': hlc,
        'last_chunk_key': row['last_chunk_key'],
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      restored = true;
    }
    if (restored) await batch.commit(noResult: true);
    return restored;
  }

  Future<void> _pull(
    Database db,
    CloudSyncRunResult result,
    String baseline, {
    required bool restoredWatermarks,
    required DateTime deadline,
    bool Function()? isCancelled,
    void Function(CloudSyncRunPhase phase, int done, int total)? onProgress,
  }) async {
    final allDeviceIds = await _meta.listDeviceIds();
    // 重置设备标识后，旧设备目录仍留在云端；本机数据已经包含这些变更，
    // 不能再把它们当作其它设备重放（否则计数类字段会翻倍）。把旧 ID 的
    // head 水位记录到本地 state，既跳过拉取，也让 GC 能继续回收旧 chunk。
    final ignoredDeviceIds = await CloudSyncSettings.loadIgnoredDeviceIds();
    for (final ignored in allDeviceIds.where(ignoredDeviceIds.contains)) {
      await _rememberIgnoredDevice(db, ignored);
    }
    final deviceIds = allDeviceIds
        .where((id) => !ignoredDeviceIds.contains(id))
        .toList();
    if (deviceIds.isEmpty) {
      await _flushState(db, result);
      return;
    }

    final appliedRows = await db.query('sync_chunks', columns: ['chunk_key']);
    final appliedKeys = {
      for (final row in appliedRows) row['chunk_key'] as String,
    };

    for (final sourceDevice in deviceIds) {
      final isOwn = sourceDevice == deviceId;
      // 旧格式恢复只有 baseline；新格式恢复会写入来源水位，本机也按水位
      // 只补齐快照之后上传的 chunk。
      if (isOwn && baseline.isEmpty && !restoredWatermarks) continue;

      final stateRows = await db.query(
        'sync_state',
        where: 'device_id = ?',
        whereArgs: [sourceDevice],
        limit: 1,
      );
      final state = stateRows.isEmpty ? null : stateRows.first;
      final lastKey = (state?['last_chunk_key'] as String?) ?? '';
      final lastHlc = (state?['last_hlc'] as String?) ?? '';

      // head 快速路径对本机同样适用：恢复水位已经明确了本机进度时，
      // 不必每轮都 LIST 自己的全部 chunk。
      final head = await _meta.fetchHead(sourceDevice);
      if (head != null &&
          lastHlc.isNotEmpty &&
          _compareHlc(head.latestHlc, lastHlc) <= 0) {
        result.skippedByHead++;
        continue;
      }

      final objects = await storage.list(
        '${config.devicePrefix(sourceDevice)}/chunks/',
        recursive: true,
        startAfter: lastKey.isEmpty ? null : lastKey,
      );
      final candidates =
          objects
              .where((o) => _isChunkKey(o.key))
              .where((o) => !appliedKeys.contains(o.key))
              .where(
                (o) => _includeForRestore(
                  o.key,
                  lastHlc,
                  baseline,
                  restoredWatermarks: restoredWatermarks,
                ),
              )
              .toList()
            ..sort((a, b) => a.key.compareTo(b.key));
      if (candidates.isEmpty) continue;

      var lastGoodKey = lastKey;
      var lastGoodHlc = lastHlc;
      var blocked = false;

      for (final object in candidates) {
        if (_shouldStop(result, deadline, isCancelled)) break;
        final outcome = await _applyChunk(
          db,
          object.key,
          result,
          sourceDevice,
          deadline: deadline,
          isCancelled: isCancelled,
        );
        onProgress?.call(
          CloudSyncRunPhase.pull,
          result.pulledChunks,
          candidates.length,
        );
        if (outcome == null) {
          blocked = true;
          continue;
        }
        if (!blocked) {
          lastGoodKey = object.key;
          lastGoodHlc = outcome;
        }
      }

      // 只有连续成功的前缀才推进水位；中间失败时保留旧位置，下次重试。
      if (lastGoodKey.isNotEmpty && lastGoodKey != lastKey) {
        await _saveSyncState(
          db,
          sourceDevice: sourceDevice,
          lastHlc: lastGoodHlc,
          lastChunkKey: lastGoodKey,
        );
        result.stateUpdated = true;
      }
      if (result.budgetExhausted || result.cancelled) break;
    }

    // 每次成功拉取后都尝试发布 state：即使用户删除了 state.json，
    // 或本地 sync_state 已存在但云端水位缺失，也能自愈。
    await _flushState(db, result);
  }

  /// 应用单个 chunk；成功返回起始 HLC，失败（或缺失父级）返回 null。
  Future<String?> _applyChunk(
    Database db,
    String key,
    CloudSyncRunResult result,
    String sourceDevice, {
    required DateTime deadline,
    bool Function()? isCancelled,
  }) async {
    try {
      final bytes = await storage.getBytes(
        key,
        maxBytes: 8 * 1024 * 1024,
        nullIfMissing: true,
      );
      if (bytes == null) return null;
      final sha = CloudSyncUtils.sha256Hex(bytes);
      if (!_hashMatches(key, sha)) {
        result.errors.add('chunk 哈希校验失败：$key');
        return null;
      }
      final ops = SyncChunkCodec.decodeAuto(bytes);
      final bounds = _hlcBounds(key, ops);
      final apply = await SyncApplyService.applyOps(
        ops,
        db: db,
        deadline: deadline,
        isCancelled: isCancelled,
      );
      result.pulledOps += ops.length;
      if (apply.deferred) {
        result.budgetExhausted = !apply.cancelled;
        result.cancelled = apply.cancelled;
        result.conflicts += apply.conflicts;
        result.duplicates += apply.duplicates;
        result.skippedMissingParent += apply.skippedMissingParent;
        if (result.conflictDetails.length < 20) {
          result.conflictDetails.addAll(
            apply.conflictDetails.take(20 - result.conflictDetails.length),
          );
        }
        // 当前 chunk 未完整应用，不写 sync_chunks / 水位，下次重试。
        return null;
      }
      result.duplicates += apply.duplicates;
      result.conflicts += apply.conflicts;
      result.skippedMissingParent += apply.skippedMissingParent;
      if (result.conflictDetails.length < 20) {
        result.conflictDetails.addAll(
          apply.conflictDetails.take(20 - result.conflictDetails.length),
        );
      }
      if (apply.skippedMissingParent > 0) {
        result.errors.add('chunk 存在缺失父级，将在下次同步重试：$key');
        return null;
      }
      await db.insert('sync_chunks', {
        'device_id': sourceDevice,
        'chunk_key': key,
        'sha256': sha,
        'min_hlc': bounds.$1,
        'max_hlc': bounds.$2,
        'applied_at': DateTime.now().toUtc().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      result.pulledChunks++;
      return bounds.$1;
    } catch (e) {
      result.errors.add('拉取 $key 失败：$e');
      return null;
    }
  }

  /// 已重置的旧设备 ID：只记录其最新水位，不再拉取/应用它的 chunk。
  ///
  /// 这些 chunk 的内容已经包含在本机数据库里（重置设备标识不会清库）。
  /// 记录水位后 `_flushState` 会把它发布到 state.json，避免旧目录永久
  /// 阻塞其它设备的 chunk GC。
  Future<void> _rememberIgnoredDevice(
    Database db,
    String ignoredDeviceId,
  ) async {
    final head = await _meta.fetchHead(ignoredDeviceId);
    if (head == null || head.latestHlc.isEmpty) return;
    final stateRows = await db.query(
      'sync_state',
      where: 'device_id = ?',
      whereArgs: [ignoredDeviceId],
      limit: 1,
    );
    final existing = stateRows.isEmpty
        ? ''
        : (stateRows.first['last_hlc'] as String? ?? '');
    if (existing.isNotEmpty && _compareHlc(head.latestHlc, existing) <= 0) {
      return;
    }
    await _saveSyncState(
      db,
      sourceDevice: ignoredDeviceId,
      lastHlc: head.latestHlc,
      lastChunkKey: head.latestChunkKey,
    );
  }

  Future<void> _saveSyncState(
    Database db, {
    required String sourceDevice,
    required String lastHlc,
    required String lastChunkKey,
  }) async {
    await db.insert('sync_state', {
      'device_id': sourceDevice,
      'last_seq': 0,
      'last_hlc': lastHlc.isEmpty ? null : lastHlc,
      'last_chunk_key': lastChunkKey,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 把本机已应用到其它设备的水位发布到 `state.json`。
  Future<void> _flushState(Database db, CloudSyncRunResult result) async {
    final rows = await db.query(
      'sync_state',
      where: 'device_id != ?',
      whereArgs: [deviceId],
    );
    final applied = <String, String>{};
    for (final row in rows) {
      final source = row['device_id'];
      final hlc = row['last_hlc'];
      if (source is String &&
          source.isNotEmpty &&
          hlc is String &&
          hlc.isNotEmpty) {
        applied[source] = hlc;
      }
    }
    if (applied.isEmpty) return;

    try {
      final existing = await _meta.fetchState(deviceId);
      final unchanged =
          existing != null && _sameApplied(existing.applied, applied);
      if (unchanged &&
          DateTime.now().difference(existing.updatedAt) <
              const Duration(hours: 24)) {
        return;
      }
      await _meta.saveState(
        CloudDeviceState(
          deviceId: deviceId,
          deviceName: deviceName,
          applied: applied,
          updatedAt: DateTime.now(),
        ),
      );
      result.stateUpdated = true;
    } catch (e) {
      result.errors.add('上传设备同步状态失败：$e');
    }
  }

  bool _sameApplied(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  /// 上传成功后补写本机 head；失败时保留 `head_dirty`，下次同步重试。
  Future<void> _flushHead(Database db, CloudSyncRunResult result) async {
    final rows = await db.query(
      'sync_meta',
      columns: ['head_hlc', 'head_key', 'head_chunk_count', 'head_dirty'],
      where: 'id = 1',
      limit: 1,
    );
    if (rows.isEmpty) return;
    final row = rows.first;
    final dirty = ((row['head_dirty'] as int?) ?? 0) == 1;
    final hlc = (row['head_hlc'] as String?) ?? '';
    final key = (row['head_key'] as String?) ?? '';
    if (!dirty || hlc.isEmpty || key.isEmpty) return;

    final head = CloudDeviceHead(
      deviceId: deviceId,
      deviceName: deviceName,
      latestChunkKey: key,
      latestHlc: hlc,
      chunkCount: (row['head_chunk_count'] as int?) ?? 0,
      updatedAt: DateTime.now(),
    );
    try {
      await _meta.saveHead(head);
      await db.update('sync_meta', {'head_dirty': 0}, where: 'id = 1');
    } catch (e) {
      result.errors.add('上传设备 head 失败：$e');
    }
  }

  Future<void> _push(
    Database db,
    CloudSyncRunResult result,
    int maxPushBatches,
    DateTime deadline,
    bool Function()? isCancelled,
    void Function(CloudSyncRunPhase phase, int done, int total)? onProgress,
  ) async {
    for (var i = 0; i < maxPushBatches; i++) {
      if (_shouldStop(result, deadline, isCancelled)) break;
      final batch = await SyncCaptureService.takePendingBatch(
        db: db,
        deviceId: deviceId,
      );
      if (batch == null) break;
      final key = _chunkKey(batch);
      try {
        await storage.putBytes(key, batch.bytes);
      } catch (e) {
        result.errors.add('上传 chunk 失败：$e');
        break;
      }
      await SyncCaptureService.markUploaded(
        batch,
        db: db,
        ownChunkDeviceId: deviceId,
        ownChunkKey: key,
      );
      result.pushedChunks++;
      result.pushedOps += batch.ops.length;
      onProgress?.call(
        CloudSyncRunPhase.push,
        result.pushedChunks,
        maxPushBatches,
      );
      await _markHeadDirty(db, key, batch.ops.first.hlc);
    }
  }

  /// 检查取消标记与时间预算；命中时写入结果并返回 true。
  bool _shouldStop(
    CloudSyncRunResult result,
    DateTime deadline,
    bool Function()? isCancelled,
  ) {
    if (isCancelled?.call() ?? false) {
      result.cancelled = true;
      return true;
    }
    if (!DateTime.now().isBefore(deadline)) {
      result.budgetExhausted = true;
      return true;
    }
    return false;
  }

  /// 记录本机最新 chunk，供本次 run 末尾写 `head.json`。
  Future<void> _markHeadDirty(Database db, String key, SyncHlc hlc) async {
    final rows = await db.query(
      'sync_meta',
      columns: ['head_chunk_count'],
      where: 'id = 1',
      limit: 1,
    );
    final previous = rows.isEmpty
        ? 0
        : ((rows.first['head_chunk_count'] as int?) ?? 0);
    await db.update('sync_meta', {
      'head_hlc': hlc.value,
      'head_key': key,
      'head_chunk_count': previous + 1,
      'head_dirty': 1,
    }, where: 'id = 1');
  }

  /// chunk 键包含首个 op 的 HLC，便于按时间顺序拉取。
  String _chunkKey(SyncBatch batch) {
    final first = batch.ops.first;
    final hlc = first.hlc.value.replaceAll(':', '-');
    return '${config.devicePrefix(deviceId)}/chunks/$hlc-'
        '${batch.sha256}.jsonl.gz';
  }

  bool _isChunkKey(String key) =>
      key.endsWith('.jsonl') || key.endsWith('.jsonl.gz');

  /// 校验文件名中的哈希。新 chunk 使用完整 64 位，旧 chunk 仍支持前 16 位。
  bool _hashMatches(String key, String actualSha) {
    final name = key.split('/').last;
    final match = RegExp(
      r'-([0-9a-f]{64}|[0-9a-f]{16})\.jsonl(?:\.gz)?$',
    ).firstMatch(name);
    if (match == null) return false;
    final expected = match.group(1)!;
    if (expected.length == 64) return actualSha == expected;
    return actualSha.startsWith(expected);
  }

  /// 返回 chunk 内 op 的 HLC 范围；空 chunk 退回对象键的起始 HLC。
  (String, String) _hlcBounds(String key, List<SyncOp> ops) {
    final fallback = _chunkStartHlc(key)?.value ?? '';
    if (ops.isEmpty) return (fallback, fallback);
    var min = ops.first.hlc;
    var max = ops.first.hlc;
    for (final op in ops) {
      if (op.hlc.compareTo(min) < 0) min = op.hlc;
      if (op.hlc.compareTo(max) > 0) max = op.hlc;
    }
    return (min.value, max.value);
  }

  /// chunk 键形如 `chunks/{msHex}-{counterHex}-{sha}.jsonl`。
  SyncHlc? _chunkStartHlc(String key) {
    final name = key.split('/').last;
    final parts = name.split('-');
    if (parts.length < 2) return null;
    final ms = int.tryParse(parts[0], radix: 16);
    final counter = int.tryParse(parts[1], radix: 16);
    if (ms == null || counter == null) return null;
    return SyncHlc(ms, counter);
  }

  int _compareHlc(String a, String b) {
    try {
      return SyncHlc.parse(a).compareTo(SyncHlc.parse(b));
    } on FormatException {
      // 无法解析时视为“有更新”，强制走一次受控 LIST。
      return 1;
    }
  }

  /// 恢复快照后决定某个 chunk 是否需要拉取。
  ///
  /// - 新格式（[restoredWatermarks]）：按来源设备水位精确过滤，水位之前
  ///   的 chunk 已包含在快照里；
  /// - 旧格式：退回全局 baseline（快照创建时间）。
  bool _includeForRestore(
    String key,
    String lastHlc,
    String baseline, {
    required bool restoredWatermarks,
  }) {
    if (restoredWatermarks) {
      if (lastHlc.isEmpty) return true;
      final start = _chunkStartHlc(key);
      if (start == null) return true;
      return _compareHlc(start.value, lastHlc) > 0;
    }
    return !_isAtOrBeforeBaseline(key, baseline);
  }

  /// 备份恢复后，基线之前的 chunk 已包含在快照中，应跳过以免重复计数。
  bool _isAtOrBeforeBaseline(String key, String baseline) {
    if (baseline.isEmpty) return false;
    final start = _chunkStartHlc(key);
    if (start == null) return false;
    try {
      return start.compareTo(SyncHlc.parse(baseline)) <= 0;
    } on FormatException {
      return false;
    }
  }
}
