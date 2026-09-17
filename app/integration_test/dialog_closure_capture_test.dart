import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/security/secure_storage_options.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/utils/l10n_ext.dart';
import 'package:money_companion/features/app/app_shell.dart';
import 'package:money_companion/features/goals/goal_form_screen.dart';
import 'package:money_companion/features/plans/plan_form_sheet.dart';
import 'package:money_companion/features/transactions/manual_transaction_sheet.dart';
import 'package:money_companion/main.dart' as app;
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import 'demo_seed_test.dart' as demo_seed;

/// DIALOG CLOSURE — the Atlas dialog designs beyond `DLG-DESTRUCTIVE-CONFIRM`.
///
/// §6 of the visual matrix closed with a one-line admission: "the remaining 12
/// dialog designs in the Atlas" were not inspected. Of the eleven the Atlas
/// actually enumerates, one had been opened. This file opens the rest that a
/// signed-in iOS device can reach.
///
/// Two of them are system pickers — `showDatePicker` and `showTimePicker`. They
/// are Material's, not this app's, which is exactly why they are worth opening:
/// the app passes them arguments, and an argument passed wrong is invisible in
/// every test that never renders the picker.
///
/// `demo_seed` runs first and seeds the ledger these surfaces need.
const _qaEmail = String.fromEnvironment('QA_EMAIL');
const _qaPassword = String.fromEnvironment('QA_PASSWORD');
const _qaUserId = String.fromEnvironment('QA_USER_ID');

/// Raised when a dialog cannot be reached because no row in the QA ledger
/// produces it. Recorded separately from a failure — "nothing to show" and
/// "broken" are different findings and collapsing them hides both.
class _NoData implements Exception {
  _NoData(this.reason);
  final String reason;
  @override
  String toString() => reason;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // DISARM THE APP LOCK BEFORE ANY TEST RUNS.
  //
  // `AppLockGate` locks on the first frame when this flag is set, and asks iOS
  // to authenticate. On a Simulator that prompt is the device-passcode sheet,
  // which is a NATIVE view sitting above Flutter and cannot be satisfied — the
  // shell never mounts and every test in the file dies on "shell never
  // mounted", including ones that have nothing to do with the lock.
  //
  // The flag is sticky: `visual_closure_capture_test` turns it on to capture
  // the locked screen, and a run killed between the capture and its restore
  // leaves the device unlaunchable. Two runs were lost to exactly that before
  // the cause was found, so clearing it is a precondition of every capture
  // file rather than a courtesy of the one that sets it.
  setUpAll(() async {
    await SecureStorageOptions.storage
        .write(key: 'app_lock_enabled', value: '0');
  });

  // Runs FIRST, and not only for the ledger. Dropping it to save four minutes
  // cost a whole run: with this file's `app.main()` the first in the process,
  // the shell never mounted and the walk died on "shell never mounted". Every
  // capture file in this repo calls `app.main()` as the SECOND caller, behind
  // demo_seed — that is the configuration they are known to work in.
  demo_seed.main();

  var surfaceConverted = false;
  Future<void> captureReady() async {
    if (surfaceConverted || !Platform.isAndroid) return;
    await binding.convertFlutterSurfaceToImage();
    surfaceConverted = true;
  }

  Future<void> settle(WidgetTester tester,
      {Duration budget = const Duration(seconds: 8)}) async {
    final deadline = DateTime.now().add(budget);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
      if (!tester.binding.hasScheduledFrame) break;
    }
  }

  Future<bool> waitFor(WidgetTester tester, Finder f,
      {Duration timeout = const Duration(seconds: 20)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
      if (f.evaluate().isNotEmpty) return true;
    }
    return false;
  }

  testWidgets('dialog designs, both languages', (tester) async {
    WidgetController.hitTestWarningShouldBeFatal = false;
    void phase(String s) => debugPrint('[DLG-PHASE] $s');

    phase('app.main');
    app.main();
    await settle(tester, budget: const Duration(seconds: 45));

    if (_qaEmail.isEmpty) fail('QA_EMAIL/QA_PASSWORD/QA_USER_ID are required');
    final owner = await AppSession.instance.readLocalDataOwnerUid();
    if (owner != null && owner != _qaUserId) {
      fail('ABORT — the local database belongs to another account.');
    }
    final client = supabase.Supabase.instance.client;
    phase('sign in');
    String? userId;
    try {
      final res = await client.auth
          .signInWithPassword(email: _qaEmail, password: _qaPassword)
          .timeout(const Duration(seconds: 60));
      userId = res.user?.id;
    } catch (e) {
      debugPrint('[DLG-PHASE] sign in failed/timed out: $e');
      userId = client.auth.currentUser?.id;
    }
    if (userId == null) fail('no session restored and none established');
    if (userId != _qaUserId) fail('ABORT — signed in as $userId');
    await AppSession.instance
        .setIdentity(method: 'email', email: _qaEmail, userId: userId);
    try {
      await AppSession.instance
          .reconcileAccountOnboarding(client)
          .timeout(const Duration(seconds: 60));
    } catch (e) {
      debugPrint('[DLG-PHASE] reconcile failed/timed out: $e');
    }
    await AppSession.instance.markWelcomeManifestoSeen();
    await settle(tester, budget: const Duration(seconds: 30));
    if (!AppSession.instance.hasCompletedOnboarding) {
      await AppSession.instance.finishOnboarding();
      await settle(tester, budget: const Duration(seconds: 20));
    }
    expect(await waitFor(tester, find.byType(AppShell),
            timeout: const Duration(seconds: 90)),
        isTrue,
        reason: 'shell never mounted');

    final shellElement = tester.element(find.byType(AppShell));
    final container = ProviderScope.containerOf(shellElement);
    final settingsRepo = container.read(userSettingsRepositoryProvider);
    final router = GoRouter.of(shellElement);

    final failures = <String>[];
    final captured = <String>[];
    final noData = <String>[];

    Future<void> home() async {
      router.go('/');
      await settle(tester, budget: const Duration(seconds: 10));
    }

    Future<void> popAll() async {
      for (var i = 0; i < 8; i++) {
        final scaffold = find.byType(Scaffold);
        if (scaffold.evaluate().isEmpty) break;
        final nav = Navigator.of(tester.element(scaffold.first));
        if (!nav.canPop()) break;
        nav.pop();
        await settle(tester, budget: const Duration(seconds: 3));
      }
      await home();
    }

    Future<void> shoot(String lang, String name) async {
      await captureReady();
      await settle(tester, budget: const Duration(seconds: 2));
      await binding.takeScreenshot('dlg-$lang-$name');
      captured.add('$lang/$name');
      debugPrint('[DLG-PHASE] captured $lang/$name');
    }

    Element host() => tester.element(find.byType(Scaffold).first);

    Future<void> tapText(String text) async {
      final f = find.text(text);
      if (f.evaluate().isEmpty) throw StateError('no control labelled "$text"');
      try {
        await tester.ensureVisible(f.first);
        await settle(tester, budget: const Duration(seconds: 2));
      } catch (_) {
        // Not in a scrollable, or already visible.
      }
      await tester.tap(f.first, warnIfMissed: false);
      await settle(tester, budget: const Duration(seconds: 6));
    }

    Future<void> dialog(
        String lang, String name, Future<void> Function() body) async {
      debugPrint('[DLG-PHASE] start $lang/$name');
      try {
        await body();
        debugPrint('[DLG-PHASE] ok $lang/$name');
      } on _NoData catch (e) {
        noData.add('[$lang] $name: $e');
        debugPrint('[DLG-PHASE] no data $lang/$name: $e');
      } catch (e) {
        failures.add('[$lang] $name: $e');
        debugPrint('[DLG-PHASE] FAIL $lang/$name: $e');
      } finally {
        try {
          await popAll();
        } catch (e) {
          failures.add('[$lang] $name: could not close — $e');
        }
      }
    }

    Future<void> walk(String lang) async {
      final current = await settingsRepo.getSettings();
      await settingsRepo.saveSettings(current.copyWith(language: lang));
      await home();
      final deadline = DateTime.now().add(const Duration(seconds: 25));
      var carried = false;
      while (DateTime.now().isBefore(deadline)) {
        final s = find.byType(Scaffold);
        if (s.evaluate().isNotEmpty &&
            Localizations.localeOf(tester.element(s.first)).languageCode ==
                lang) {
          carried = true;
          break;
        }
        await settle(tester, budget: const Duration(seconds: 2));
      }
      if (!carried) {
        failures.add('[$lang] the tree never carried the language');
        return;
      }

      // ── DLG-DATE-PICKER, from the goal form ──────────────────────────────
      // This call site passes `locale: const Locale('ar')`. Nine of the
      // eleven pickers in the app do not, so this is the one to look at.
      await dialog(lang, 'date-picker-goal', () async {
        unawaited(GoalFormScreen.showSheet(host()));
        await settle(tester, budget: const Duration(seconds: 8));
        await tapText(host().l10n.gfDeadline);
        if (find.byType(DatePickerDialog).evaluate().isEmpty) {
          throw StateError('the date picker did not open');
        }
        await shoot(lang, 'date-picker-goal');
      });

      // ── DLG-DATE-PICKER, from a call site that does NOT pin the locale ───
      // Captured for contrast: the two frames sit next to each other in the
      // evidence, and under `en` they should read the same language.
      await dialog(lang, 'date-picker-plan', () async {
        unawaited(PlanFormSheet.show(host()));
        await settle(tester, budget: const Duration(seconds: 8));
        final calendar = find.byIcon(Icons.calendar_today);
        if (calendar.evaluate().isNotEmpty) {
          await tester.tap(calendar.first, warnIfMissed: false);
          await settle(tester, budget: const Duration(seconds: 6));
        }
        if (find.byType(DatePickerDialog).evaluate().isEmpty) {
          throw _NoData('the plan form date field was not identifiable');
        }
        await shoot(lang, 'date-picker-plan');
      });

      // ── DLG-TIME-PICKER, from the manual transaction sheet ───────────────
      // The date picker comes first and has to be accepted before the time
      // picker exists at all.
      await dialog(lang, 'time-picker', () async {
        unawaited(ManualTransactionSheet.show(host()));
        await settle(tester, budget: const Duration(seconds: 8));
        final clock = find.byIcon(Icons.access_time);
        final cal = find.byIcon(Icons.calendar_today);
        final trigger = clock.evaluate().isNotEmpty ? clock : cal;
        if (trigger.evaluate().isEmpty) {
          throw _NoData('the date/time field was not identifiable by icon');
        }
        await tester.tap(trigger.first, warnIfMissed: false);
        await settle(tester, budget: const Duration(seconds: 6));
        if (find.byType(DatePickerDialog).evaluate().isNotEmpty) {
          await shoot(lang, 'date-picker-manual-tx');
          // Accept the date so the time picker opens behind it. The confirm
          // label comes from MaterialLocalizations, which means it is Arabic
          // under `ar` — finding it by the literal "OK" would work in exactly
          // one of the two languages this walk exists to compare.
          final ok = find.text(MaterialLocalizations.of(
                  tester.element(find.byType(DatePickerDialog).first))
              .okButtonLabel);
          if (ok.evaluate().isNotEmpty) {
            await tester.tap(ok.first, warnIfMissed: false);
            await settle(tester, budget: const Duration(seconds: 6));
          }
        }
        if (find.byType(TimePickerDialog).evaluate().isEmpty) {
          throw _NoData('the time picker did not follow the date picker');
        }
        await shoot(lang, 'time-picker');
      });

      // ── DLG-VALUE-INPUT, from transaction details ────────────────────────
      await dialog(lang, 'value-input', () async {
        final txns = await container
            .read(transactionRepositoryProvider)
            .getRecent(limit: 1);
        if (txns.isEmpty) throw _NoData('no transaction in the ledger');
        router.go('/transaction/${txns.first.id}');
        await settle(tester, budget: const Duration(seconds: 14));
        final add = find.textContaining(
            host().l10n.txdAddValueIn('').replaceAll('()', '').trim());
        if (add.evaluate().isEmpty) {
          throw _NoData('this transaction already carries a value, so the '
              'add-value control is not shown');
        }
        await tester.tap(add.first, warnIfMissed: false);
        await settle(tester, budget: const Duration(seconds: 6));
        if (find.byType(AlertDialog).evaluate().isEmpty) {
          throw StateError('the value dialog did not open');
        }
        await shoot(lang, 'value-input');
      });

      // ── DLG-BULK-CONFIRM, from the transactions review queue ─────────────
      await dialog(lang, 'bulk-confirm', () async {
        final pending = await container
            .read(transactionRepositoryProvider)
            .getRecent(limit: 200);
        final anyPending = pending.any((t) => t.status.name == 'pending');
        if (!anyPending) {
          throw _NoData('the seeded ledger holds no pending capture, so the '
              'confirm-all control is not rendered');
        }
        container.read(shellIndexProvider.notifier).state = 1;
        await settle(tester, budget: const Duration(seconds: 12));
        await tapText(host().l10n.txnConfirmAll);
        if (find.text(host().l10n.txnConfirmAllTitle).evaluate().isEmpty) {
          throw StateError('the bulk-confirm dialog did not open');
        }
        await shoot(lang, 'bulk-confirm');
      });
    }

    await walk('ar');
    await walk('en');

    final last = await settingsRepo.getSettings();
    await settingsRepo.saveSettings(last.copyWith(language: 'ar'));
    await settle(tester);

    debugPrint('[DLG] captured ${captured.length}: ${captured.join(", ")}');
    for (final n in noData) {
      debugPrint('[DLG-NODATA] $n');
    }
    for (final f in failures) {
      debugPrint('[DLG-FAIL] $f');
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
  }, timeout: const Timeout(Duration(minutes: 40)));
}
