import 'package:aquamarina/services/data/learning_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const today = '2026-11-21';
  const tomorrow = '2026-11-22';

  group('nextWrongWordSchedule', () {
    test('首次答错排到今天且计数为 0', () {
      final schedule = LearningService.nextWrongWordSchedule(
        currentScheduledDate: null,
        today: today,
        tomorrow: tomorrow,
      );
      expect(schedule.scheduledDate, today);
      expect(schedule.retryCount, 0);
    });

    test('当天内重试累加计数', () {
      final schedule = LearningService.nextWrongWordSchedule(
        currentScheduledDate: today,
        currentRetryCount: 0,
        today: today,
        tomorrow: tomorrow,
      );
      expect(schedule.scheduledDate, today);
      expect(schedule.retryCount, 1);
    });

    test('达到上限后顺延到明天并清零', () {
      final schedule = LearningService.nextWrongWordSchedule(
        currentScheduledDate: today,
        currentRetryCount: LearningService.maxWrongWordRetriesPerDay - 1,
        today: today,
        tomorrow: tomorrow,
      );
      expect(schedule.scheduledDate, tomorrow);
      expect(schedule.retryCount, 0);
    });

    test('之前排期不是今天就重新从今天计数', () {
      final schedule = LearningService.nextWrongWordSchedule(
        currentScheduledDate: '2026-11-20',
        currentRetryCount: 5,
        today: today,
        tomorrow: tomorrow,
      );
      expect(schedule.scheduledDate, today);
      expect(schedule.retryCount, 0);
    });

    test('连续答错最终会在有限次数内离开今日队列', () {
      var scheduledDate = today;
      var retryCount = 0;
      var escaped = false;
      for (var i = 0; i < 10; i++) {
        final schedule = LearningService.nextWrongWordSchedule(
          currentScheduledDate: scheduledDate,
          currentRetryCount: retryCount,
          today: today,
          tomorrow: tomorrow,
        );
        scheduledDate = schedule.scheduledDate;
        retryCount = schedule.retryCount;
        if (scheduledDate != today) {
          escaped = true;
          break;
        }
      }
      expect(escaped, isTrue);
    });
  });
}
