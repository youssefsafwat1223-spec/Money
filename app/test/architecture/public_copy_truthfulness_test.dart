import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Public copy must not claim capabilities the app does not have.
///
/// ## Why this exists
///
/// On 2026-09-03 the published website, the Terms and the Privacy Policy all
/// said Qirsh "reads bank SMS **and notification messages**". It does not, and
/// never has: there is no `NotificationListenerService`, no
/// `BIND_NOTIFICATION_LISTENER_SERVICE`, and no notification-read path on
/// either platform. The only capture sources are Android SMS (opt-in), the
/// share sheet, iOS Shortcuts, and manual paste.
///
/// The app's own shipped string said so correctly the whole time —
/// `smsCaptureTrustNotice` in `app_ar.arb` promises «لا يقرأ إشعارات تطبيقات
/// البنوك» ("it does not read bank app notifications"). So the product told
/// users one thing in-app and the opposite on the web, in a **legal document**,
/// in both languages, across seven separate strings.
///
/// This matters beyond tidiness: the Google Play restricted-permission
/// declaration attaches the policy URL, and Play reconciles the policy against
/// the Data Safety form. Over-claiming collection is not a safe direction to
/// err in — it describes data handling the app cannot actually perform.
///
/// Same family as RB-3 and RB-8: a published document that source disproves.
void main() {
  final manifest =
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
  final kotlin = Directory('android/app/src/main/kotlin')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.kt'))
      .map((f) => f.readAsStringSync())
      .join('\n');

  final appReadsNotifications =
      manifest.contains('BIND_NOTIFICATION_LISTENER_SERVICE') ||
          kotlin.contains('NotificationListenerService');

  test('the app genuinely has no notification-read capability', () {
    // The anchor for everything below. If this ever legitimately changes, this
    // test fails FIRST and tells you to revisit the public copy deliberately,
    // rather than the copy silently becoming true by accident.
    expect(appReadsNotifications, isFalse,
        reason: 'A notification-read capability now exists. That is a product '
            'and Play-policy change: update the Privacy Policy, Terms, site '
            'copy and the Data Safety form together, then update this test.');
  });

  test('no public-facing copy claims Qirsh reads notifications', () {
    if (appReadsNotifications) return; // covered by the test above

    // Targeted phrases, not a blanket ban on the word "notification" — the app
    // legitimately SENDS local notifications (reminders), and describing that
    // is true and must stay allowed.
    const forbidden = <String, String>{
      'notification messages': 'EN: claims notification reading',
      'notification text': 'EN: claims notification collection',
      'رسائل البنك والإشعارات': 'AR: claims notification reading',
    };

    final sources = <String, String>{
      '../docs/legal/PRIVACY_POLICY.md': '',
      '../docs/legal/TERMS.md': '',
      '../tools/site_content.py': '',
    };

    final violations = <String>[];
    for (final path in sources.keys) {
      final f = File(path);
      expect(f.existsSync(), isTrue, reason: '$path missing');
      final text = f.readAsStringSync();
      forbidden.forEach((phrase, why) {
        if (text.contains(phrase)) violations.add('$path — $why: "$phrase"');
      });
    }

    expect(violations, isEmpty,
        reason: 'Public copy claims a capability the app does not have. The '
            'app has no notification access; its own in-app string says so. '
            'These documents are attached to a Play restricted-permission '
            'declaration and reconciled against Data Safety.');
  });

  test('the in-app promise this is pinned to still exists', () {
    // If the Arabic trust notice is ever reworded away, the contradiction this
    // test exists to prevent becomes invisible again.
    final arb = File('lib/l10n/app_ar.arb').readAsStringSync();
    expect(arb, contains('لا يقرأ إشعارات تطبيقات البنوك'),
        reason: 'smsCaptureTrustNotice no longer promises that Qirsh does not '
            'read bank app notifications. Either restore it, or reconcile the '
            'promise with the public copy deliberately.');
  });
}
