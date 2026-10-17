import 'package:aquamarina/services/cloud_sync_network_service.dart';
import 'package:aquamarina/services/cloud_sync_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  CloudSyncConfig config({required bool wifiOnly}) => CloudSyncConfig.create(
    endpointInput: 'https://cn-nb1.rains3.com',
    bucket: 'aquamarina-test',
    region: 'cn-nb1',
    wifiOnly: wifiOnly,
  );

  tearDown(CloudSyncNetworkService.resetForTesting);

  test('未开启仅 Wi-Fi 时始终允许', () async {
    expect(
      await CloudSyncNetworkService.isAllowed(config(wifiOnly: false)),
      isTrue,
    );
  });

  test('开启仅 Wi-Fi 时使用注入的网络判断', () async {
    var allowed = false;
    CloudSyncNetworkService.debugAllowed = () async => allowed;
    final cfg = config(wifiOnly: true);
    expect(await CloudSyncNetworkService.isAllowed(cfg), isFalse);
    allowed = true;
    expect(await CloudSyncNetworkService.isAllowed(cfg), isTrue);
  });
}
