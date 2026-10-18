import 'package:aquamarina/services/cloud_sync_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('首次接入决策按 datasetId 记录，且互不影响', () async {
    expect(await CloudSyncSettings.loadIntroDecision('dataset-a'), isNull);

    await CloudSyncSettings.saveIntroDecision('dataset-a', 'merge');

    final saved = await CloudSyncSettings.loadIntroDecision('dataset-a');
    expect(saved, isNotNull);
    expect(saved, contains('merge'));
    expect(await CloudSyncSettings.loadIntroDecision('dataset-b'), isNull);
  });

  test('空 datasetId 不会写入或读取决策', () async {
    await CloudSyncSettings.saveIntroDecision('', 'merge');
    expect(await CloudSyncSettings.loadIntroDecision(''), isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getKeys().where((key) => key.startsWith('cloud_sync_intro_v1:')),
      isEmpty,
    );
  });
}
