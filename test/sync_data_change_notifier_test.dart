import 'package:aquamarina/services/sync_data_change_notifier.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('notifyRemoteDataChanged 递增版本并通知监听器', () {
    final notifier = SyncDataChangeNotifier.instance;
    final start = notifier.revision;
    var notified = 0;
    void listener() => notified++;

    notifier.addListener(listener);
    addTearDown(() => notifier.removeListener(listener));

    notifier.notifyRemoteDataChanged();
    notifier.notifyRemoteDataChanged();

    expect(notifier.revision, start + 2);
    expect(notified, 2);
  });
}
