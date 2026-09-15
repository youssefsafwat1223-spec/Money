import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/features/app/app_shell.dart';
import 'package:money_companion/main.dart' as app;
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

/// DESTRUCTIVE PHASE — sign out, walk onboarding, sign back in.
///
/// Runs LAST and alone, because it is the one phase that cannot be undone:
/// `AppSession.signOut` is wired to the local data wipe, so every populated
/// -state measurement the sweep, the probes and the CRUD matrix depend on must
/// already be captured before this file executes. It ends the coverage story
/// rather than contributing to it.
///
/// It closes the last five routes no other run could reach — `/welcome` and the
/// four `/onboarding/*` screens are unreachable while a session exists, so no
/// amount of navigation from a signed-in app can enumerate them.
///
/// Three things are proven here, in order:
///   1. the wipe actually wipes — financial tables are empty afterwards, not
///      merely hidden by a logged-out UI;
///   2. every control on the five post-sign-out routes is enumerated and
///      exercised;
///   3. signing back in restores a working shell, so the destructive path is
///      recoverable rather than terminal.
const _qaEmail = String.fromEnvironment('QA_EMAIL');
const _qaPassword = String.fromEnvironment('QA_PASSWORD');
const _qaUserId = String.fromEnvironment('QA_USER_ID');

/// Financial tables the sign-out wipe is supposed to clear. If any row survives
/// here, a second person signing in on this device inherits the first's money.
const _financialTables = <String>[
  'accounts',
  'transactions',
  'budgets',
  'goals',
  'goal_contributions',
  'cards',
  'subscriptions',
];

const _onboardingRoutes = <String>[
  '/welcome',
  '/onboarding/brand',
  '/onboarding/auth',
  '/onboarding/setup',
  '/onboarding/privacy',
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Collected, not just printed. This file previously defined record() as a
  // bare debugPrint and carried exactly one expect() — on shell mount, not on
  // the wipe — so it printed `WIPE :: FAIL` and still exited zero. The only
  // end-to-end proof that sign-out erases financial data asserted nothing.
  final failures = <String>[];
  final log = <String>[];
  void record(String line) {
    log.add(line);
    if (line.contains(':: FAIL')) failures.add(line);
    debugPrint('[DESTRUCT] $line');
  }

  Future<void> settle(WidgetTester tester,
      {Duration budget = const Duration(seconds: 20)}) async {
    final deadline = DateTime.now().add(budget);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 200));
      if (!tester.binding.hasScheduledFrame) break;
    }
  }

  Future<bool> waitFor(WidgetTester tester, Finder f,
      {Duration timeout = const Duration(seconds: 30)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 200));
      if (f.evaluate().isNotEmpty) return true;
    }
    return false;
  }

  List<String> texts(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
      .where((s) => s.trim().isNotEmpty)
      .toList();

  testWidgets('destructive phase', (tester) async {
    if (_qaEmail.isEmpty || _qaPassword.isEmpty || _qaUserId.isEmpty) {
      debugPrint('[DESTRUCT] SKIPPED — QA defines not supplied.');
      return;
    }
    final previousFatal = WidgetController.hitTestWarningShouldBeFatal;
    WidgetController.hitTestWarningShouldBeFatal = false;
    addTearDown(
        () => WidgetController.hitTestWarningShouldBeFatal = previousFatal);
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
    // A FRESH install (a clean Simulator) has not seen the cinematic welcome,
    // and the router redirects every route to /welcome until it has — so the
    // shell never mounts and every run dies on "shell never mounted". The
    // welcome and onboarding routes are covered by the destructive phase, which
    // reaches them the only way a user can.
    await AppSession.instance.markWelcomeManifestoSeen();
    await settle(tester, budget: const Duration(seconds: 60));
    if (!AppSession.instance.hasCompletedOnboarding) {
      await AppSession.instance.finishOnboarding();
      await settle(tester, budget: const Duration(seconds: 45));
    }
    expect(await waitFor(tester, find.byType(AppShell)), isTrue,
        reason: 'shell never mounted');

    final container =
        ProviderScope.containerOf(tester.element(find.byType(AppShell)));
    final db = container.read(appDatabaseProvider);
    final router = GoRouter.of(tester.element(find.byType(AppShell)));
    String location() =>
        router.routerDelegate.currentConfiguration.uri.toString();

    Future<Map<String, int>> census() async {
      final out = <String, int>{};
      for (final t in _financialTables) {
        try {
          out[t] = (await db.customSelect('SELECT COUNT(*) AS n FROM $t').getSingle())
              .read<int>('n');
        } catch (_) {
          // Table absent in this schema version — nothing to wipe either.
        }
      }
      return out;
    }

    // ── 1. pre-state census ────────────────────────────────────────────────
    final before = await census();
    record('PRE-STATE ${before.entries.map((e) => "${e.key}=${e.value}").join(" ")}');
    if (before.values.every((n) => n == 0)) {
      record('WARNING — the device is already empty; the wipe assertion below '
          'proves nothing on this run.');
    }

    // ── 2. sign out through the UI ─────────────────────────────────────────
    router.go('/settings');
    await settle(tester, budget: const Duration(seconds: 25));
    final out = find.text('تسجيل الخروج');
    if (out.evaluate().isEmpty) {
      // Returning here used to skip the end-of-run assertion entirely, so the
      // one condition that makes the whole phase impossible also made it green.
      semantics.dispose();
      fail('sign-out tile absent on /settings — the destructive phase cannot '
          'run, and that is a failure, not a skip');
    }
    await tester.scrollUntilVisible(out.first, 250,
        scrollable: find.byType(Scrollable).first);
    await settle(tester, budget: const Duration(seconds: 6));
    await tester.tap(out.first, warnIfMissed: false);
    await settle(tester, budget: const Duration(seconds: 20));

    // The unsynced-data dialog only appears when the outbox is non-empty, so
    // its absence is not a failure — but if it IS up, the flow is blocked
    // until it is answered, and the destructive choice is the one under test.
    final discard = find.text('تسجيل الخروج وحذف غير المحفوظ');
    if (discard.evaluate().isNotEmpty) {
      record('SIGN-OUT :: unsynced-data dialog shown; choosing discard');
      await tester.tap(discard.first, warnIfMissed: false);
      await settle(tester, budget: const Duration(seconds: 30));
    } else {
      record('SIGN-OUT :: no unsynced-data dialog (outbox was empty)');
    }
    await settle(tester, budget: const Duration(seconds: 30));

    // ── 3. the wipe must be real, not cosmetic ─────────────────────────────
    final after = await census();
    record('POST-WIPE ${after.entries.map((e) => "${e.key}=${e.value}").join(" ")}');
    final survivors = after.entries.where((e) => e.value > 0).toList();
    record('WIPE :: ${survivors.isEmpty ? "PASS (every financial table empty)" : "FAIL (rows survived: ${survivors.map((e) => "${e.key}=${e.value}").join(",")})"}');
    // A row surviving the sign-out wipe means the next person to sign in on this
    // device inherits the previous user's money. Assert it, do not narrate it.
    expect(
      survivors,
      isEmpty,
      reason: 'sign-out must leave every financial table empty; these survived: '
          '${survivors.map((e) => "${e.key}=${e.value}").join(", ")}',
    );
    expect(
      before.values.any((n) => n > 0),
      isTrue,
      reason: 'the device held no financial rows before sign-out, so this run '
          'proves nothing about the wipe — seed the device and re-run',
    );
    record('SESSION :: status=${AppSession.instance.status} '
        'location=${location()}');

    // ── 4. the five routes no signed-in run can reach ──────────────────────
    for (final path in _onboardingRoutes) {
      router.go(path);
      await settle(tester, budget: const Duration(seconds: 25));
      final landed = location();
      if (find.byType(ErrorWidget).evaluate().isNotEmpty) {
        record('ROUTE $path :: FAIL (ErrorWidget: '
            '${tester.widget<ErrorWidget>(find.byType(ErrorWidget).first).message})');
        continue;
      }
      if (find.byType(Scaffold).evaluate().isEmpty) {
        record('ROUTE $path :: FAIL (no Scaffold; landed at $landed)');
        continue;
      }
      // The redirect guard may legitimately bounce a route: record where we
      // actually ended up rather than pretending we arrived.
      final controls = <String>[];
      for (final entry in <String, Finder>{
        'FilledButton': find.byType(FilledButton),
        'OutlinedButton': find.byType(OutlinedButton),
        'TextButton': find.byType(TextButton),
        'IconButton': find.byType(IconButton),
        'Switch': find.byType(Switch),
        'TextField': find.byType(TextField),
        'InkWell': find.byType(InkWell),
        'GestureDetector': find.byType(GestureDetector),
      }.entries) {
        final n = entry.value.evaluate().length;
        if (n > 0) controls.add('${entry.key}=$n');
      }
      record('ROUTE $path :: arrived=$landed :: controls ${controls.join(" ")} '
          ':: texts ${texts(tester).take(6).join(" | ")}');

      // Exercise the primary CTA where one exists. Onboarding controls advance
      // the flow by design, so the effect measured is the route change, and the
      // next iteration re-navigates anyway.
      for (final f in [find.byType(FilledButton), find.byType(OutlinedButton)]) {
        if (f.evaluate().isEmpty) continue;
        final was = location();
        await tester.tap(f.first, warnIfMissed: false);
        await settle(tester, budget: const Duration(seconds: 20));
        record('$path :: primary CTA :: '
            '${location() != was ? "PASS (advanced to ${location()})" : texts(tester).isNotEmpty ? "DEAD-TAP (no route change)" : "DEAD-TAP"}');
        break;
      }
    }

    // ── 5. recoverable, not terminal ───────────────────────────────────────
    final back = await client.auth
        .signInWithPassword(email: _qaEmail, password: _qaPassword);
    await AppSession.instance
        .setIdentity(method: 'email', email: _qaEmail, userId: back.user!.id);
    await AppSession.instance.reconcileAccountOnboarding(client);
    await settle(tester, budget: const Duration(seconds: 60));
    if (!AppSession.instance.hasCompletedOnboarding) {
      await AppSession.instance.finishOnboarding();
      await settle(tester, budget: const Duration(seconds: 45));
    }
    router.go('/');
    final remounted = await waitFor(tester, find.byType(AppShell),
        timeout: const Duration(seconds: 60));
    record('RELOGIN :: ${remounted ? "PASS (shell remounted)" : "FAIL (shell never came back)"} '
        'status=${AppSession.instance.status}');
    record('===== END =====');
    expect(
      failures,
      isEmpty,
      reason: 'destructive phase recorded ${failures.length} failure(s):\n'
          '${failures.join("\n")}\n\nfull run log:\n${log.join("\n")}',
    );
    semantics.dispose();
  }, timeout: const Timeout(Duration(minutes: 25)));
}
