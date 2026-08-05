// MALI-019 §6 — lock-screen privacy: redacted content carries no financial
// data, and the preference round-trips through persistence.
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/features/capture/services/local_notification_service.dart';

void main() {
  group('redactedContentFor', () {
    test('every type yields generic content with no financial data', () {
      // A canary for each sensitive class the finding lists.
      const canaries = <String>[
        '512.34', 'STARBUCKS', 'ستاربكس', '4417', 'AlRajhi', 'نتفلكس',
        'رصيد', 'الراتب', 'goal', 'Netflix',
      ];
      for (final type in NotificationType.values) {
        final (title, body) = LocalNotificationService.redactedContentFor(type);
        expect(title.isNotEmpty, isTrue);
        expect(body.isNotEmpty, isTrue);
        for (final canary in canaries) {
          expect(title.contains(canary), isFalse, reason: '$type title');
          expect(body.contains(canary), isFalse, reason: '$type body');
        }
      }
    });
  });

  group('hideLockScreenContent preference', () {
    test('defaults to false (full details), documented non-regressive', () {
      expect(const NotificationPreferences().hideLockScreenContent, isFalse);
    });

    test('round-trips through toJson/fromJson', () {
      final on = const NotificationPreferences()
          .copyWith(hideLockScreenContent: true);
      final restored = NotificationPreferences.fromJson(on.toJson());
      expect(restored.hideLockScreenContent, isTrue);
      // Absent key (old persisted blob) → false.
      expect(
        NotificationPreferences.fromJson(<String, dynamic>{})
            .hideLockScreenContent,
        isFalse,
      );
    });
  });
}
