import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/security/secure_storage_options.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/theme/theme_mode_controller.dart';
import 'package:money_companion/features/app/app_shell.dart';
import 'package:money_companion/features/budgets/budget_form_screen.dart';
import 'package:money_companion/main.dart' as app;
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import 'demo_seed_test.dart' as demo_seed;

/// DESIGN FIDELITY WALK — every primary shipping surface, in all four
/// combinations, captured from the real running app.
///
/// One launch covers Arabic/English × light/dark, because both are switchable
/// in-process through the app's own sources: `SaveLanguageUseCase` writes the
/// settings row `localeProvider` reads, and `ThemeModeController.set` writes the
/// keychain flag `themeModeProvider` reads. Four separate installs would prove
/// nothing extra and cost four sign-ins.
///
/// Every surface is recorded rather than thrown, so one unreachable route
/// cannot cost the other fifty-five their captures — the same contract
/// `visual_closure_capture_test` runs under.
const _qaEmail = String.fromEnvironment('QA_EMAIL');
const _qaPassword = String.fromEnvironment('QA_PASSWORD');
const _qaUserId = String.fromEnvironment('QA_USER_ID');

/// The shipping routes a user can reach from the shell, plus the two overlays
/// that carry the most design surface. `/design` is debug-only, `/backup` is a
/// redirect, and `/welcome` needs a signed-out app — none are in the walk.
const _routes = <String, String>{
  'home': '/',
  'budgets': '/budgets',
  'goals': '/goals',
  'reports': '/reports',
  'accounts': '/accounts',
  'cards': '/cards',
  'subscriptions': '/subscriptions',
  'settings': '/settings',
  'privacy': '/privacy',
  'data-transfer': '/data-transfer',
  'achievements': '/achievements',
  'announcements': '/announcements',
  'help': '/help',
  'paste': '/paste',
};

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await SecureStorageOptions.storage
        .write(key: 'app_lock_enabled', value: '0');
  });
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
      await tester.pump(const Duration(milliseconds: 150));
      if (f.evaluate().isNotEmpty) return true;
    }
    return false;
  }

  testWidgets('design fidelity walk', (tester) async {
    WidgetController.hitTestWarningShouldBeFatal = false;
    void phase(String s) => debugPrint('[DF] $s');

    phase('app.main');
    app.main();
    await settle(tester, budget: const Duration(seconds: 60));

    if (_qaEmail.isEmpty) fail('QA_EMAIL/QA_PASSWORD/QA_USER_ID are required');
    final owner = await AppSession.instance.readLocalDataOwnerUid();
    if (owner != null && owner != _qaUserId) fail('ABORT — wrong account');
    final client = supabase.Supabase.instance.client;
    String? userId;
    try {
      final res = await client.auth
          .signInWithPassword(email: _qaEmail, password: _qaPassword)
          .timeout(const Duration(seconds: 60));
      userId = res.user?.id;
    } catch (_) {
      userId = client.auth.currentUser?.id;
    }
    if (userId == null) fail('no session');
    await AppSession.instance
        .setIdentity(method: 'email', email: _qaEmail, userId: userId);
    try {
      await AppSession.instance
          .reconcileAccountOnboarding(client)
          .timeout(const Duration(seconds: 60));
    } catch (_) {/* a restored session reaches the shell */}
    await AppSession.instance.markWelcomeManifestoSeen();
    await settle(tester, budget: const Duration(seconds: 30));
    if (!AppSession.instance.hasCompletedOnboarding) {
      await AppSession.instance.finishOnboarding();
      await settle(tester, budget: const Duration(seconds: 20));
    }
    expect(await waitFor(tester, find.byType(AppShell)), isTrue,
        reason: 'shell never mounted');

    final shell = tester.element(find.byType(AppShell));
    final container = ProviderScope.containerOf(shell);
    final router = GoRouter.of(shell);

    final captured = <String>[];
    final failures = <String>[];

    Future<void> shoot(String name) async {
      await settle(tester, budget: const Duration(seconds: 3));
      await binding.takeScreenshot('df-$name');
      captured.add(name);
      phase('captured $name');
    }

    Future<void> surface(String name, Future<void> Function() body) async {
      try {
        await body();
        await shoot(name);
      } catch (e) {
        phase('FAIL $name: $e');
        failures.add('$name: $e');
      }
    }

    Future<void> popAll() async {
      for (var i = 0; i < 6; i++) {
        final sc = find.byType(Scaffold);
        if (sc.evaluate().isEmpty) break;
        final nav = Navigator.of(tester.element(sc.first));
        if (!nav.canPop()) break;
        nav.pop();
        await settle(tester, budget: const Duration(seconds: 4));
      }
      router.go('/');
      await settle(tester, budget: const Duration(seconds: 8));
    }

    for (final lang in const ['ar', 'en']) {
      await container.read(saveLanguageUseCaseProvider).call(lang);
      await settle(tester, budget: const Duration(seconds: 10));
      for (final theme in const ['light', 'dark']) {
        await container.read(themeModeProvider.notifier).set(
            theme == 'dark' ? ThemeMode.dark : ThemeMode.light);
        await settle(tester, budget: const Duration(seconds: 6));
        final combo = '$lang-$theme';
        phase('=== $combo ===');

        for (final entry in _routes.entries) {
          await surface('$combo-${entry.key}', () async {
            router.go(entry.value);
            await settle(tester, budget: const Duration(seconds: 12));
          });
        }

        // The ledger is a shell TAB, not a route — and it is the densest
        // category-bearing surface in the app, so it cannot be left out of a
        // walk whose job is to inspect category glyphs.
        await surface('$combo-transactions', () async {
          router.go('/');
          await settle(tester, budget: const Duration(seconds: 6));
          container.read(shellIndexProvider.notifier).state = 1;
          await settle(tester, budget: const Duration(seconds: 12));
        });
        container.read(shellIndexProvider.notifier).state = 0;
        await settle(tester, budget: const Duration(seconds: 5));

        // The two overlays that carry the most design surface, including the
        // new Budget alert control.
        await popAll();
        await surface('$combo-budget-form', () async {
          unawaited(BudgetFormScreen.showSheet(
              tester.element(find.byType(AppShell))));
          await settle(tester, budget: const Duration(seconds: 12));
        });
        await popAll();
      }
    }

    phase('captured=${captured.length} failures=${failures.length}');
    for (final f in failures) {
      phase('FAILURE $f');
    }
    // Restore the device for the next run and for manual use.
    await container.read(saveLanguageUseCaseProvider).call('ar');
    await container.read(themeModeProvider.notifier).set(ThemeMode.system);
    await settle(tester, budget: const Duration(seconds: 5));
    phase('DONE');
    expect(failures, isEmpty,
        reason: 'surfaces that could not be reached: ${failures.join("; ")}');
  }, timeout: const Timeout(Duration(minutes: 40)));
}
