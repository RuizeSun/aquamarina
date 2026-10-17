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

  /// 找到快照最新的设备；没有可用快照时返回 null。
  static Future<BootstrapCandidate?> findLatestSnapshot() async {
    final service = await CloudSyncService.create();
    final devices = await service.listDevices();
    CloudDeviceSummary? best;
    for (final device in devices) {
      if (device.latest == null) continue;
      if (best == null ||
          device.latest!.createdAt.isAfter(best.latest!.createdAt)) {
        best = device;
      }
    }
    if (best == null) return null;
    return BootstrapCandidate(service: service, summary: best);
  }
}

class BootstrapCandidate {
  final CloudSyncService service;
  final CloudDeviceSummary summary;

  const BootstrapCandidate({required this.service, required this.summary});
}
