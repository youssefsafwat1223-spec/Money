import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/features/app/app_shell.dart';
import 'package:money_companion/features/common/category_catalog.dart';
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

/// Every V1 route with a screen of its own.
///
/// `/backup` is NOT here, and that is the finding that put it here as a
/// comment rather than an entry. It is a permanent redirect to
/// `/data-transfer` — cloud backup is retired in V1, `BackupScreen` has no
/// reference anywhere in `lib/` outside its own file, and the only remaining
/// cloud surface is `/backup/restore`, offered from Data Transfer when a
/// backup from an earlier build exists. The walk used to list `/backup`,
/// land on `/data-transfer`, find a Scaffold with the right direction, and
/// count it as walked — one of nineteen routes measured was never the route
/// it claimed.
const _routes = <String>[
  '/', '/reports', '/accounts', '/budgets', '/goals', '/cards',
  '/subscriptions', '/settings', '/help', '/privacy', '/backup/restore',
  '/data-transfer', '/coupons', '/profile', '/achievements', '/announcements',
  '/savings', '/paste', '/referrals',
];

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// Android renders Flutter into a SurfaceView, which neither `screencap` nor
  /// `takeScreenshot` can read until the surface is converted to an image —
  /// that is what the "Call convertFlutterSurfaceToImage() before taking a
  /// screenshot" state error means. It is a no-op-by-absence on iOS, where the
  /// call is not supported at all, so it is guarded rather than unconditional.
  ///
  /// This is also why `adb exec-out screencap` returns a solid black frame for
  /// a running Flutter app while the app is demonstrably rendering.
  var surfaceConverted = false;
  Future<void> captureReady() async {
    if (surfaceConverted || !Platform.isAndroid) return;
    await binding.convertFlutterSurfaceToImage();
    surfaceConverted = true;
  }
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

    // Captured ONCE. `AppShell` is only mounted on the shell routes, so
    // re-resolving the router inside the loop throws the moment the walk
    // reaches a standalone route like /accounts.
    final router = GoRouter.of(tester.element(find.byType(AppShell)));

    final failures = <String>[];
    final arabicSurvivors = <String, int>{};
    final survivingText = <String, List<String>>{};
    final visited = <String, int>{'ar': 0, 'en': 0};
    final arabicScript = RegExp(r'[؀-ۿ]');

    Future<void> walk(String lang, TextDirection expected) async {
      final current = await settingsRepo.getSettings();
      await settingsRepo.saveSettings(current.copyWith(language: lang));
      await settle(tester, budget: const Duration(seconds: 15));

      // `categoryCatalogProvider` is a FutureProvider keyed off the language,
      // so a language switch re-queries the whole category table. Until that
      // future resolves the tree still holds the PREVIOUS language's labels,
      // and the first route walked reads them — which is exactly what made the
      // Android run report five Arabic category names on `/` while
      // `/transactions`, walked later and rendering the same catalog, reported
      // none. Wait for the catalog to actually carry this language before
      // measuring anything.
      final catalogDeadline = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(catalogDeadline)) {
        final catalog = container.read(categoryCatalogProvider).valueOrNull;
        if (catalog != null && catalog.languageCode == lang) break;
        await settle(tester, budget: const Duration(seconds: 2));
      }

      final seen = <String>{};
      for (final route in _routes) {
        if (!seen.add(route)) continue;
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

        // The router ACTUALLY went there. Without this, a `go()` that quietly
        // no-ops leaves the PREVIOUS route on screen — which still has a
        // Scaffold and still has the right direction, so every other check
        // here passes and the route is counted as walked while showing
        // something else entirely. A redirect is not a failure (an auth guard
        // may legitimately send `/x` to `/y`), so the location is recorded
        // rather than asserted equal, and a route that lands somewhere it was
        // not sent is named.
        final landed =
            router.routerDelegate.currentConfiguration.uri.toString();
        final expectedLanding = route.split('?').first;
        if (!landed.startsWith(expectedLanding) &&
            !expectedLanding.startsWith(landed)) {
          failures.add('[$lang] $route did not navigate — landed on $landed');
          continue;
        }

        // THE assertion: the tree's resolved direction, not a guess from a
        // screenshot.
        //
        // Read EVERY Directionality in the route, not just the one above the
        // first Scaffold. 31 widgets across 19 files wrapped their content in
        // `Directionality(textDirection: TextDirection.rtl)`, all of them
        // BELOW that node — so this assertion was true where it looked and
        // false three widgets down, and English screens rendered mirrored for
        // as long as this test has existed.
        final directions = tester
            .widgetList<Directionality>(find.byType(Directionality))
            .map((d) => d.textDirection)
            .toSet();
        final wrong = directions.where((d) => d != expected).toList();
        if (wrong.isNotEmpty) {
          failures.add('[$lang] $route has ${wrong.length} '
              'Directionality node(s) set to ${wrong.join(", ")}, '
              'expected $expected');
        }

        visited[lang] = visited[lang]! + 1;
        if (lang == 'en') {
          final arabic =
              visibleText(tester).where(arabicScript.hasMatch).toList();
          if (arabic.isNotEmpty) {
            arabicSurvivors[route] = arabic.length;
            // A count says how much is left; the strings say WHERE. Without
            // them each round of closure is a guess at which widget produced
            // which leftover.
            survivingText[route] = arabic.toSet().toList();
          }
        }
        await captureReady();
        await tester.pumpAndSettle();
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
    for (final e in worst) {
      for (final t in survivingText[e.key] ?? const <String>[]) {
        debugPrint('[BILINGUAL-TEXT] ${e.key} :: ${t.replaceAll("\n", " ⏎ ")}');
      }
    }

    // Printed BEFORE the assertions. The count assertion fires first
    // otherwise, and the list that says WHICH route failed never reaches the
    // log — which is the only thing that makes the count actionable.
    for (final f in failures) {
      debugPrint('[BILINGUAL-FAIL] $f');
    }

    // Every route, in every language. A silently-skipped route would shrink
    // the denominator of "8/19" without anything else noticing.
    final expectedRoutes = _routes.toSet().length;
    expect(visited['ar'], expectedRoutes,
        reason: 'only ${visited['ar']} of $expectedRoutes routes were walked '
            'in Arabic');
    expect(visited['en'], expectedRoutes,
        reason: 'only ${visited['en']} of $expectedRoutes routes were walked '
            'in English');

    expect(failures, isEmpty,
        reason: 'direction or routing failures:\n${failures.join("\n")}');
  }, timeout: const Timeout(Duration(minutes: 30)));
}
