import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/features/app/app_shell.dart';
import 'package:money_companion/main.dart' as app;
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'demo_seed_test.dart' as demo_seed;

/// BILINGUAL WALK — the same surfaces in Arabic and in English, with the text
/// direction asserted rather than assumed.
///
/// `V1_LOCALIZATION_MATRIX.md` recorded RTL as "asserted on the new surfaces"
/// and LTR as never run at all. This runs both: it drives the app through every
/// V1 route in `ar`, captures each, then switches `settings.language` to `en`
/// — which is what `localeProvider` reads — and drives the same routes again.
///
/// The directionality assertion is the point. A screenshot proves a screen
/// rendered; only `Directionality.of(context)` proves it rendered the right way
/// round, and a mirrored layout is the failure mode nobody notices in a
/// thumbnail.
///
/// What this CANNOT establish: that the English text is complete. Coverage is
/// roughly a tenth of the UI, so most English surfaces still show Arabic
/// literals. That is measured in the matrix, not hidden — the walk records how
/// many Arabic strings survive a switch to English, which is the honest number.
const _qaEmail = String.fromEnvironment('QA_EMAIL');
const _qaPassword = String.fromEnvironment('QA_PASSWORD');
const _qaUserId = String.fromEnvironment('QA_USER_ID');

const _routes = <String>[
  '/', '/reports', '/accounts', '/budgets', '/goals', '/cards',
  '/subscriptions', '/settings', '/help', '/privacy', '/backup',
  '/data-transfer', '/coupons', '/profile', '/achievements', '/announcements',
  '/savings', '/paste', '/subscriptions', '/referrals',
];

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  demo_seed.main();

  Future<void> settle(WidgetTester tester,
      {Duration budget = const Duration(seconds: 20)}) async {
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

  /// Every visible non-empty Text on screen.
  List<String> visibleText(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
      .where((s) => s.trim().isNotEmpty)
      .toList();

  testWidgets('every V1 route in Arabic and English, direction asserted',
      (tester) async {
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

    final container =
        ProviderScope.containerOf(tester.element(find.byType(AppShell)));
    final settingsRepo = container.read(userSettingsRepositoryProvider);

    final failures = <String>[];
    final arabicSurvivors = <String, int>{};
    final visited = <String, int>{'ar': 0, 'en': 0};
    final arabicScript = RegExp(r'[؀-ۿ]');

    Future<void> walk(String lang, TextDirection expected) async {
      final current = await settingsRepo.getSettings();
      await settingsRepo.saveSettings(current.copyWith(language: lang));
      await settle(tester, budget: const Duration(seconds: 15));

      final seen = <String>{};
      for (final route in _routes) {
        if (!seen.add(route)) continue;
        final router = GoRouter.of(tester.element(find.byType(AppShell).first));
        router.go(route);
        await settle(tester);

        if (find.textContaining('GoException').evaluate().isNotEmpty) {
          failures.add('[$lang] $route is not a route');
          continue;
        }
        if (find.byType(Scaffold).evaluate().isEmpty) {
          failures.add('[$lang] $route rendered no Scaffold');
          continue;
        }

        // THE assertion: the tree's resolved direction, not a guess from a
        // screenshot.
        final ctx = tester.element(find.byType(Scaffold).first);
        final dir = Directionality.of(ctx);
        if (dir != expected) {
          failures.add('[$lang] $route rendered $dir, expected $expected');
        }

        visited[lang] = visited[lang]! + 1;
        if (lang == 'en') {
          final arabic =
              visibleText(tester).where(arabicScript.hasMatch).length;
          if (arabic > 0) arabicSurvivors[route] = arabic;
        }
        await binding.takeScreenshot('$lang-${route.replaceAll("/", "_")}');
      }
    }

    await walk('ar', TextDirection.rtl);
    await walk('en', TextDirection.ltr);

    // Restore Arabic so a later run on this simulator starts where it expects.
    final last = await settingsRepo.getSettings();
    await settingsRepo.saveSettings(last.copyWith(language: 'ar'));
    await settle(tester);

    debugPrint('[BILINGUAL] routes walked: ar=${visited['ar']} en=${visited['en']}');
    debugPrint('[BILINGUAL] routes still showing Arabic under `en`: '
        '${arabicSurvivors.length}/${visited['en']}');
    final worst = arabicSurvivors.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final e in worst.take(20)) {
      debugPrint('[BILINGUAL]   ${e.key}: ${e.value} Arabic strings');
    }

    expect(failures, isEmpty,
        reason: 'direction or routing failures:\n${failures.join("\n")}');
  }, timeout: const Timeout(Duration(minutes: 30)));
}
