// MALI-019 §6 — lock-screen privacy: redacted content carries no financial
// data, and the preference round-trips through persistence.
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/features/capture/services/local_notification_service.dart';

void main() {
  group('redactedContentFor', () {
    test('every type yields generic content with no financial data', () {
      // A canary for each sensitive class the finding lists.
      // Each canary stands for a VALUE that must never reach the lock screen:
      // an amount, a merchant, a card tail, a bank, a balance, a salary, a
      // goal NAME. The bare word 'goal' used to be in this list as a cheap
      // catch-all — it only ever passed because the bodies were Arabic, and it
      // fires on the English "goal update", which leaks nothing. Replaced with
      // the thing it was actually guarding: a goal's name.
      const canaries = <String>[
        '512.34', 'STARBUCKS', 'ستاربكس', '4417', 'AlRajhi', 'نتفلكس',
        'رصيد', 'الراتب', 'Netflix', 'رحلة الصيف', 'Summer trip',
      ];
      // The guarantee is about the CONTRACT, not the wording, so it has to
      // hold in every language the content can be emitted in. An English
      // redaction string that leaked a merchant would be the same defect.
      for (final lang in ['ar', 'en']) {
        for (final type in NotificationType.values) {
          final (title, body) = LocalNotificationService.redactedContentFor(
              type,
              languageCode: lang);
          expect(title.isNotEmpty, isTrue, reason: '$type/$lang title');
          expect(body.isNotEmpty, isTrue, reason: '$type/$lang body');
          for (final canary in canaries) {
            expect(title.contains(canary), isFalse, reason: '$type/$lang title');
            expect(body.contains(canary), isFalse, reason: '$type/$lang body');
          }
        }
      }
    });

    test('the default is Arabic, so no caller silently changed language', () {
      for (final type in NotificationType.values) {
        expect(LocalNotificationService.redactedContentFor(type),
            LocalNotificationService.redactedContentFor(type,
                languageCode: 'ar'));
      }
    });

    test('English is actually English, not Arabic wearing a flag', () {
      final arabic = RegExp(r'[\u0600-\u06FF]');
      for (final type in NotificationType.values) {
        final (title, body) =
            LocalNotificationService.redactedContentFor(type, languageCode: 'en');
        // The brand name is exempt — «قرش» is a name, and the English build
        // spells it "Qirsh", so neither string should carry Arabic script.
        expect(arabic.hasMatch(title), isFalse, reason: '$type title: $title');
        expect(arabic.hasMatch(body), isFalse, reason: '$type body: $body');
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
