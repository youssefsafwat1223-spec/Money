import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:money_companion/core/utils/l10n_ext.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/features/app/app_shell.dart';
import 'package:money_companion/main.dart' as app;
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import 'demo_seed_test.dart' as demo_seed;

/// DETAIL AND FORM ROUTES — the shipping screens the route walk cannot reach.
///
/// `bilingual_walk_test` walks the 19 routes that take no parameter. Every
/// detail and form screen needs an id — a transaction, an account, a card, a
/// goal — so none of them has ever been walked, captured or direction-checked,
/// in either language.
///
/// That is a real hole rather than a technicality: `goal_details_screen.dart`
/// alone held two of the thirty-one widgets that forced `TextDirection.rtl`,
/// and `budget_form_screen.dart` and `card_form_sheet.dart` held one each. The
/// screens most likely to be wrong were the ones nothing opened.
///
/// Ids come from the seeded ledger through the shipping repositories. A
/// fabricated id renders an error state, which would be inspecting the error
/// state and calling it the screen.
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
      {Duration budget = const Duration(seconds: 15)}) async {
    final deadline = DateTime.now().add(budget);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
      if (!tester.binding.hasScheduledFrame) break;
    }
  }

  testWidgets('detail and form routes, both languages', (tester) async {
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

    // ---- resolve real ids from the seeded ledger -----------------------
    final txs = await container.read(transactionRepositoryProvider).getRecent(
        limit: 1);
    final accounts = await container.read(accountRepositoryProvider).getAll();
    final cards = await container.read(cardRepositoryProvider).getAll();
    final goals = await container.read(goalRepositoryProvider).getAll();
    final budgets = await container.read(budgetRepositoryProvider).getAll();

    final routes = <String, String>{
      if (txs.isNotEmpty) 'transaction-details': '/transaction/${txs.first.id}',
      if (accounts.isNotEmpty) 'account-detail': '/account/${accounts.first.id}',
      if (cards.isNotEmpty) 'card-details': '/card/${cards.first.last4}',
      if (goals.isNotEmpty) 'goal-details': '/goals/${goals.first.id}',
      'goal-new': '/goals/new',
      'budget-new': '/budgets/new',
      if (budgets.isNotEmpty)
        'budget-edit': '/budgets/${budgets.first.id}/edit',
      'sms-permission': '/capture/sms-permission',
      'planning-currency-repair': '/settings/planning-currency-repair',
    };

    final failures = <String>[];
    final captured = <String>[];
    final arabicScript = RegExp(r'[؀-ۿ]');
    final survivors = <String, List<String>>{};

    Future<void> walk(String lang, TextDirection expected) async {
      final current = await settingsRepo.getSettings();
      await settingsRepo.saveSettings(current.copyWith(language: lang));
      await settle(tester, budget: const Duration(seconds: 10));

      // The switch must reach the WIDGET TREE before the first route is
      // measured, not merely the settings row. Without this the FIRST route
      // walked reads the previous language and reports every string on it as
      // untranslated — `transaction-details` reported 21 that way while its
      // ARB entries were complete. The route walk and the sheet walk both
      // learned this the same way.
      final localeDeadline = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(localeDeadline)) {
        final shell = find.byType(AppShell);
        if (shell.evaluate().isNotEmpty &&
            Localizations.localeOf(tester.element(shell.first)).languageCode ==
                lang) {
          break;
        }
        await settle(tester, budget: const Duration(seconds: 2));
      }

      for (final entry in routes.entries) {
        router.go(entry.value);
        await settle(tester, budget: const Duration(seconds: 25));

        if (find.textContaining('GoException').evaluate().isNotEmpty) {
          failures.add('[$lang] ${entry.key}: not a route (${entry.value})');
          continue;
        }
        if (find.byType(Scaffold).evaluate().isEmpty) {
          failures.add('[$lang] ${entry.key}: no Scaffold');
          continue;
        }

        // Every Directionality in the screen, not just the topmost — the
        // forced-RTL wrappers all sat below the first Scaffold, which is how
        // they survived a direction assertion for this long.
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
                .widgetList<Directionality>(find.byType(Directionality))
                .map((d) => d.textDirection)
                .where((d) => d == TextDirection.rtl)
                .toList()
            : const <TextDirection>[];
        if (wrong.isNotEmpty) {
          failures.add('[$lang] ${entry.key}: ${wrong.length} Directionality '
              'node(s) set to ${wrong.join(", ")}, expected $expected');
        }

        if (lang == 'en') {
          final arabic = tester
              .widgetList<Text>(find.byType(Text))
              .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
              .where((s) => s.trim().isNotEmpty)
              .where(arabicScript.hasMatch)
              .toSet()
              .toList();
          if (arabic.isNotEmpty) survivors[entry.key] = arabic;
        }

        await captureReady();
        // BOUNDED, not `pumpAndSettle`. A skeleton shimmer or an indeterminate
        // spinner never reaches quiescence, so `pumpAndSettle` times out and
        // takes the whole pass with it — which is exactly what happened on the
        // first run of this file. The route walk has used a bounded pump for
        // the same reason since it was written.
        await settle(tester, budget: const Duration(seconds: 4));
        await binding.takeScreenshot('detail-$lang-${entry.key}');
        captured.add('$lang/${entry.key}');
      }
      // ---- DIALOGS ---------------------------------------------------
      //
      // `DLG-DESTRUCTIVE-CONFIRM` is ONE design reused for twelve nouns —
      // delete budget, transaction, card, goal, plan, account, bill, payment,
      // category, erase all data, cancel account deletion. Opening it once
      // accepts the design; the twelve are copy variants of the same frame.
      //
      // Reached the way a user reaches it: from goal details, which is already
      // loaded above, by tapping Delete.
      if (goals.isNotEmpty) {
        router.go('/goals/${goals.first.id}');
        await settle(tester, budget: const Duration(seconds: 20));
        final l = tester.element(find.byType(Scaffold).first).l10n;
        final del = find.text(l.gdDeleteGoal);
        if (del.evaluate().isEmpty) {
          failures.add('[$lang] destructive-confirm: '
              'no "${l.gdDeleteGoal}" control');
        } else {
          await tester.ensureVisible(del.first);
          await settle(tester, budget: const Duration(seconds: 3));
          await tester.tap(del.first, warnIfMissed: false);
          await settle(tester, budget: const Duration(seconds: 8));
          if (find.byType(AlertDialog).evaluate().isEmpty &&
              find.byType(Dialog).evaluate().isEmpty) {
            failures.add('[$lang] destructive-confirm: nothing opened');
          } else {
            if (expected == TextDirection.ltr) {
              final host = find.byType(AlertDialog).evaluate().isNotEmpty
                  ? find.byType(AlertDialog).first
                  : find.byType(Dialog).first;
              final wrong = tester
                  .widgetList<Directionality>(find.descendant(
                      of: host, matching: find.byType(Directionality)))
                  .map((d) => d.textDirection)
                  .where((d) => d == TextDirection.rtl)
                  .toList();
              if (wrong.isNotEmpty) {
                failures.add('[$lang] destructive-confirm: '
                    '${wrong.length} forced-RTL node(s)');
              }
            }
            await captureReady();
            await settle(tester, budget: const Duration(seconds: 3));
            await binding.takeScreenshot('detail-$lang-destructive-confirm');
            captured.add('$lang/destructive-confirm');
            // Dismiss WITHOUT confirming — this dialog deletes a goal.
            final nav = Navigator.of(tester.element(find.byType(Scaffold).first));
            if (nav.canPop()) nav.pop();
            await settle(tester, budget: const Duration(seconds: 5));
          }
        }
      }

      // ---- the shell TABS -------------------------------------------
      //
      // `TransactionsScreen` is tab 1 and has NO route. The route walk
      // therefore never reaches it, and it is the second-busiest screen in the
      // app — five of the thirty-one forced-RTL wrappers lived in it. Dashboard
      // (0), Budgets (2), Settings (3) and Reports (4) are also routes and are
      // already covered; only tab 1 is reachable no other way.
      router.go('/');
      await settle(tester, budget: const Duration(seconds: 15));
      container.read(shellIndexProvider.notifier).state = 1;
      await settle(tester, budget: const Duration(seconds: 25));

      final tabWrong = expected == TextDirection.ltr
          ? tester
              .widgetList<Directionality>(find.byType(Directionality))
              .map((d) => d.textDirection)
              .where((d) => d == TextDirection.rtl)
              .toList()
          : const <TextDirection>[];
      if (tabWrong.isNotEmpty) {
        failures.add('[$lang] transactions-tab: ${tabWrong.length} '
            'Directionality node(s) set to ${tabWrong.join(", ")}, '
            'expected $expected');
      }
      if (lang == 'en') {
        final arabic = tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
            .where((s) => s.trim().isNotEmpty)
            .where(arabicScript.hasMatch)
            .toSet()
            .toList();
        if (arabic.isNotEmpty) survivors['transactions-tab'] = arabic;
      }
      await captureReady();
      await settle(tester, budget: const Duration(seconds: 4));
      await binding.takeScreenshot('detail-$lang-transactions-tab');
      captured.add('$lang/transactions-tab');

      container.read(shellIndexProvider.notifier).state = 0;
      await settle(tester, budget: const Duration(seconds: 10));
    }

    await walk('ar', TextDirection.rtl);
    await walk('en', TextDirection.ltr);

    final last = await settingsRepo.getSettings();
    await settingsRepo.saveSettings(last.copyWith(language: 'ar'));
    await settle(tester);

    debugPrint('[DETAIL] routes resolved: ${routes.length}');
    debugPrint('[DETAIL] captured: ${captured.length}');
    debugPrint('[DETAIL] showing Arabic under `en`: ${survivors.length}');
    for (final e in survivors.entries) {
      for (final t in e.value) {
        debugPrint('[DETAIL-TEXT] ${e.key} :: ${t.replaceAll("\n", " ⏎ ")}');
      }
    }
    for (final f in failures) {
      debugPrint('[DETAIL-FAIL] $f');
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
    // routes × 2 languages, plus the transactions tab and the destructive
    // confirmation dialog in each.
    expect(captured.length, (routes.length + 2) * 2,
        reason: 'captured ${captured.length}, expected '
            '${(routes.length + 2) * 2}');
  }, timeout: const Timeout(Duration(minutes: 30)));
}
