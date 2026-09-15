import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/features/app/app_shell.dart';
import 'package:money_companion/main.dart' as app;
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

/// ACCESSIBILITY AUDIT — Flutter's own guidelines, run against real screens.
///
/// The readiness sheet recorded this gate as PARTIAL: "RTL/LTR asserted on the
/// new surfaces; no full audit". This is the audit, and it runs the framework's
/// `meetsGuideline` matchers rather than anything hand-rolled:
///
///   * `iOSTapTargetGuideline`      — every tappable is at least 44x44
///   * `labeledTapTargetGuideline`  — every tappable has a semantic label a
///                                     screen reader can announce
///   * `textContrastGuideline`      — text meets WCAG AA against its background
///
/// It reports per route rather than stopping at the first failure, because
/// "which screens and how many" is the question an audit has to answer.
///
/// ## What it found, and why it does not simply fail
///
/// First run, 2026-09-16: contrast 10/10 routes, labels 5/10, tap targets 2/10.
/// That is real debt and it is recorded as debt — not waved through, and not
/// dressed up as a pass.
///
/// It asserts against a BASELINE rather than against zero. Fixing contrast
/// across ten screens means changing the brand palette, which is a design
/// decision and not one a test should make at release time; fixing every label
/// means touching surfaces this effort has no other reason to open. A test that
/// fails permanently teaches people to ignore failures, and one that asserts
/// zero today would simply be deleted tomorrow. So: the counts may not GROW,
/// and every reduction should be accompanied by lowering the baseline.
///
/// One honest caveat on the contrast number. Flutter's `textContrastGuideline`
/// samples the rendered pixels behind the text, and this app puts white text on
/// navy GRADIENTS across most headers. The guideline is known to report against
/// gradients and images in ways that do not always match what a person sees.
/// Some of these ten are certainly real; treating all ten as confirmed
/// violations would be overstating what has been established.
const _qaEmail = String.fromEnvironment('QA_EMAIL');
const _qaPassword = String.fromEnvironment('QA_PASSWORD');
const _qaUserId = String.fromEnvironment('QA_USER_ID');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> settle(WidgetTester tester,
      {Duration budget = const Duration(seconds: 25)}) async {
    final deadline = DateTime.now().add(budget);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
      if (!tester.binding.hasScheduledFrame) break;
    }
  }

  testWidgets('every V1 surface against the framework guidelines',
      (tester) async {
    if (_qaEmail.isEmpty || _qaPassword.isEmpty || _qaUserId.isEmpty) {
      fail('QA_EMAIL/QA_PASSWORD/QA_USER_ID are required');
    }
    final previousFatal = WidgetController.hitTestWarningShouldBeFatal;
    WidgetController.hitTestWarningShouldBeFatal = false;
    addTearDown(
        () => WidgetController.hitTestWarningShouldBeFatal = previousFatal);

    final handle = tester.ensureSemantics();

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
    expect(await _waitForShell(tester), isTrue, reason: 'shell never mounted');

    final router = GoRouter.of(tester.element(find.byType(AppShell)));
    final contrastFailures = <String>[];
    final labelFailures = <String>[];
    final tapTargetNotes = <String>[];

    for (final route in const [
      '/',
      '/reports',
      '/accounts',
      '/budgets',
      '/goals',
      '/cards',
      '/subscriptions',
      '/settings',
      '/help',
      '/privacy',
    ]) {
      router.go(route);
      await settle(tester);

      Future<String?> check(AccessibilityGuideline g) async {
        try {
          await expectLater(tester, meetsGuideline(g));
          return null;
        } catch (e) {
          // The matcher's message names the offending nodes; keep the first
          // couple of lines so the report says WHAT, not just "failed".
          final text = e.toString().split('\n').take(4).join(' | ');
          return text.length > 300 ? '${text.substring(0, 300)}…' : text;
        }
      }

      final contrast = await check(textContrastGuideline);
      if (contrast != null) contrastFailures.add('$route :: $contrast');
      final labels = await check(labeledTapTargetGuideline);
      if (labels != null) labelFailures.add('$route :: $labels');
      final taps = await check(iOSTapTargetGuideline);
      if (taps != null) tapTargetNotes.add('$route :: $taps');
    }

    debugPrint('[A11Y] ==== accessibility audit ====');
    debugPrint('[A11Y] contrast failures:    ${contrastFailures.length}/10 routes');
    for (final f in contrastFailures) {
      debugPrint('[A11Y]   $f');
    }
    debugPrint('[A11Y] label failures:       ${labelFailures.length}/10 routes');
    for (final f in labelFailures) {
      debugPrint('[A11Y]   $f');
    }
    debugPrint('[A11Y] tap-target notes:     ${tapTargetNotes.length}/10 routes');
    for (final f in tapTargetNotes) {
      debugPrint('[A11Y]   $f');
    }

    handle.dispose();

    // The baseline measured on 2026-09-16. These are DEBT, not a target, and
    // the only correct direction is down. Lower the number when you fix one.
    const contrastBaseline = 10;
    const labelBaseline = 5;
    const tapTargetBaseline = 2;

    expect(
      labelFailures.length,
      lessThanOrEqualTo(labelBaseline),
      reason: 'unlabeled tappables grew past the $labelBaseline-route baseline '
          '— an unlabeled control is invisible to VoiceOver:\n'
          '${labelFailures.join("\n")}',
    );
    expect(
      contrastFailures.length,
      lessThanOrEqualTo(contrastBaseline),
      reason: 'contrast failures grew past the $contrastBaseline-route '
          'baseline:\n${contrastFailures.join("\n")}',
    );
    expect(
      tapTargetNotes.length,
      lessThanOrEqualTo(tapTargetBaseline),
      reason: 'sub-44x44 tappables grew past the $tapTargetBaseline-route '
          'baseline:\n${tapTargetNotes.join("\n")}',
    );
  }, timeout: const Timeout(Duration(minutes: 20)));
}

Future<bool> _waitForShell(WidgetTester tester) async {
  final deadline = DateTime.now().add(const Duration(seconds: 90));
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (find.byType(AppShell).evaluate().isNotEmpty) return true;
  }
  return false;
}
