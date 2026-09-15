import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/capture/services/local_notification_service.dart';

/// V1 removed the streak reminder (charter: REQUIRED_PRODUCT_CHANGE_2).
///
/// Deleting a scheduler is not the same as removing a notification: the OS keeps
/// whatever was already scheduled, so a device that installed a pre-V1 build
/// would go on receiving a reminder for a feature that no longer exists. These
/// guards cover both halves — nothing may schedule it again, and the cancel
/// path that retires the pending ones must stay wired.
void main() {
  test('no production code schedules the retired streak reminder', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.trimLeft().startsWith('///') ||
            line.trimLeft().startsWith('//')) {
          continue;
        }
        if (line.contains('scheduleStreakReminder') ||
            line.contains('streakReminder:') ||
            line.contains('_streakChannelId')) {
          offenders.add('${entity.path}:${i + 1}: ${line.trim()}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'the streak reminder is retired in V1; these reintroduce it:\n'
          '${offenders.join("\n")}',
    );
  });

  test('the retired id stays in the cancellation set', () {
    // If this id ever drops out of the managed set, sign-out stops cancelling
    // pending streak reminders and pre-V1 installs keep firing them.
    expect(LocalNotificationService.retiredStreakReminderId, 88008);
    expect(
      LocalNotificationService.isManagedReminderId(
        LocalNotificationService.retiredStreakReminderId,
      ),
      isTrue,
    );
  });

  test('the streak reminder is gone from the notification preferences', () {
    // The user-facing setting and its persisted key are both removed; a blank
    // preferences object must not serialise the retired flag.
    expect(
      File('lib/domain/entities/engagement_entities.dart')
          .readAsStringSync()
          .contains('streakReminder'),
      isFalse,
      reason: 'NotificationPreferences must no longer carry the retired flag',
    );
  });
}
