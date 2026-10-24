import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/l10n/app_localizations_ar.dart';
import 'package:money_companion/l10n/app_localizations_en.dart';

// Astra R45 R10.3 — the incomplete-denial notices state ONLY what is known: the
// durable offline-access denial could not be established. They must not claim
// the data was removed (removal may have thrown, or there may have been no
// target) and must not promise that a restart finishes the job (a restart with
// an unwritten denial may restore offline access).

void main() {
  final en = AppL10nEn();
  final ar = AppL10nAr();

  final enMessages = {
    'removeDataDenyIncompleteMessage': en.removeDataDenyIncompleteMessage,
    'removeDataDenyStillIncomplete': en.removeDataDenyStillIncomplete,
    'signOutCleanupIncompleteMessage': en.signOutCleanupIncompleteMessage,
    'signOutCleanupStillIncomplete': en.signOutCleanupStillIncomplete,
  };
  final arMessages = {
    'removeDataDenyIncompleteMessage': ar.removeDataDenyIncompleteMessage,
    'removeDataDenyStillIncomplete': ar.removeDataDenyStillIncomplete,
    'signOutCleanupIncompleteMessage': ar.signOutCleanupIncompleteMessage,
    'signOutCleanupStillIncomplete': ar.signOutCleanupStillIncomplete,
  };

  test('EN: no restart promise on any incomplete-denial notice (a restart is\n      only named as a risk, never as the fix)', () {
    enMessages.forEach((key, text) {
      expect(text.toLowerCase(), isNot(contains('restart the app')), reason: key);
      expect(text.toLowerCase(), isNot(contains('to finish')), reason: key);
    });
  });

  test('AR: no restart promise on any incomplete-denial notice', () {
    arMessages.forEach((key, text) {
      expect(text, isNot(contains('أعد تشغيل')), reason: key);
      expect(text, isNot(contains('لإكمال ذلك')), reason: key);
    });
  });

  test('the removal denial notice makes no data-removed claim (EN and AR)', () {
    for (final text in [
      en.removeDataDenyIncompleteMessage,
      en.removeDataDenyStillIncomplete,
    ]) {
      expect(text.toLowerCase(), isNot(contains('was removed')));
      expect(text.toLowerCase(), isNot(contains('removed from')));
    }
    for (final text in [
      ar.removeDataDenyIncompleteMessage,
      ar.removeDataDenyStillIncomplete,
    ]) {
      expect(text, isNot(contains('تمت إزالة')));
    }
  });

  test('every notice still says what is true: offline access is not locked',
      () {
    expect(en.removeDataDenyIncompleteMessage.toLowerCase(),
        contains('offline access'));
    expect(en.signOutCleanupIncompleteMessage.toLowerCase(),
        contains('offline'));
    expect(ar.removeDataDenyIncompleteMessage, contains('دون اتصال'));
    expect(ar.signOutCleanupIncompleteMessage, contains('دون اتصال'));
    // A retry is offered instead of a restart.
    expect(en.removeDataDenyIncompleteMessage.toLowerCase(), contains('try again'));
    expect(ar.removeDataDenyIncompleteMessage, contains('أعد المحاولة'));
  });
}
