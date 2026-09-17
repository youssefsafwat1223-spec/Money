import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/features/app/app_shell.dart';
import 'package:money_companion/main.dart' as app;
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:money_companion/features/capture/capture_entry_sheet.dart';
import 'package:money_companion/features/capture/manual_paste_screen.dart';
import 'package:money_companion/features/goals/goal_form_screen.dart';
import 'package:money_companion/features/onboarding/ios_shortcut_guide.dart';
import 'package:money_companion/features/reporting/ui/report_config_page.dart';
import 'package:money_companion/features/subscriptions/bill_form_sheet.dart';
import 'package:money_companion/features/budgets/allocate_income_sheet.dart';
import 'package:money_companion/features/plans/plan_form_sheet.dart';
import 'package:money_companion/features/planning_sync/planning_conflicts_sheet.dart';
import 'package:money_companion/features/subscriptions/bill_details_sheet.dart';
import 'package:money_companion/features/transactions/manual_transaction_sheet.dart';
import 'package:money_companion/features/transactions/widgets/change_category_sheet.dart';
import 'package:money_companion/features/transactions/widgets/confirm_transaction_sheet.dart';
import 'package:money_companion/features/common/category_catalog.dart';

import 'demo_seed_test.dart' as demo_seed;

/// BILINGUAL SHEET WALK — the surfaces the route walk cannot reach.
///
/// The route walk covers 19 top-level routes. Everything a user actually
/// COMMITS data through is a sheet or a dialog behind a tap, and those carry
/// the validation messages, the destructive confirmations and the empty
/// states — exactly the copy that hurts most when it is in the wrong language.
///
/// This opens each one by calling its own entry point rather than hunting for
/// a button to tap. That matters: the earlier tap-everything harvest reached 7
/// modals in nine minutes and then hung, because "find a control, tap it, see
/// what opens" is not deterministic in a live app. Naming the sheets is less
/// clever and it actually finishes.
///
/// What it proves: each sheet opens, renders, and — under `en` — how much
/// Arabic survives. What it cannot prove: that the English READS well. That is
/// a human judgement on the captures.
const _qaEmail = String.fromEnvironment('QA_EMAIL');
const _qaPassword = String.fromEnvironment('QA_PASSWORD');
const _qaUserId = String.fromEnvironment('QA_USER_ID');

typedef SheetOpener = Future<void> Function(BuildContext context);

/// Only sheets that open with no argument, or with one we can supply without
/// inventing data. A sheet that needs a real entity is covered by the route
/// walk's screen instead.
/// Sheets that need nothing but a context.
final _sheets = <String, SheetOpener>{
  'goal-form': (c) => GoalFormScreen.showSheet(c),
  'bill-form': (c) => BillFormSheet.show(c),
  'capture-entry': (c) => showCaptureEntrySheet(c),
  'manual-paste': (c) => ManualPasteScreen.showSheet(c),
  'ios-shortcut-guide': (c) => showIosShortcutSheet(c),
  'report-config': (c) => showReportConfigPage(c).then((_) {}),
  'manual-transaction': (c) => ManualTransactionSheet.show(c),
  'allocate-income': (c) => AllocateIncomeSheet.show(c),
  'plan-form': (c) => PlanFormSheet.show(c),
  'planning-conflicts': (c) => PlanningConflictsSheet.show(c),
};

/// Sheets that need a real ROW to render — a transaction, a bill. They are
/// fetched from the seeded ledger through the shipping repositories rather
/// than fabricated: a made-up entity renders a shape the app never produces,
/// which is worse than not inspecting the sheet at all.
typedef DataSheetOpener = Future<void> Function(
    BuildContext context, ProviderContainer container);

/// Thrown when a row-backed sheet has no row to render. Distinct from a
/// failure: nothing is broken, there is simply nothing to show.
class _NoDataForSheet implements Exception {
  _NoDataForSheet(this.reason);
  final String reason;
  @override
  String toString() => reason;
}

final _dataSheets = <String, DataSheetOpener>{
  'change-category': (c, container) async {
    final tx = (await container.read(transactionRepositoryProvider).getRecent(
        limit: 1));
    if (tx.isEmpty) return;
    final catalog = await container.read(categoryCatalogProvider.future);
    if (!c.mounted) return;
    return showChangeCategorySheet(c, tx.first, catalog);
  },
  'confirm-transaction': (c, container) async {
    final tx = (await container.read(transactionRepositoryProvider).getRecent(
        limit: 1));
    if (tx.isEmpty) return;
    if (!c.mounted) return;
    return showConfirmTransactionSheet(c, tx.first.id);
  },
  // Opens only when the account HAS a bill. The QA ledger seeds two detected
  // subscriptions that are not enabled, so `getAll()` is empty and this sheet
  // has no row to render. Reported as unreachable-with-this-data rather than
  // as a failure: a fabricated bill would render a shape the app never
  // produces, which is worse than not inspecting the sheet.
  'bill-details': (c, container) async {
    final bills = await container.read(billRepositoryProvider).getAll();
    if (bills.isEmpty) throw _NoDataForSheet('no bill in the seeded ledger');
    if (!c.mounted) return;
    return BillDetailsSheet.show(c, bills.first);
  },
};

/// `showAccountForm` and `showCardForm` take a `WidgetRef`, which this walk has
/// no honest way to synthesise — a fabricated ref would exercise a container
/// the app never uses. They are covered instead by their widget tests, which
/// now run with the localization delegates and assert the ARB in both
/// languages. Recorded here so the gap is visible rather than implied.
const _needsWidgetRef = <String>['account-form', 'card-form'];

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

  NavigatorState navigatorOf(WidgetTester tester) =>
      tester.state<NavigatorState>(find.byType(Navigator).first);

  /// Close whatever is on top until the shell is back, bounded.
  ///
  /// One stuck sheet used to take the whole pass down; popping until the shell
  /// returns, with a bound, means a sheet that will not close costs one entry
  /// rather than the run.
  Future<void> popToShell(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      if (find.byType(AppShell).evaluate().isNotEmpty &&
          find.byType(BottomSheet).evaluate().isEmpty &&
          find.byType(Dialog).evaluate().isEmpty) {
        return;
      }
      final nav = navigatorOf(tester);
      if (!nav.canPop()) return;
      nav.pop();
      await settle(tester, budget: const Duration(seconds: 5));
    }
  }


  /// Text inside the MODAL only.
  ///
  /// Reading the whole tree reports the screen still sitting behind the sheet,
  /// which made every sheet look like it had leftover Arabic when what leaked
  /// through was Home's account and merchant names — user data, and correctly
  /// Arabic. Scope to the sheet subtree or the measurement is meaningless.
  /// The language the thing currently on top actually resolved.
  ///
  /// `Localizations.localeOf` on the SHEET's own element, not the shell's: a
  /// modal is pushed with its own context, and that is precisely where a stale
  /// one hides.
  String? localeOfTopmost(WidgetTester tester) {
    for (final type in [BottomSheet, AlertDialog, Dialog]) {
      final host = find.byType(type);
      if (host.evaluate().isEmpty) continue;
      return Localizations.localeOf(tester.element(host.first)).languageCode;
    }
    final scaffolds = find.byType(Scaffold);
    if (scaffolds.evaluate().isEmpty) return null;
    return Localizations.localeOf(tester.element(scaffolds.last)).languageCode;
  }

  List<String> modalText(WidgetTester tester) {
    for (final type in [BottomSheet, AlertDialog, Dialog]) {
      final host = find.byType(type);
      if (host.evaluate().isEmpty) continue;
      return tester
          .widgetList<Text>(find.descendant(of: host.first, matching: find.byType(Text)))
          .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
          .where((s) => s.trim().isNotEmpty)
          .toList();
    }
    // A pushed page: read the topmost Scaffold instead of the whole tree.
    final scaffolds = find.byType(Scaffold);
    if (scaffolds.evaluate().isEmpty) return const [];
    return tester
        .widgetList<Text>(
            find.descendant(of: scaffolds.last, matching: find.byType(Text)))
        .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
        .where((s) => s.trim().isNotEmpty)
        .toList();
  }

  testWidgets('every openable sheet, in Arabic and in English',
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
    if (client.auth.currentUser == null) {
      final res = await client.auth
          .signInWithPassword(email: _qaEmail, password: _qaPassword);
      expect(res.user, isNotNull, reason: 'QA sign-in failed');
      await AppSession.instance
          .setIdentity(method: 'email', email: _qaEmail, userId: res.user!.id);
    }
    await AppSession.instance.markWelcomeManifestoSeen();
    await settle(tester, budget: const Duration(seconds: 45));
    if (!AppSession.instance.hasCompletedOnboarding) {
      await AppSession.instance.finishOnboarding();
      await settle(tester, budget: const Duration(seconds: 30));
    }
    expect(await waitFor(tester, find.byType(AppShell)), isTrue,
        reason: 'shell never mounted');

    final container =
        ProviderScope.containerOf(tester.element(find.byType(AppShell)));
    final settingsRepo = container.read(userSettingsRepositoryProvider);
    final arabicScript = RegExp(r'[؀-ۿ]');

    final opened = <String, int>{'ar': 0, 'en': 0};
    final failedToOpen = <String>[];
    final unreachable = <String>[];
    final survivors = <String, List<String>>{};

    Future<void> walk(String lang) async {
      final current = await settingsRepo.getSettings();
      await settingsRepo.saveSettings(current.copyWith(language: lang));
      await settle(tester, budget: const Duration(seconds: 10));

      // The switch has to reach the WIDGET TREE before anything is measured,
      // not merely the settings row. A sheet opened from a context whose
      // `Localizations` is still the previous language renders that language
      // and looks exactly like an untranslated screen — `goal-form` reported
      // seven Arabic strings this way while its ARB entries were complete and
      // correct in English. Wait for the tree, then measure.
      final localeDeadline = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(localeDeadline)) {
        final shell = find.byType(AppShell);
        if (shell.evaluate().isNotEmpty &&
            Localizations.localeOf(tester.element(shell)).languageCode ==
                lang) {
          break;
        }
        await settle(tester, budget: const Duration(seconds: 2));
      }

      // Context-only sheets and row-backed sheets, walked as one list so the
      // measurement and the capture are identical for both kinds.
      final all = <String, SheetOpener>{
        ..._sheets,
        for (final e in _dataSheets.entries)
          e.key: (c) => e.value(c, container),
      };

      for (final entry in all.entries) {
        // Re-resolve the shell each time: closing a sheet rebuilds the tree.
        final shell = find.byType(AppShell);
        if (shell.evaluate().isEmpty) {
          failedToOpen.add('[$lang] ${entry.key}: shell gone');
          continue;
        }
        final ctx = tester.element(shell);
        var noData = false;
        unawaited(entry.value(ctx).catchError((Object e) {
          if (e is _NoDataForSheet) noData = true;
        }));
        await settle(tester);
        if (noData) {
          unreachable.add('[$lang] ${entry.key}');
          continue;
        }
        // A row-backed sheet awaits TWO repository reads before it can build,
        // so it can still be in flight when the first settle returns. Give it
        // a second window before concluding that nothing opened — the
        // difference between "slow" and "broken" is the whole point of this
        // measurement.
        if (find.byType(BottomSheet).evaluate().isEmpty &&
            find.byType(Dialog).evaluate().isEmpty &&
            find.byType(AlertDialog).evaluate().isEmpty) {
          await settle(tester, budget: const Duration(seconds: 8));
        }

        // A sheet is a modal; the report builder is a pushed PAGE. Both are
        // "something opened on top", so the test is whether the shell is no
        // longer the thing on screen — not which widget class was used.
        final isModal = find.byType(BottomSheet).evaluate().isNotEmpty ||
            find.byType(Dialog).evaluate().isNotEmpty ||
            find.byType(AlertDialog).evaluate().isNotEmpty ||
            find.byType(Scaffold).evaluate().length > 1 ||
            navigatorOf(tester).canPop();
        if (!isModal) {
          failedToOpen.add('[$lang] ${entry.key}: nothing opened');
        } else {
          opened[lang] = opened[lang]! + 1;
          if (lang == 'en') {
            // THE guard against a false positive: read the locale the sheet
            // itself resolved. If it is not `lang`, the sheet was built from a
            // stale context and its Arabic says nothing about whether the copy
            // is translated. Record it as a failure to MEASURE rather than as
            // untranslated copy — the two need different fixes and must not be
            // reported as the same thing.
            final sheetLocale = localeOfTopmost(tester);
            if (sheetLocale != null && sheetLocale != lang) {
              failedToOpen.add('[$lang] ${entry.key}: rendered in '
                  '$sheetLocale — stale Localizations, not untranslated copy');
              await popToShell(tester);
              continue;
            }
            final arabic = modalText(tester)
                .where(arabicScript.hasMatch)
                .toSet()
                .toList();
            if (arabic.isNotEmpty) survivors[entry.key] = arabic;
          }
          await binding.takeScreenshot('sheet-$lang-${entry.key}');
        }

        // Pop until the shell is back. A single pop was not enough: one sheet
        // that failed to close took the ENTIRE English pass down with it,
        // because every later opener needs the shell's context.
        await popToShell(tester);
      }
    }

    await walk('ar');
    await walk('en');

    final last = await settingsRepo.getSettings();
    await settingsRepo.saveSettings(last.copyWith(language: 'ar'));
    await settle(tester);

    debugPrint('[SHEETS] opened: ar=${opened['ar']} en=${opened['en']} '
        'of ${_sheets.length}');
    debugPrint('[SHEETS] not reachable from here (need a WidgetRef): '
        '${_needsWidgetRef.join(", ")}');
    for (final u in unreachable) {
      debugPrint('[SHEETS] no data to render: $u');
    }
    for (final f in failedToOpen) {
      debugPrint('[SHEETS] could not open: $f');
    }
    debugPrint('[SHEETS] sheets still showing Arabic under `en`: '
        '${survivors.length}/${opened['en']}');
    for (final e in survivors.entries) {
      for (final t in e.value) {
        debugPrint('[SHEETS-TEXT] ${e.key} :: ${t.replaceAll("\n", " ⏎ ")}');
      }
    }

    // The walk is evidence, not a gate on the English count — that number is
    // recorded in the matrix and closed screen by screen. What IS asserted is
    // that every sheet still opens in both languages, because a localization
    // change that breaks a sheet is a regression, not a translation gap.
    expect(failedToOpen, isEmpty,
        reason: 'a sheet that does not open cannot be verified in either '
            'language');
  });
}
