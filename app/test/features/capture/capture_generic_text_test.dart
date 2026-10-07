// CAP-7 (`capture_notify_v2`, manifest Q3 / X9): the lock-screen text of a
// capture alert never carries an amount, merchant, card or sender, on any
// channel, in both languages. Flag OFF keeps the shipped behaviour.
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/features/capture/services/capture_notification_content.dart';
import 'package:money_companion/features/capture/services/local_notification_service.dart';

void main() {
  const detailedTitle = 'تم رصد عملية شراء 🛒';
  const detailedBody = 'المبلغ: 45.00 SAR\nالتاجر: NETFLIX\nالبطاقة: ****4521';

  (String, String) shown({
    required NotificationType type,
    bool hide = false,
    bool generic = false,
    required bool v2,
    String lang = 'en',
  }) =>
      LocalNotificationService.lockScreenContentFor(
        type: type,
        title: detailedTitle,
        body: detailedBody,
        hideLockScreenContent: hide,
        genericContent: generic,
        captureNotifyV2: v2,
        languageCode: lang,
      );

  final digits = RegExp(r'[0-9٠-٩]');

  group('flag ON: generic for every capture alert type', () {
    for (final type in [
      NotificationType.captureReview,
      NotificationType.captureLight,
    ]) {
      for (final lang in ['en', 'ar']) {
        for (final hide in [false, true]) {
          test('$type / $lang / hideLockScreenContent=$hide', () {
            final (title, body) = shown(type: type, hide: hide, v2: true, lang: lang);
            final expected = buildGenericCaptureContent(lang: lang);
            expect(title, expected.title);
            expect(body, expected.body);
            for (final leaked in ['NETFLIX', '4521', '45', 'SAR', 'المبلغ']) {
              expect('$title $body', isNot(contains(leaked)));
            }
            expect(digits.hasMatch('$title$body'), isFalse);
          });
        }
      }
    }

    test('English wording mirrors the server push (GENERIC_CAPTURE_PUSH)', () {
      expect(buildGenericCaptureContent(lang: 'en').body,
          'New transaction captured');
    });

    test('summary and correction text is shown as given (already generic)', () {
      final summary = buildCaptureSummaryContent(7, lang: 'en');
      final (title, body) = LocalNotificationService.lockScreenContentFor(
        type: NotificationType.captureLight,
        title: summary.title,
        body: summary.body,
        hideLockScreenContent: true,
        genericContent: true,
        captureNotifyV2: true,
        languageCode: 'en',
      );
      expect((title, body), (summary.title, summary.body));
      expect(body, '7 new transactions captured');
    });

    test('non-capture alerts are untouched by the flag', () {
      expect(shown(type: NotificationType.budgetWarning, v2: true),
          (detailedTitle, detailedBody));
    });
  });

  group('flag OFF: shipped behaviour', () {
    test('detailed content unless the redaction preference is on', () {
      expect(shown(type: NotificationType.captureReview, v2: false),
          (detailedTitle, detailedBody));
      expect(
        shown(type: NotificationType.captureLight, hide: true, v2: false),
        LocalNotificationService.redactedContentFor(NotificationType.captureLight,
            languageCode: 'en'),
      );
    });

    test('the service defaults to the flag being off', () {
      expect(LocalNotificationService.instance.captureNotifyV2(), isFalse);
    });
  });

  group('builders carry no financial data', () {
    for (final lang in ['en', 'ar']) {
      test('generic / summary / correction in $lang', () {
        for (final c in [
          buildGenericCaptureContent(lang: lang),
          buildCaptureSummaryContent(5, lang: lang),
          buildCaptureCorrectionContent(lang: lang),
        ]) {
          // Only the summary count is a digit; nothing else may be.
          final text = '${c.title} ${c.body}'.replaceAll('5', '');
          expect(digits.hasMatch(text), isFalse);
        }
      });
    }

    test('Arabic summary plural form', () {
      expect(buildCaptureSummaryContent(5, lang: 'ar').body, 'تم رصد 5 عمليات جديدة');
      expect(buildCaptureSummaryContent(12, lang: 'ar').body, 'تم رصد 12 عملية جديدة');
    });
  });
}
