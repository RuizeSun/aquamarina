import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/cloud_sync_manifest.dart';
import 'cloud_sync_service.dart';
import 'database_service.dart';

/// 新设备引导：本机没有业务数据时，自动找到云端最新快照（P2-2）。
class CloudSyncBootstrapService {
  CloudSyncBootstrapService._();

  static Future<bool> hasLocalData({Database? db}) async {
    final database = db ?? await DatabaseService.database;
    for (final table in const [
      'user_word_records',
      'word_notes',
      'sentence_notes',
      'wrong_words',
      'wrong_sentences',
      'learning_sessions',
      'sentence_sets',
      'vocab_test_history',
      'daily_activity',
    ]) {
      try {
        final rows = await database.rawQuery(
          'SELECT COUNT(*) AS c FROM "$table"',
        );
        if (((rows.first['c'] as int?) ?? 0) > 0) return true;
      } catch (_) {
        // 旧库可能缺少某些表：忽略
      }
    }
    try {
      final books = await database.rawQuery(
        'SELECT COUNT(*) AS c FROM word_books WHERE is_builtin = 0',
      );
      if (((books.first['c'] as int?) ?? 0) > 0) return true;
    } catch (_) {}
    return false;
  }

  /// 找到适合引导的共享数据集快照；没有可用快照时返回 null。
  ///
  /// v2 起云端只有一份统一数据，不再从多台设备的快照里挑选。
  /// 旧布局（按设备隔离）仍作为兼容回退。
  static Future<BootstrapCandidate?> findLatestSnapshot() async {
    final service = await CloudSyncService.create();
    final dataset = await service.fetchDatasetManifest();
    if (dataset?.latest != null) {
      return BootstrapCandidate(
        service: service,
        summary: CloudDeviceSummary(manifest: dataset!, isCurrentDevice: true),
      );
    }
    final devices = await service.listDevices();
    final chosen = chooseCandidate(devices);
    if (chosen == null) return null;
    return BootstrapCandidate(service: service, summary: chosen);
  }

  /// 选择引导快照的纯逻辑（便于测试）。
  ///
  /// 默认选择时间最新的快照，但如果最新快照明显小于另一台设备的最新快照
  /// （例如新设备先上传了一个接近空库的快照），优先选择数据更完整的那个。
  /// 体积相近时仍选最新，避免用旧的、已包含已删除数据的快照覆盖。
  static CloudDeviceSummary? chooseCandidate(
    Iterable<CloudDeviceSummary> devices,
  ) {
    CloudDeviceSummary? latest;
    CloudDeviceSummary? largest;
    for (final device in devices) {
      final snapshot = device.latest;
      if (snapshot == null) continue;
      if (latest == null ||
          snapshot.createdAt.isAfter(latest.latest!.createdAt)) {
        latest = device;
      }
      if (largest == null || snapshot.size > largest.latest!.size) {
        largest = device;
      }
    }
    if (latest == null || largest == null) return null;
    // 只有差距足够明显时才偏离「最新」：避免把正常的小体积备份误判为空库。
    return largest != latest && largest.latest!.size >= latest.latest!.size * 2
        ? largest
        : latest;
  }
}

class BootstrapCandidate {
  final CloudSyncService service;
  final CloudDeviceSummary summary;

  const BootstrapCandidate({required this.service, required this.summary});
}
