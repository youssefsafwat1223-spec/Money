import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/features/app/app_shell.dart';
import 'package:money_companion/features/help/coach_marks.dart';
import 'package:money_companion/main.dart' as app;
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import 'demo_seed_test.dart' as demo_seed;

/// STORE SCREENSHOTS — captures the surfaces the App Store listing needs, plus
/// the two V1 guidance surfaces the charter requires evidence for.
///
/// Runs through `flutter drive`, not `flutter test`: `takeScreenshot` only
/// requests a capture from the host, and `test_driver/integration_test.dart` is
/// what writes the bytes to disk.
///
/// Seeds in the SAME PROCESS, by running `demo_seed_test.dart`'s test first.
/// It cannot be a separate run: installing the app replaces its container, so
/// a device seeded by an earlier `flutter test` invocation arrives at the
/// screenshot run empty. The first attempt did exactly that and produced a
/// listing's worth of empty-state screens.
///
/// Reads nothing and asserts nothing about money. If a route fails to render,
/// the run FAILS rather than emitting a screenshot of an error screen, because
/// a blank or broken capture that reaches a store listing is worse than none.
const _qaEmail = String.fromEnvironment('QA_EMAIL');
const _qaPassword = String.fromEnvironment('QA_PASSWORD');
const _qaUserId = String.fromEnvironment('QA_USER_ID');

/// (file name, route). Ordered as a reviewer would walk the app.
const _shots = <(String, String)>[
  ('01-dashboard', '/'),
  ('04-reports', '/reports'),
  ('05-budgets', '/budgets'),
  ('06-goals', '/goals'),
  ('07-accounts', '/accounts'),
  ('08-cards', '/cards'),
  ('09-subscriptions', '/subscriptions'),
  ('10-help', '/help'),
  ('11-settings', '/settings'),
  ('12-privacy', '/privacy'),
];

/// Tabs live inside `AppShell` and have no routes of their own — `/transactions`
/// is not a path, and asking the router for it yields GoRouter's error page.
/// The first run captured exactly that and called it a transactions screenshot,
/// because the error page is a perfectly valid `Scaffold`.
const _tabs = <(String, String)>[
  ('02-transactions', 'العمليات'),
  ('03-analytics', 'التحليلات'),
];

/// Every non-empty string currently rendered, as one comparable value.
String _visibleText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
    .where((s) => s.trim().isNotEmpty)
    .join('|');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Registers the seeding test. It runs first, in this process, against the
  // database this run will then photograph.
  demo_seed.main();

  Future<void> settle(WidgetTester tester,
      {Duration budget = const Duration(seconds: 25)}) async {
    final deadline = DateTime.now().add(budget);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 200));
      if (!tester.binding.hasScheduledFrame) break;
    }
  }

  Future<bool> waitFor(WidgetTester tester, Finder f,
      {Duration timeout = const Duration(seconds: 90)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 200));
      if (f.evaluate().isNotEmpty) return true;
    }
    return false;
  }

  testWidgets('capture the store and guidance surfaces', (tester) async {
    if (_qaEmail.isEmpty || _qaPassword.isEmpty || _qaUserId.isEmpty) {
      fail('QA_EMAIL/QA_PASSWORD/QA_USER_ID are required');
    }
    final previousFatal = WidgetController.hitTestWarningShouldBeFatal;
    WidgetController.hitTestWarningShouldBeFatal = false;
    addTearDown(
        () => WidgetController.hitTestWarningShouldBeFatal = previousFatal);

    // `find.bySemanticsLabel` resolves nothing unless the semantics tree is
    // being built, and the nav tabs are reachable only through it.
    // Disposed explicitly at the end of the body, NOT via addTearDown:
    // `_endOfTestVerifications` runs before tear-downs and fails the test on a
    // handle that is still live.
    final semantics = tester.ensureSemantics();

    app.main();
    await settle(tester, budget: const Duration(seconds: 60));

    final client = supabase.Supabase.instance.client;
    final owner = await AppSession.instance.readLocalDataOwnerUid();
    if (owner != null && owner != _qaUserId) {
      fail('ABORT — the local database belongs to another account.');
    }
    final res = await client.auth
        .signInWithPassword(email: _qaEmail, password: _qaPassword);
    await AppSession.instance
        .setIdentity(method: 'email', email: _qaEmail, userId: res.user!.id);
    await AppSession.instance.reconcileAccountOnboarding(client);
    await AppSession.instance.markWelcomeManifestoSeen();
    await settle(tester, budget: const Duration(seconds: 60));
    if (!AppSession.instance.hasCompletedOnboarding) {
      await AppSession.instance.finishOnboarding();
      await settle(tester, budget: const Duration(seconds: 45));
    }
    expect(await waitFor(tester, find.byType(AppShell)), isTrue,
        reason: 'shell never mounted');

    final router = GoRouter.of(tester.element(find.byType(AppShell)));
    final failures = <String>[];

    // The dashboard tour (charter REQUIRED_PRODUCT_CHANGE_5, Layer A) fires by
    // itself on the first dashboard visit, so it is captured where it actually
    // appears rather than reconstructed. Re-shown deliberately: a device that
    // has been launched before has already seen it, and `showCoachMarksOnce` is
    // a no-op then.
    if (find.byType(AlertDialog).evaluate().isEmpty) {
      await AppSession.instance.resetCoachMarks();
      router.go('/');
      await settle(tester);
      unawaited(showCoachMarksOnce(
        tester.element(find.byType(AppShell)),
        id: CoachMarkIds.dashboard,
        marks: dashboardCoachMarks(tester.element(find.byType(AppShell))),
      ));
      await settle(tester, budget: const Duration(seconds: 8));
    }
    if (find.byType(AlertDialog).evaluate().isNotEmpty) {
      await binding.takeScreenshot('00-coach-marks');
      // Dismiss, so every screenshot below shows the screen and not the tour.
      await tester.tap(find.text('تخطّي').first, warnIfMissed: false);
      await settle(tester, budget: const Duration(seconds: 6));
    } else {
      failures.add('the coach-mark tour did not render');
    }

    for (final (name, route) in _shots) {
      router.go(route);
      await settle(tester);
      if (find.byType(ErrorWidget).evaluate().isNotEmpty) {
        failures.add('$route rendered an ErrorWidget');
        continue;
      }
      if (find.byType(Scaffold).evaluate().isEmpty) {
        failures.add('$route rendered no Scaffold');
        continue;
      }
      // GoRouter's error page IS a Scaffold, so the two checks above pass on a
      // route that does not exist. Nothing but the text distinguishes it.
      if (find.textContaining('GoException').evaluate().isNotEmpty ||
          find.text('Page Not Found').evaluate().isNotEmpty) {
        failures.add('$route is not a route — the router served its error page');
        continue;
      }
      await binding.takeScreenshot(name);
    }

    for (final (name, label) in _tabs) {
      // Back to home before each one. The nav bar collapses to a single-icon
      // pill as the content scrolls, and a collapsed bar shows only the ACTIVE
      // label — so tapping one tab and then looking for the next finds nothing.
      router.go('/');
      await settle(tester);
      // Scoped to the nav bar, not the whole tree. A bare `find.text` matched
      // the dashboard's own "العمليات" section header, tapped it, and produced
      // a second copy of the dashboard under the transactions name — the same
      // mistake as trusting the router's error page, one layer down.
      final navBar = find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == '_BottomNavBar');
      // By SEMANTICS, not by text: the nav renders icons only — the label
      // lives in `Semantics(label: ...)` and is never a `Text` widget. A
      // `find.text` here matched the dashboard's own section header instead,
      // tapped it, and produced a second copy of the dashboard under the tab's
      // name — byte-identical to `01-dashboard`, which is how it was caught.
      final tab =
          find.descendant(of: navBar, matching: find.bySemanticsLabel(label));
      if (navBar.evaluate().isEmpty) {
        failures.add('the bottom nav bar is not mounted');
        continue;
      }
      if (tab.evaluate().isEmpty) {
        // The bar also collapses to a single-icon pill as content scrolls, and
        // a collapsed bar carries only the active tab.
        failures.add('the "$label" tab is not on the nav bar (collapsed?)');
        continue;
      }
      // A tab switch does NOT change the route — the tabs all live at `/` —
      // so the only honest signal that the tap did something is that the
      // screen's text changed. Without this, a tap on dead pixels yields a
      // second copy of the dashboard filed under the tab's name.
      final before = _visibleText(tester);
      await tester.tap(tab.first, warnIfMissed: false);
      await settle(tester);
      if (_visibleText(tester) == before) {
        failures.add('tapping "$label" changed nothing on screen');
        continue;
      }
      await binding.takeScreenshot(name);
    }

    semantics.dispose();
    expect(failures, isEmpty,
        reason: 'no screenshot is better than a broken one:\n'
            '${failures.join("\n")}');
  }, timeout: const Timeout(Duration(minutes: 20)));
}
