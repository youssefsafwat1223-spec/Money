import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/utils/l10n_ext.dart';
import 'package:money_companion/features/app/app_shell.dart';
import 'package:money_companion/main.dart' as app;
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import 'demo_seed_test.dart' as demo_seed;

/// SETTINGS OVERLAYS — the three sheets the sheet walk cannot reach.
///
/// `_showCategoriesSheet`, `_showSettingsPicker` (country and base currency)
/// are PRIVATE functions triggered by an `onTap` on a settings row. There is
/// no opener to call, so they are reached the only way a user reaches them:
/// by tapping the row.
///
/// They matter disproportionately. Four of the thirty-one widgets that forced
/// `TextDirection.rtl` regardless of locale lived in exactly these builders,
/// so these sheets rendered mirrored under `en` — and nothing in the suite
/// opened them, which is why that survived. A sheet nobody looks at is a sheet
/// nobody checks.
///
/// This captures them in both languages and asserts the property the
/// screenshots are there to confirm: every `Directionality` inside the open
/// overlay agrees with the app's language.
const _qaEmail = String.fromEnvironment('QA_EMAIL');
const _qaPassword = String.fromEnvironment('QA_PASSWORD');
const _qaUserId = String.fromEnvironment('QA_USER_ID');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  demo_seed.main();

  var surfaceConverted = false;
  Future<void> captureReady() async {
    if (surfaceConverted || !Platform.isAndroid) return;
    await binding.convertFlutterSurfaceToImage();
    surfaceConverted = true;
  }

  Future<void> settle(WidgetTester tester,
      {Duration budget = const Duration(seconds: 12)}) async {
    final deadline = DateTime.now().add(budget);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
      if (!tester.binding.hasScheduledFrame) break;
    }
  }

  testWidgets('settings overlays, both languages', (tester) async {
    WidgetController.hitTestWarningShouldBeFatal = false;

    app.main();
    await settle(tester, budget: const Duration(seconds: 60));

    if (_qaEmail.isEmpty) fail('QA_EMAIL/QA_PASSWORD/QA_USER_ID are required');
    final owner = await AppSession.instance.readLocalDataOwnerUid();
    if (owner != null && owner != _qaUserId) {
      fail('ABORT — the local database belongs to another account.');
    }
    final client = supabase.Supabase.instance.client;
    final res = await client.auth
        .signInWithPassword(email: _qaEmail, password: _qaPassword);
    await AppSession.instance
        .setIdentity(method: 'email', email: _qaEmail, userId: res.user!.id);
    await AppSession.instance.reconcileAccountOnboarding(client);
    await AppSession.instance.markWelcomeManifestoSeen();
    await settle(tester, budget: const Duration(seconds: 45));
    if (!AppSession.instance.hasCompletedOnboarding) {
      await AppSession.instance.finishOnboarding();
      await settle(tester, budget: const Duration(seconds: 30));
    }
    expect(find.byType(AppShell), findsWidgets, reason: 'shell never mounted');

    final container =
        ProviderScope.containerOf(tester.element(find.byType(AppShell)));
    final settingsRepo = container.read(userSettingsRepositoryProvider);
    final router = GoRouter.of(tester.element(find.byType(AppShell)));

    final failures = <String>[];
    final captured = <String>[];

    Future<void> walk(String lang, TextDirection expected) async {
      final current = await settingsRepo.getSettings();
      await settingsRepo.saveSettings(current.copyWith(language: lang));
      await settle(tester, budget: const Duration(seconds: 10));

      router.go('/settings');
      await settle(tester, budget: const Duration(seconds: 20));

      // Wait for the tree to actually carry the language before reading a
      // label from it — a stale `Localizations` would make every `find.text`
      // below miss, and a miss is indistinguishable from a moved row.
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(deadline)) {
        final shell = find.byType(Scaffold);
        if (shell.evaluate().isNotEmpty &&
            Localizations.localeOf(tester.element(shell.first)).languageCode ==
                lang) {
          break;
        }
        await settle(tester, budget: const Duration(seconds: 2));
      }

      final l = tester.element(find.byType(Scaffold).first).l10n;
      final rows = <String, String>{
        'categories': l.setCategories,
        'country': l.setCountry,
        'base-currency': l.setBaseCurrency,
      };

      for (final entry in rows.entries) {
        final row = find.text(entry.value);
        if (row.evaluate().isEmpty) {
          failures.add('[$lang] ${entry.key}: row "${entry.value}" not found');
          continue;
        }
        await tester.ensureVisible(row.first);
        await settle(tester, budget: const Duration(seconds: 3));
        await tester.tap(row.first, warnIfMissed: false);
        await settle(tester, budget: const Duration(seconds: 8));

        final isOpen = find.byType(BottomSheet).evaluate().isNotEmpty ||
            find.byType(Dialog).evaluate().isNotEmpty;
        if (!isOpen) {
          failures.add('[$lang] ${entry.key}: nothing opened');
          continue;
        }

        // THE assertion the screenshot exists to support. Four of the widgets
        // that forced RTL lived in these builders.
        final host = find.byType(BottomSheet).evaluate().isNotEmpty
            ? find.byType(BottomSheet).first
            : find.byType(Dialog).first;
        // Asserted in ONE direction, deliberately: no node may force RTL
        // while the app is English. That is the defect class — mirrored
        // layouts wearing English text.
        //
        // The reverse is NOT a defect. LTR islands inside an Arabic screen are
        // correct and intentional: a card number «•••• 4471», an email
        // address, a coupon code and the bottom-nav row (whose curated order
        // keeps Home centred) all read left-to-right in every language. An
        // assertion that demanded uniformity would flag all of them and teach
        // the next reader to weaken it.
        final wrong = expected == TextDirection.ltr
            ? tester
                .widgetList<Directionality>(find.descendant(
                    of: host, matching: find.byType(Directionality)))
                .map((d) => d.textDirection)
                .where((d) => d == TextDirection.rtl)
                .toList()
            : const <TextDirection>[];
        if (wrong.isNotEmpty) {
          failures.add('[$lang] ${entry.key}: ${wrong.length} Directionality '
              'node(s) set to ${wrong.join(", ")}, expected $expected');
        }

        await captureReady();
        // BOUNDED, not `pumpAndSettle`. A skeleton shimmer or an indeterminate
        // spinner never reaches quiescence, so `pumpAndSettle` times out and
        // takes the whole pass with it — which is exactly what happened on the
        // first run of this file. The route walk has used a bounded pump for
        // the same reason since it was written.
        await settle(tester, budget: const Duration(seconds: 4));
        await binding.takeScreenshot('settings-$lang-${entry.key}');
        captured.add('$lang/${entry.key}');

        // Close whatever opened, bounded.
        for (var i = 0; i < 4; i++) {
          final nav = Navigator.of(tester.element(find.byType(Scaffold).first));
          if (!nav.canPop()) break;
          nav.pop();
          await settle(tester, budget: const Duration(seconds: 4));
          if (find.byType(BottomSheet).evaluate().isEmpty &&
              find.byType(Dialog).evaluate().isEmpty) {
            break;
          }
        }
      }
    }

    await walk('ar', TextDirection.rtl);
    await walk('en', TextDirection.ltr);

    final last = await settingsRepo.getSettings();
    await settingsRepo.saveSettings(last.copyWith(language: 'ar'));
    await settle(tester);

    debugPrint('[SETTINGS-OVL] captured: ${captured.join(", ")}');
    for (final f in failures) {
      debugPrint('[SETTINGS-OVL-FAIL] $f');
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
    expect(captured.length, 6,
        reason: 'expected 3 overlays × 2 languages, got ${captured.length}');
  }, timeout: const Timeout(Duration(minutes: 25)));
}
