import 'package:aquamarina/services/cloud_sync_compatibility_service.dart';
import 'package:aquamarina/services/cloud_sync_settings.dart';
import 'package:aquamarina/services/cloud_sync_version_gate_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final gate = CloudSyncVersionGateService.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await gate.clear();
  });

  test('阻断结论写入运行时状态并发布一次提示', () async {
    final result = CloudSyncCompatibilityResult(
      level: CloudSyncCompatibilityLevel.blocked,
      reason: '设备使用 schema 20，本机为 19',
      signature: 'block-sig',
      localSchemaVersion: 19,
      localProtocolVersion: 2,
      peerDeviceName: '新设备',
      peerAppVersion: '1.5.0+25',
      peerSchemaVersion: 20,
      requiresUpgrade: true,
    );

    await gate.report(result);

    final state = await CloudSyncSettings.loadState();
    expect(state.versionBlockSignature, 'block-sig');
    expect(state.versionBlockReason, contains('schema 20'));
    expect(state.versionBlockPeerSchemaVersion, 20);
    expect(gate.notice.value?.signature, 'block-sig');

    await gate.dismiss('block-sig');
    expect(gate.notice.value, isNull);
  });

  test('升级后启动恢复会清除已失效的阻断', () async {
    await CloudSyncSettings.saveState(
      CloudSyncRuntimeState(
        versionBlockSignature: 'stale',
        versionBlockReason: '旧版本阻断',
        versionBlockPeerSchemaVersion: 18,
        versionBlockLocalSchemaVersion: 19,
        versionBlockedAt: DateTime.now(),
      ),
    );

    await gate.restore();

    expect(gate.notice.value, isNull);
    final state = await CloudSyncSettings.loadState();
    expect(state.versionBlockSignature, isNull);
  });

  test('超过 7 天的软提示启动时自动清理', () async {
    await CloudSyncSettings.saveState(
      CloudSyncRuntimeState(
        versionWarningSignature: 'old-warning',
        versionWarningMessage: '旧版本提示',
        versionWarningAt: DateTime.now().subtract(const Duration(days: 8)),
      ),
    );

    await gate.restore();

    expect(gate.notice.value, isNull);
    final state = await CloudSyncSettings.loadState();
    expect(state.versionWarningSignature, isNull);
  });
}
