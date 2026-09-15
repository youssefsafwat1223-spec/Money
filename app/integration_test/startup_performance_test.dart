import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/features/app/app_shell.dart';
import 'package:money_companion/main.dart' as app;
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

/// STARTUP AND NAVIGATION TIMING — turning "NOT MEASURED" into numbers.
///
/// This measures; it does not set a budget. A performance target is a product
/// decision, and inventing one here would dress a guess as a gate. What it DOES
/// assert are ceilings loose enough that only a real regression trips them —
/// the kind of change that takes cold start from two seconds to twenty, not the
/// kind that costs eighty milliseconds.
///
/// Simulator numbers, and they are not device numbers: no thermal limits, a
/// desktop CPU, and a debug build with assertions on. They are a baseline to
/// compare against, not a claim about what anyone's phone does.
const _qaEmail = String.fromEnvironment('QA_EMAIL');
const _qaPassword = String.fromEnvironment('QA_PASSWORD');
const _qaUserId = String.fromEnvironment('QA_USER_ID');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> settle(WidgetTester tester,
      {Duration budget = const Duration(seconds: 30)}) async {
    final deadline = DateTime.now().add(budget);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
      if (!tester.binding.hasScheduledFrame) break;
    }
  }

  testWidgets('cold start and route navigation, measured', (tester) async {
    if (_qaEmail.isEmpty || _qaPassword.isEmpty || _qaUserId.isEmpty) {
      fail('QA_EMAIL/QA_PASSWORD/QA_USER_ID are required');
    }
    final previousFatal = WidgetController.hitTestWarningShouldBeFatal;
    WidgetController.hitTestWarningShouldBeFatal = false;
    addTearDown(
        () => WidgetController.hitTestWarningShouldBeFatal = previousFatal);

    final launchedAt = DateTime.now();
    app.main();

    // Time to the FIRST frame the user could see, rather than to a settled
    // tree: a splash that appears instantly and then works is a different
    // experience from a blank window, and only the first is worth measuring as
    // "did it start".
    var firstFrameMs = -1;
    final firstFrameDeadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(firstFrameDeadline)) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.byType(MaterialApp).evaluate().isNotEmpty) {
        firstFrameMs = DateTime.now().difference(launchedAt).inMilliseconds;
        break;
      }
    }

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

    final shellAt = DateTime.now();
    var shellMs = -1;
    final shellDeadline = DateTime.now().add(const Duration(seconds: 90));
    while (DateTime.now().isBefore(shellDeadline)) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.byType(AppShell).evaluate().isNotEmpty) {
        shellMs = DateTime.now().difference(shellAt).inMilliseconds;
        break;
      }
    }
    expect(shellMs, greaterThanOrEqualTo(0), reason: 'shell never mounted');

    final router = GoRouter.of(tester.element(find.byType(AppShell)));
    final routeMs = <String, int>{};
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
      final at = DateTime.now();
      router.go(route);
      await settle(tester, budget: const Duration(seconds: 20));
      routeMs[route] = DateTime.now().difference(at).inMilliseconds;
    }

    debugPrint('[PERF] first frame:        ${firstFrameMs}ms');
    debugPrint('[PERF] shell after auth:   ${shellMs}ms');
    final sorted = routeMs.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final e in sorted) {
      debugPrint('[PERF] route ${e.key.padRight(16)} ${e.value}ms');
    }
    final slowest = sorted.first;
    final total = routeMs.values.fold(0, (a, b) => a + b);
    debugPrint('[PERF] slowest route:      ${slowest.key} (${slowest.value}ms)');
    debugPrint('[PERF] mean route settle:  ${total ~/ routeMs.length}ms');

    // Regression ceilings, not targets. Deliberately generous: these exist to
    // catch "something now blocks the main thread for twenty seconds", which is
    // the failure a release should never ship, and to stay quiet about the
    // ordinary variance of a shared CI machine.
    expect(firstFrameMs, lessThan(15000),
        reason: 'no frame within 15s of launch is a broken app, not a slow one');
    expect(slowest.value, lessThan(15000),
        reason: '${slowest.key} took ${slowest.value}ms to settle');
  }, timeout: const Timeout(Duration(minutes: 15)));
}
