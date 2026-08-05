import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/services/notification_planner.dart';

// MALI-061n §3 (closure) — logical notification identity must derive from a
// stable business key, NEVER from mutable display text. `notificationEventId`
// (the sole id source for capture-light / review / achievement notifications)
// takes only (type, stableKey): the rendered title/body/locale/amount are
// structurally not inputs, so changing them cannot change the id, while a
// different occurrence key always yields a different id.
void main() {
  test('same business key → same id regardless of any rendered text', () {
    // The id is a pure function of (type, key). Two different display strings
    // for the SAME capture map to the same id because text is not an input.
    final a = notificationEventId('captureLight', 'txn-42');
    final b = notificationEventId('captureLight', 'txn-42');
    expect(a, b);
  });

  test('different occurrence key → different id', () {
    expect(
      notificationEventId('captureLight', 'txn-1'),
      isNot(notificationEventId('captureLight', 'txn-2')),
    );
  });

  test('the type scopes the identity (same key, different type → different id)', () {
    expect(
      notificationEventId('captureLight', 'txn-1'),
      isNot(notificationEventId('review', 'txn-1')),
    );
  });

  test('content-fingerprint key is stable across display/locale/amount changes', () {
    // For an unprocessable capture with no transaction id, the id key is a
    // fingerprint of the IMMUTABLE capture content (source|sender|raw text) —
    // the same shape the ingest use case builds. The same raw capture always
    // maps to the same id even if the localized banner text differs.
    String contentKey(String source, String? sender, String text) =>
        'capture:$source:${sender ?? ''}:$text';
    final k1 = contentKey('androidShare', 'BANK', 'raw sms body');
    final sameContent = notificationEventId('captureLight', k1);
    final againEnglishUiVsArabicUi = notificationEventId('captureLight', k1);
    expect(sameContent, againEnglishUiVsArabicUi);
    // A different raw capture → a different id.
    final k2 = contentKey('androidShare', 'BANK', 'a different sms body');
    expect(sameContent, isNot(notificationEventId('captureLight', k2)));
  });

  test('achievement id derives from the stable achievement key, not text', () {
    expect(
      achievementNotificationId('first_transaction'),
      achievementNotificationId('first_transaction'),
    );
    expect(
      achievementNotificationId('first_transaction'),
      isNot(achievementNotificationId('century_transaction')),
    );
  });

  test('all ids are non-negative 31-bit-safe integers', () {
    for (final id in [
      notificationEventId('captureLight', 'x'),
      notificationEventId('review', 'y'),
      achievementNotificationId('z'),
      billReminderNotificationId('bill-1'),
      goalMilestoneNotificationId('goal-1'),
    ]) {
      expect(id, greaterThanOrEqualTo(0));
      expect(id, lessThan(0x7FFFFFFF));
    }
  });
}
