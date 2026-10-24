import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../models/cloud_sync_manifest.dart';
import 'cloud_sync_bootstrap_service.dart';
import 'cloud_sync_compatibility_service.dart';
import 'cloud_sync_engine.dart';
import 'cloud_sync_merge_service.dart';
import 'cloud_sync_run_lock.dart';
import 'cloud_sync_service.dart';
import 'cloud_sync_settings.dart';
import 'cloud_sync_version_gate_service.dart';
import '../data/database_service.dart';
import '../system/log_service.dart';
import 'sync_data_change_notifier.dart';
import 'sync_schema.dart';

/// 首次接入时用户选择的数据处理方式。
enum CloudSyncIntroAction { merge, keepLocal, useCloud }

extension CloudSyncIntroActionName on CloudSyncIntroAction {
  String get storageValue => switch (this) {
    CloudSyncIntroAction.merge => 'merge',
    CloudSyncIntroAction.keepLocal => 'keep_local',
    CloudSyncIntroAction.useCloud => 'use_cloud',
  };

  String get label => switch (this) {
    CloudSyncIntroAction.merge => '合并',
    CloudSyncIntroAction.keepLocal => '以本机为准',
    CloudSyncIntroAction.useCloud => '以云端为准',
  };
}

/// 首次接入状态。
class CloudSyncIntroState {
  final bool localHasData;
  final bool cloudHasData;
  final String? datasetId;
  final String? decision;

  const CloudSyncIntroState({
    required this.localHasData,
    required this.cloudHasData,
    this.datasetId,
    this.decision,
  });

  bool get needsDecision =>
      localHasData && cloudHasData && datasetId != null && decision == null;
}

/// 统一数据集的首次接入编排。
///
/// - 本机为空：不需要选择，正常引导/增量即可；
/// - 本机已有数据 + 云端已有数据 + 尚未选择：询问一次；
/// - 每台设备、每个 datasetId 只问一次。
class CloudSyncIntroductionService {
  CloudSyncIntroductionService._();

  static Future<CloudSyncIntroState> inspect({Database? db}) async {
    var localHasData = false;
    try {
      localHasData = await CloudSyncBootstrapService.hasLocalData(db: db);
    } catch (_) {
      localHasData = false;
    }
    if (!localHasData) {
      return const CloudSyncIntroState(
        localHasData: false,
        cloudHasData: false,
      );
    }

    CloudSyncService service;
    try {
      service = await CloudSyncService.create();
    } catch (_) {
      return const CloudSyncIntroState(localHasData: true, cloudHasData: false);
    }
    final manifest = await service.fetchDatasetManifest();
    final datasetId = manifest?.deviceId;
    final cloudHasData = manifest?.latest != null;
    if (!cloudHasData || datasetId == null || datasetId.isEmpty) {
      return CloudSyncIntroState(
        localHasData: true,
        cloudHasData: cloudHasData,
        datasetId: datasetId,
      );
    }
    final decision = await CloudSyncSettings.loadIntroDecision(datasetId);
    return CloudSyncIntroState(
      localHasData: true,
      cloudHasData: true,
      datasetId: datasetId,
      decision: decision,
    );
  }

  /// 本机是否已经把自己的数据合并进该数据集。
  ///
  /// 旧版清单没有 `contributors` 字段，退化为从快照 key 反推上传者。
  /// 已经贡献过数据的设备再次合并时不需要上传/更换 datasetId，
  /// 否则两端会互相把对方重新变成“未确认”状态，形成确认循环。
  static bool hasContributed(CloudDeviceManifest? manifest, String deviceId) {
    if (manifest == null || deviceId.isEmpty) return false;
    final contributors = manifest.contributors.isNotEmpty
        ? manifest.contributors.toSet()
        : CloudSyncUtils.snapshotContributorIds(manifest.snapshots);
    return contributors.contains(deviceId);
  }

  /// 执行用户选择。整个过程在全局同步锁内串行完成。
  static Future<CloudSyncMergeResult?> apply(
    CloudSyncIntroAction action, {
    void Function(String message)? onProgress,
    void Function(int done, int total)? onMergeProgress,
  }) async {
    if (!await CloudSyncSettings.hasCompleteConfiguration()) {
      throw const CloudSyncException('尚未完成云同步配置');
    }
    return CloudSyncRunLock.runExclusive(() async {
      final service = await CloudSyncService.create();
      final manifest = await service.fetchDatasetManifest();
      final datasetId = manifest?.deviceId ?? '';
      if (datasetId.isEmpty || manifest?.latest == null) {
        throw const CloudSyncException('云端还没有可用数据');
      }

      final appVersion = await CloudSyncCompatibilityService.localAppVersion();
      final compatibility = await CloudSyncCompatibilityService.evaluate(
        config: service.config,
        storage: service.storage,
        localDeviceId: service.deviceId,
        localAppVersion: appVersion,
      );
      if (compatibility.isBlocked) {
        await CloudSyncVersionGateService.instance.report(compatibility);
        throw CloudSyncIncompatibleException(
          compatibility.reason,
          requiredSchemaVersion: compatibility.peerSchemaVersion,
          requiredProtocolVersion: compatibility.peerProtocolVersion,
        );
      }
      if (compatibility.isSoftWarning) {
        await CloudSyncVersionGateService.instance.report(compatibility);
      } else {
        await CloudSyncVersionGateService.instance.clear();
      }

      switch (action) {
        case CloudSyncIntroAction.merge:
          final alreadyContributed = hasContributed(manifest, service.deviceId);
          onProgress?.call('正在下载云端数据…');
          final file = await service.downloadLatestDatasetSnapshot();
          try {
            onProgress?.call('正在合并两端数据…');
            final result = await CloudSyncMergeService.mergeBackupFile(
              file,
              onProgress: onMergeProgress,
            );
            final db = await DatabaseService.database;
            await SyncSchema.adoptSnapshotWatermarks(
              db,
              watermarks: result.watermarks,
              baseline: result.snapshotCreatedAt ?? manifest!.latest!.createdAt,
              backendId: service.config.backendIdentity,
            );
            if (alreadyContributed) {
              // 本机历史数据已经在云端快照里，合并后不需要换 datasetId；
              // 否则另一端会因为 datasetId 变化再次确认，两端来回换 ID。
              onProgress?.call('正在保存合并结果…');
              await CloudSyncSettings.saveIntroDecision(
                datasetId,
                action.storageValue,
              );
              logInfo('CloudSyncIntro', '本机已贡献该数据集，合并后保持 datasetId=$datasetId');
            } else {
              onProgress?.call('正在上传合并后的云端数据…');
              await service.uploadSnapshot(
                includeApiKeys: false,
                startNewDataset: true,
              );
              final updated = await service.fetchDatasetManifest();
              await CloudSyncSettings.saveIntroDecision(
                updated?.deviceId ?? datasetId,
                action.storageValue,
              );
            }
            logInfo(
              'CloudSyncIntro',
              '合并完成 inserted=${result.inserted} '
                  'updated=${result.updated} conflicts=${result.conflicts}',
            );
            if (result.inserted > 0 || result.updated > 0) {
              SyncDataChangeNotifier.instance.notifyRemoteDataChanged();
            }
            return result;
          } finally {
            if (await file.exists()) await file.delete();
          }

        case CloudSyncIntroAction.keepLocal:
          onProgress?.call('正在以本机数据建立云端基线…');
          final db = await DatabaseService.database;
          await SyncSchema.resetForNewBaseline(
            db,
            cutoff: DateTime.now().toUtc(),
            backendId: service.config.backendIdentity,
          );
          await service.uploadSnapshot(
            includeApiKeys: false,
            startNewDataset: true,
            resetContributors: true,
          );
          final updated = await service.fetchDatasetManifest();
          await CloudSyncSettings.saveIntroDecision(
            updated?.deviceId ?? datasetId,
            action.storageValue,
          );
          logInfo('CloudSyncIntro', '已用本机数据替换云端数据集');
          return null;

        case CloudSyncIntroAction.useCloud:
          onProgress?.call('正在使用云端数据覆盖本机…');
          await service.restoreLatestDatasetSnapshot();
          // 快照覆盖后业务表已经变化，即使后续增量没有新 chunk，也要刷新 UI。
          SyncDataChangeNotifier.instance.notifyRemoteDataChanged();
          await CloudSyncSettings.saveIntroDecision(
            datasetId,
            action.storageValue,
          );
          onProgress?.call('正在同步最新变更…');
          final engine = await CloudSyncEngine.create();
          final result = await engine.run();
          if (result.hasErrors) {
            logWarning('CloudSyncIntro', '覆盖后增量同步有告警：${result.errors.first}');
          }
          logInfo('CloudSyncIntro', '已使用云端数据覆盖本机');
          return null;
      }
    });
  }
}
