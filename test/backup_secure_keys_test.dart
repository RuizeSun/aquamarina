import 'package:aquamarina/services/data/backup_service.dart';
import 'package:aquamarina/services/tts/mimo_tts_credentials.dart';
import 'package:aquamarina/services/cloud/cloud_sync_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「清除全部数据」必须把 Ai / MiMo / 云同步的凭据全部清掉，
/// 否则用户以为清空了、系统钥匙串里仍留着 key。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('固定凭据 key 全部纳入清理范围', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();
    final keys = BackupService.knownSecureKeys(prefs);

    expect(keys, contains('ai_api_key'));
    expect(keys, contains(MimoTtsCredentials.storageKey));
    expect(keys, contains(CloudSyncSettings.accessKeyStorageKey));
    expect(keys, contains(CloudSyncSettings.secretKeyStorageKey));
  });

  test('每个 AI 配置的 key 都会被枚举', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'ai_profiles_v2': '[{"id":"p1"},{"id":"p2"}]',
    });
    final prefs = await SharedPreferences.getInstance();
    final keys = BackupService.knownSecureKeys(prefs);

    expect(keys, containsAll(['ai_api_key_p1', 'ai_api_key_p2']));
  });

  test('配置数据损坏时退回固定 key 而不抛异常', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'ai_profiles_v2': 'not-json',
    });
    final prefs = await SharedPreferences.getInstance();
    final keys = BackupService.knownSecureKeys(prefs);

    expect(keys, contains('ai_api_key'));
    expect(keys, contains(MimoTtsCredentials.storageKey));
  });
}
