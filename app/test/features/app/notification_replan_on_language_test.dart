import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/domain/services/notification_planner.dart';

/// A scheduled notification is composed NOW and delivered hours or days later,
/// so it carries the language that was current when it was PLANNED.
///
/// Re-planning used to happen only on cold start and on resume. Someone who
/// switched to English and did not background the app would still receive that
/// evening's reminder in Arabic — and the doc comment in the planner claimed
/// "switching language re-plans", which was not true of any code path.
///
/// `AppShell` now listens for the switch. These assert the property that makes
/// that safe: re-planning in a new language produces the SAME ids, so the OS
/// replaces the pending requests instead of stacking a second set.
void main() {
  const planner = NotificationPlanner();
  final now = DateTime(2026, 9, 17, 8);

  test('re-planning in another language keeps every notification id', () {
    final ar = planner.planScheduled(
      preferences: const NotificationPreferences(),
      bills: const [],
      nowRiyadh: now,
      lang: 'ar',
    );
    final en = planner.planScheduled(
      preferences: const NotificationPreferences(),
      bills: const [],
      nowRiyadh: now,
      lang: 'en',
    );

    expect(ar, isNotEmpty, reason: 'nothing was planned, so nothing is proven');
    expect(en.map((p) => p.id).toList(), ar.map((p) => p.id).toList(),
        reason: 'a language switch changed the ids — the old requests would '
            'stay pending and the user would get BOTH languages');
    expect(en.map((p) => p.kind).toList(), ar.map((p) => p.kind).toList());
    expect(
      en.map((p) => p.scheduledAtRiyadh).toList(),
      ar.map((p) => p.scheduledAtRiyadh).toList(),
      reason: 're-planning moved the delivery time',
    );
  });

  test('and it does change the words', () {
    // The counterpart: identical ids are only correct if the CONTENT differs.
    final ar = planner.planScheduled(
      preferences: const NotificationPreferences(),
      bills: const [],
      nowRiyadh: now,
      lang: 'ar',
    );
    final en = planner.planScheduled(
      preferences: const NotificationPreferences(),
      bills: const [],
      nowRiyadh: now,
      lang: 'en',
    );
    final arabicScript = RegExp(r'[؀-ۿ]');
    for (var i = 0; i < ar.length; i++) {
      expect(en[i].title, isNot(ar[i].title),
          reason: '${en[i].kind} has the same title in both languages');
      expect(arabicScript.hasMatch(en[i].title), isFalse,
          reason: '${en[i].kind} title still reads Arabic under en');
      expect(arabicScript.hasMatch(en[i].body), isFalse,
          reason: '${en[i].kind} body still reads Arabic under en');
    }
  });

  test('the shell re-plans on a language switch, not only on resume', () {
    // The behaviour lives in a StatefulWidget with a live database and
    // notification plugin behind it, so this asserts the WIRING rather than
    // pumping the shell. Without the listener the planner is correct and the
    // user still gets the old language until they next background the app.
    final shell = File('lib/features/app/app_shell.dart').readAsStringSync();
    expect(shell, contains('ref.listen<Locale>(localeProvider'));
    expect(shell, contains('_replanScheduledNotifications'));
  });
}
