import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/features/app/app_shell.dart';
import 'package:money_companion/main.dart' as app;
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import 'demo_seed_test.dart' as demo_seed;

/// MODAL HARVEST — reaching the surfaces no route can.
///
/// The proof audit reported sheets, dialogs, menus and forms as NOT PROVEN, and
/// the UI Atlas explains why a route walk cannot reach them: HEAD has **45
/// `showModalBottomSheet` call-sites and 28 `showDialog` call-sites**, none of
/// which is a route. `UI_SURFACE_GAP_REPORT.md` names twelve overlays that live
/// as private classes inside 1,600-line screens, launched by a tap.
///
/// So this taps. For every route it enumerates the tappable controls, presses
/// each in turn, and captures whatever modal route appears — then dismisses it
/// and continues. It is deliberately indiscriminate: naming the triggers in
/// advance would only re-encode what someone already believed was there, and
/// the atlas exists because that belief was wrong twelve times.
///
/// Destructive controls are skipped by label. A harvest that deletes the
/// fixture half way through stops being a harvest.
const _qaEmail = String.fromEnvironment('QA_EMAIL');
const _qaPassword = String.fromEnvironment('QA_PASSWORD');
const _qaUserId = String.fromEnvironment('QA_USER_ID');

/// Labels whose controls must not be pressed: they delete data, end the
/// session, or leave the app.
const _forbidden = <String>[
  'حذف', 'احذف', 'تسجيل الخروج', 'إزالة', 'أزل', 'مسح', 'امسح',
  'إعادة تعيين', 'تصفير', 'إلغاء الاشتراك', 'فصل', 'تعطيل',
];

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  demo_seed.main();

  Future<void> settle(WidgetTester tester,
      {Duration budget = const Duration(seconds: 12)}) async {
    final deadline = DateTime.now().add(budget);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
      if (!tester.binding.hasScheduledFrame) break;
    }
  }

  Future<bool> waitFor(WidgetTester tester, Finder f,
      {Duration timeout = const Duration(seconds: 90)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
      if (f.evaluate().isNotEmpty) return true;
    }
    return false;
  }

  testWidgets('harvest every sheet and dialog a tap can reach', (tester) async {
    if (_qaEmail.isEmpty || _qaPassword.isEmpty || _qaUserId.isEmpty) {
      fail('QA_EMAIL/QA_PASSWORD/QA_USER_ID are required');
    }
    final previousFatal = WidgetController.hitTestWarningShouldBeFatal;
    WidgetController.hitTestWarningShouldBeFatal = false;
    addTearDown(
        () => WidgetController.hitTestWarningShouldBeFatal = previousFatal);

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
    var captured = 0;
    var tapped = 0;
    var skipped = 0;
    final perRoute = <String, int>{};
    final seenTitles = <String>{};

    String? modalSignature(WidgetTester tester) {
      // A modal is a sheet or a dialog sitting above the page.
      final isSheet = find.byType(BottomSheet).evaluate().isNotEmpty;
      final isDialog = find.byType(Dialog).evaluate().isNotEmpty ||
          find.byType(AlertDialog).evaluate().isNotEmpty;
      if (!isSheet && !isDialog) return null;
      final texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .where((s) => s.trim().isNotEmpty)
          .take(3)
          .join('|');
      return '${isSheet ? "sheet" : "dialog"}:$texts';
    }

    Future<void> dismiss(WidgetTester tester) async {
      // Escape first (dialogs), then a back gesture (sheets).
      for (var attempt = 0; attempt < 3; attempt++) {
        if (modalSignature(tester) == null) return;
        final nav = Navigator.maybeOf(tester.element(find.byType(Scaffold).first));
        if (nav != null && nav.canPop()) {
          nav.pop();
        } else {
          break;
        }
        await settle(tester, budget: const Duration(seconds: 4));
      }
    }

    for (final route in const [
      '/', '/reports', '/accounts', '/budgets', '/goals', '/cards',
      '/subscriptions', '/settings', '/privacy', '/data-transfer',
      '/coupons', '/profile', '/achievements', '/savings', '/paste',
      '/announcements', '/referrals', '/help', '/backup',
    ]) {
      router.go(route);
      await settle(tester);
      // Progress is printed per route, not only at the end: a run that dies
      // part-way is still evidence of how far it got.
      debugPrint('[HARVEST] route $route — captured so far: $captured');
      if (find.byType(Scaffold).evaluate().isEmpty) continue;
      if (find.textContaining('GoException').evaluate().isNotEmpty) continue;

      // Snapshot the control set ONCE: tapping mutates the tree, and a live
      // finder would walk into elements that no longer exist.
      final controlCount = find.byType(InkWell).evaluate().length +
          find.byType(ListTile).evaluate().length;
      final limit = controlCount < 24 ? controlCount : 24;

      for (var i = 0; i < limit; i++) {
        router.go(route);
        await settle(tester, budget: const Duration(seconds: 6));

        final controls = [
          ...find.byType(ListTile).evaluate(),
          ...find.byType(InkWell).evaluate(),
        ];
        if (i >= controls.length) break;

        // Skip anything destructive, by the text inside it.
        final element = controls[i];
        final label = tester
            .widgetList<Text>(find.descendant(
                of: find.byWidget(element.widget), matching: find.byType(Text)))
            .map((t) => t.data ?? '')
            .join(' ');
        if (_forbidden.any(label.contains)) {
          skipped++;
          continue;
        }

        try {
          await tester.tap(find.byWidget(element.widget), warnIfMissed: false);
        } catch (_) {
          continue;
        }
        tapped++;
        await settle(tester, budget: const Duration(seconds: 6));
        tester.takeException();

        final sig = modalSignature(tester);
        if (sig != null && seenTitles.add(sig)) {
          captured++;
          perRoute[route] = (perRoute[route] ?? 0) + 1;
          await binding.takeScreenshot(
              'modal-${captured.toString().padLeft(2, "0")}'
              '-${route.replaceAll("/", "_")}');
        }
        await dismiss(tester);
        tester.takeException();
      }
    }

    debugPrint('[HARVEST] controls tapped:   $tapped');
    debugPrint('[HARVEST] destructive skipped: $skipped');
    debugPrint('[HARVEST] distinct modals captured: $captured');
    for (final e in perRoute.entries) {
      debugPrint('[HARVEST]   ${e.key}: ${e.value}');
    }
    for (final s in seenTitles) {
      debugPrint('[HARVEST] surface :: $s');
    }

    expect(captured, greaterThan(0),
        reason: 'the harvest reached no modal at all — it has stopped working');
  }, timeout: const Timeout(Duration(minutes: 45)));
}
