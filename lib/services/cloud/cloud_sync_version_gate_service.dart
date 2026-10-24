import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/sync_op.dart';
import 'cloud_sync_compatibility_service.dart';
import 'cloud_sync_settings.dart';
import '../data/database_service.dart';

/// 把版本兼容结论同步到设置页状态，并驱动主界面的弹窗。
///
/// 后台服务没有 BuildContext，因此这里只发布 [notice]；
/// `MainShell` 监听后负责展示一次（按 signature 去重）。
class CloudSyncVersionGateService {
  CloudSyncVersionGateService._();

  static final CloudSyncVersionGateService instance =
      CloudSyncVersionGateService._();

  static const String _dismissedKey = 'cloud_sync_version_dismissed_v1';

  final ValueNotifier<CloudSyncCompatibilityResult?> notice =
      ValueNotifier<CloudSyncCompatibilityResult?>(null);

  String? _dismissedSignature;
  bool _dismissedLoaded = false;

  Future<void> report(CloudSyncCompatibilityResult result) async {
    if (result.isCompatible) {
      await clear();
      return;
    }
    final current = await CloudSyncSettings.loadState();
    final unchanged = result.isBlocked
        ? current.versionBlockSignature == result.signature &&
              current.versionWarningSignature == null
        : current.versionWarningSignature == result.signature &&
              current.versionBlockSignature == null;
    if (!unchanged) {
      await CloudSyncSettings.updateState((state) {
        if (result.isBlocked) {
          return state.copyWith(
            versionBlockSignature: result.signature,
            versionBlockReason: result.reason,
            versionBlockPeerName: result.peerDeviceName,
            versionBlockPeerVersion: result.peerAppVersion,
            versionBlockPeerSchemaVersion: result.peerSchemaVersion,
            versionBlockPeerProtocolVersion: result.peerProtocolVersion,
            versionBlockLocalSchemaVersion: result.localSchemaVersion,
            versionBlockLocalProtocolVersion: result.localProtocolVersion,
            versionBlockedAt: DateTime.now(),
            clearVersionWarning: true,
          );
        }
        return state.copyWith(
          versionWarningSignature: result.signature,
          versionWarningMessage: result.reason,
          versionWarningAt: DateTime.now(),
          clearVersionBlock: true,
        );
      });
    }
    if (!await _isDismissed(result.signature)) {
      notice.value = result;
    }
  }

  Future<void> clear() async {
    final current = await CloudSyncSettings.loadState();
    if (current.versionBlockSignature == null &&
        current.versionWarningSignature == null) {
      notice.value = null;
      return;
    }
    await CloudSyncSettings.updateState((state) {
      return state.copyWith(clearVersionBlock: true, clearVersionWarning: true);
    });
    notice.value = null;
    if (_dismissedSignature != null) {
      _dismissedSignature = null;
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_dismissedKey);
      } catch (_) {
        // 清理失败只会让后续同类提示不再弹出，不影响同步。
      }
    }
  }

  Future<void> dismiss(String signature) async {
    _dismissedSignature = signature;
    _dismissedLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_dismissedKey, signature);
    } catch (_) {
      // 去重失败最多导致下次再提示一次，不影响同步。
    }
    notice.value = null;
  }

  /// 启动时恢复上一次的提示（新版本升级后不会显示已经失效的阻断）。
  Future<void> restore() async {
    final state = await CloudSyncSettings.loadState();
    final now = DateTime.now();
    if (state.versionBlockSignature != null) {
      final peerSchema = state.versionBlockPeerSchemaVersion;
      final peerProtocol = state.versionBlockPeerProtocolVersion;
      final localSchema =
          state.versionBlockLocalSchemaVersion ?? DatabaseService.schemaVersion;
      final localProtocol =
          state.versionBlockLocalProtocolVersion ?? SyncOp.currentVersion;
      final reason = state.versionBlockReason ?? '';
      final stillIncompatible =
          (peerSchema != null && peerSchema > localSchema) ||
          (peerProtocol != null && peerProtocol > localProtocol) ||
          reason.contains('格式') ||
          (peerProtocol == null && reason.contains('协议'));
      if (!stillIncompatible) {
        await clear();
        return;
      }
      if (await _isDismissed(state.versionBlockSignature!)) return;
      notice.value = CloudSyncCompatibilityResult(
        level: CloudSyncCompatibilityLevel.blocked,
        reason: reason,
        signature: state.versionBlockSignature!,
        localSchemaVersion: localSchema,
        localProtocolVersion: localProtocol,
        peerDeviceName: state.versionBlockPeerName,
        peerAppVersion: state.versionBlockPeerVersion,
        peerSchemaVersion: peerSchema,
        peerProtocolVersion: peerProtocol,
        requiresUpgrade: true,
      );
      return;
    }
    final warningSignature = state.versionWarningSignature;
    final warningAt = state.versionWarningAt;
    if (warningSignature == null || warningAt == null) return;
    if (now.difference(warningAt) > const Duration(days: 7)) {
      await clear();
      return;
    }
    if (await _isDismissed(warningSignature)) return;
    notice.value = CloudSyncCompatibilityResult(
      level: CloudSyncCompatibilityLevel.softWarning,
      reason: state.versionWarningMessage ?? '',
      signature: warningSignature,
      localSchemaVersion: DatabaseService.schemaVersion,
      localProtocolVersion: SyncOp.currentVersion,
    );
  }

  Future<bool> _isDismissed(String signature) async {
    if (!_dismissedLoaded) {
      _dismissedLoaded = true;
      try {
        final prefs = await SharedPreferences.getInstance();
        _dismissedSignature = prefs.getString(_dismissedKey);
      } catch (_) {
        _dismissedSignature = null;
      }
    }
    return _dismissedSignature == signature;
  }
}
