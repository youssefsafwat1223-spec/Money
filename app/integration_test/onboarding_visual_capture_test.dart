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
import 'package:money_companion/features/onboarding/auth_screen.dart';
import 'package:money_companion/features/onboarding/brand_screen.dart';
import 'package:money_companion/features/onboarding/setup_screen.dart';
import 'package:money_companion/features/onboarding/story_screen.dart';
import 'package:money_companion/main.dart' as app;
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import 'demo_seed_test.dart' as demo_seed;

/// FIRST-RUN ONBOARDING — the four screens an App Store reviewer sees first.
///
/// DESTRUCTIVE, and runs alone. `AppSession.signOut` is wired to the local data
/// wipe, so the seeded ledger every other runtime capture depends on is gone
/// the moment this file gets past its second phase. `demo_seed` is registered
/// AFTER the capture below precisely so the ledger is rebuilt before the run
/// ends — order of registration is order of execution.
///
/// §6 of the visual matrix gave protecting that ledger as the reason these four
/// were never opened. That was the wrong trade: the ledger is reproducible in
/// one command and the onboarding flow is the first thing a stranger sees.
///
/// Unique frames, not routes — `/welcome` is a two-page `PageView` and
/// `/onboarding/setup` a three-step form, so eight frames come out of four
/// routes, each in both languages.
const _qaEmail = String.fromEnvironment('QA_EMAIL');
const _qaPassword = String.fromEnvironment('QA_PASSWORD');
const _qaUserId = String.fromEnvironment('QA_USER_ID');

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

  // Registered TWICE, deliberately. First so this file's `app.main()` is the
  // second in the process (the first one does not mount a shell — a run was
  // lost to that), and last so the ledger the sign-out wipes is rebuilt before
  // the run ends.
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
      await tester.pump(const Duration(milliseconds: 150));
      if (!tester.binding.hasScheduledFrame) break;
    }
  }

  Future<bool> waitFor(WidgetTester tester, Finder f,
      {Duration timeout = const Duration(seconds: 30)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 150));
      if (f.evaluate().isNotEmpty) return true;
    }
    return false;
  }

  testWidgets('first-run onboarding, both languages', (tester) async {
    WidgetController.hitTestWarningShouldBeFatal = false;

    final failures = <String>[];
    final captured = <String>[];
    final notes = <String>[];

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
    expect(await waitFor(tester, find.byType(AppShell),
            timeout: const Duration(seconds: 90)),
        isTrue,
        reason: 'shell never mounted');

    final shellElement = tester.element(find.byType(AppShell));
    final container = ProviderScope.containerOf(shellElement);
    final settingsRepo = container.read(userSettingsRepositoryProvider);
    final router = GoRouter.of(shellElement);

    Future<void> shoot(String lang, String name) async {
      await captureReady();
      await settle(tester, budget: const Duration(seconds: 3));
      await binding.takeScreenshot('onb-$lang-$name');
      captured.add('$lang/$name');
    }

    /// The locale the tree is actually carrying, at the top-most Scaffold.
    /// Recorded next to every capture: after the wipe these screens read their
    /// language from a table that has just been through a sign-out, and an
    /// assumed language is exactly how three earlier walks mis-read stale copy
    /// as untranslated.
    String observedLanguage(WidgetTester tester) {
      final s = find.byType(Scaffold);
      if (s.evaluate().isEmpty) return 'no-scaffold';
      return Localizations.localeOf(tester.element(s.first)).languageCode;
    }

    // ── sign out through the UI, exactly as a user does ────────────────────
    router.go('/settings');
    await settle(tester, budget: const Duration(seconds: 25));
    final signOutLabel =
        tester.element(find.byType(Scaffold).first).l10n.setSignOut;
    final out = find.text(signOutLabel);
    if (out.evaluate().isEmpty) {
      fail('sign-out tile absent on /settings — onboarding cannot be reached, '
          'and that is a failure, not a skip');
    }
    await tester.scrollUntilVisible(out.first, 250,
        scrollable: find.byType(Scrollable).first);
    await settle(tester, budget: const Duration(seconds: 6));
    await tester.tap(out.first, warnIfMissed: false);
    await settle(tester, budget: const Duration(seconds: 20));

    // The unsynced-data dialog blocks the flow when the outbox is non-empty.
    final discardLabel =
        find.byType(Scaffold).evaluate().isEmpty
            ? null
            : tester.element(find.byType(Scaffold).first).l10n.setSignOutDiscard;
    if (discardLabel != null && find.text(discardLabel).evaluate().isNotEmpty) {
      notes.add('unsynced-data dialog shown; chose discard');
      // DLG-UNSYNCED-WARNING. One of the eleven Atlas dialog designs, and the
      // only place in the app that raises it — it needs a non-empty sync
      // outbox at the moment of sign-out, which no other run arranges. Captured
      // here because here is where it exists.
      await shoot('ar', 'unsynced-warning');
      await tester.tap(find.text(discardLabel).first, warnIfMissed: false);
      await settle(tester, budget: const Duration(seconds: 30));
    }
    await settle(tester, budget: const Duration(seconds: 30));
    notes.add('post-sign-out session status=${AppSession.instance.status}');

    Future<void> walk(String lang) async {
      // Signing out does NOT clear the welcome gate — it is a device flag, not
      // a session one — so a signed-out app still redirects `/welcome` straight
      // to sign-in and the cinematic screens stay unreachable. That is why the
      // earlier destructive walk recorded them as bounced rather than rendered.
      //
      // The two device flags are deleted and the session re-read through the
      // app's OWN `load()`, which is the state a fresh install is in. Nothing
      // is invented: these are the same keys `markWelcomeManifestoSeen` and
      // `finishOnboarding` write, and both are restored at the end.
      // WRITTEN to '0', not deleted. `delete` left both keys readable — the
      // run that first tried it came back with hasSeenWelcomeManifesto=true
      // and landed on /onboarding/auth twice. `load()` only ever tests
      // `== '1'`, so an explicit '0' is both sufficient and verifiable, and a
      // write is the operation the app itself uses on these keys.
      for (final key in const ['welcome_manifesto_seen', 'onboarding_done']) {
        await SecureStorageOptions.storage.write(key: key, value: '0');
      }
      await AppSession.instance.load();
      if (AppSession.instance.hasSeenWelcomeManifesto) {
        failures.add('[$lang] the welcome gate would not clear: the flag reads '
            'back as seen after being written to "0" and re-loaded, so '
            '/welcome cannot be reached on this device');
        return;
      }
      await settle(tester, budget: const Duration(seconds: 10));
      try {
        final current = await settingsRepo.getSettings();
        await settingsRepo.saveSettings(current.copyWith(language: lang));
      } catch (e) {
        failures.add('[$lang] could not set the language after the wipe: $e');
        return;
      }
      await settle(tester, budget: const Duration(seconds: 10));

      // ── /welcome — page 1 ────────────────────────────────────────────────
      router.go('/welcome');
      if (!await waitFor(tester, find.byType(OnboardingStoryScreen),
          timeout: const Duration(seconds: 30))) {
        // "did not render" is not a diagnosis. The redirect guard has exactly
        // three inputs, so report all three plus where the router actually
        // landed — the first attempt at this walk failed here twice with
        // nothing to go on.
        final landed =
            router.routerDelegate.currentConfiguration.uri.toString();
        final roots = tester
            .widgetList<Widget>(find.byWidgetPredicate((w) =>
                w.runtimeType.toString().endsWith('Screen') ||
                w.runtimeType.toString().endsWith('Shell')))
            .map((w) => w.runtimeType.toString())
            .toSet()
            .toList();
        failures.add('[$lang] /welcome did not render OnboardingStoryScreen — '
            'landed at "$landed", '
            'hasSeenWelcomeManifesto=${AppSession.instance.hasSeenWelcomeManifesto}, '
            'status=${AppSession.instance.status}, '
            'onScreen=$roots');
        return;
      }
      // The page reveals its blocks on a timer before the CTA appears; a
      // capture taken too early shows an empty navy field, which is a frame the
      // user barely sees and not the one under acceptance.
      await settle(tester, budget: const Duration(seconds: 14));
      final observed = observedLanguage(tester);
      if (observed != lang) {
        failures.add('[$lang] the tree carried "$observed" on /welcome — every '
            'capture in this pass would be of the wrong locale');
        return;
      }
      await shoot(lang, 'welcome-1');

      // ── /welcome — page 2, through its own CTA ───────────────────────────
      final l = tester.element(find.byType(Scaffold).first).l10n;
      final cont = find.text(l.storyContinueCta);
      if (cont.evaluate().isEmpty) {
        failures.add('[$lang] the story CTA "${l.storyContinueCta}" never '
            'appeared, so page 2 could not be reached');
      } else {
        await tester.tap(cont.first, warnIfMissed: false);
        await settle(tester, budget: const Duration(seconds: 16));
        await shoot(lang, 'welcome-2');
      }

      // ── /onboarding/brand ────────────────────────────────────────────────
      router.go('/onboarding/brand');
      if (!await waitFor(tester, find.byType(OnboardingBrandScreen))) {
        failures.add('[$lang] /onboarding/brand did not render');
      } else {
        await settle(tester, budget: const Duration(seconds: 8));
        await shoot(lang, 'brand');
      }

      // ── /onboarding/auth ─────────────────────────────────────────────────
      // Reached only once the welcome gate has been passed; the brand CTA is
      // what sets it, so it is tapped rather than the flag being written.
      final brandCta = find.text(l.brandContinueCta);
      if (brandCta.evaluate().isNotEmpty) {
        await tester.tap(brandCta.first, warnIfMissed: false);
        await settle(tester, budget: const Duration(seconds: 20));
      } else {
        await AppSession.instance.markWelcomeManifestoSeen();
        router.go('/onboarding/auth');
        await settle(tester, budget: const Duration(seconds: 20));
        notes.add('[$lang] brand CTA absent; reached auth by route');
      }
      if (!await waitFor(tester, find.byType(OnboardingAuthScreen))) {
        failures.add('[$lang] /onboarding/auth did not render');
      } else {
        await settle(tester, budget: const Duration(seconds: 6));
        await shoot(lang, 'auth');
      }

      // ── /onboarding/setup — three steps ──────────────────────────────────
      router.go('/onboarding/setup');
      if (!await waitFor(tester, find.byType(OnboardingSetupScreen))) {
        failures.add('[$lang] /onboarding/setup did not render');
        return;
      }
      await settle(tester, budget: const Duration(seconds: 8));
      await shoot(lang, 'setup-1-country');

      // Step 0 completes by choosing a country, which really does write the
      // country and currency. SA/SAR is what the QA ledger already carries, so
      // the choice changes nothing it has to change back.
      // `textContaining`, not `text`: the chip label is
      // "<flag> <name> · <currency>", so an exact match on the name alone found
      // nothing and the walk reported "the country list did not render" for a
      // list that was rendering perfectly well — badly enough to hide the real
      // defect, which was that every unselected chip was white on white.
      final sa = find.textContaining(
          tester.element(find.byType(Scaffold).first).l10n.countrySA);
      if (sa.evaluate().isEmpty) {
        failures.add('[$lang] the country list did not render');
      } else {
        await tester.tap(sa.first, warnIfMissed: false);
        await settle(tester, budget: const Duration(seconds: 12));
        await shoot(lang, 'setup-2-notifications');

        // Step 1 asks the OS for notification permission. On a Simulator that
        // has already answered the prompt the call returns immediately; if a
        // native sheet does come up it sits ABOVE Flutter and the next capture
        // would be of a dialog, so the step is recorded rather than forced.
        final notifCta = find.text(
            tester.element(find.byType(Scaffold).first).l10n.setupNotificationsCta);
        if (notifCta.evaluate().isEmpty) {
          notes.add('[$lang] notifications CTA absent — step 2 not advanced');
        } else {
          await tester.tap(notifCta.first, warnIfMissed: false);
          await settle(tester, budget: const Duration(seconds: 20));
          final shortcut = find.text(
              tester.element(find.byType(Scaffold).first).l10n.setupShortcutTitle);
          if (shortcut.evaluate().isEmpty) {
            failures.add('[$lang] step 3 (the shortcut guide) never appeared '
                'after the notifications step');
          } else {
            await shoot(lang, 'setup-3-shortcut');
          }
        }
      }
    }

    await walk('ar');
    await walk('en');

    // ── back in, so the device is usable and demo_seed can rebuild ─────────
    await AppSession.instance.markWelcomeManifestoSeen();
    final back = await client.auth
        .signInWithPassword(email: _qaEmail, password: _qaPassword);
    await AppSession.instance
        .setIdentity(method: 'email', email: _qaEmail, userId: back.user!.id);
    await AppSession.instance.reconcileAccountOnboarding(client);
    if (!AppSession.instance.hasCompletedOnboarding) {
      await AppSession.instance.finishOnboarding();
    }
    await settle(tester, budget: const Duration(seconds: 45));
    final restored = await waitFor(tester, find.byType(AppShell),
        timeout: const Duration(seconds: 90));
    final last = await settingsRepo.getSettings();
    await settingsRepo.saveSettings(last.copyWith(language: 'ar'));
    await settle(tester);

    debugPrint('[ONB] captured ${captured.length}: ${captured.join(", ")}');
    for (final n in notes) {
      debugPrint('[ONB-NOTE] $n');
    }
    for (final f in failures) {
      debugPrint('[ONB-FAIL] $f');
    }
    expect(restored, isTrue,
        reason: 'signing back in did not restore the shell — the device is '
            'left unusable and demo_seed cannot rebuild the ledger');
    expect(failures, isEmpty, reason: failures.join('\n\n'));
    expect(captured.length, 10,
        reason: 'expected 5 frames × 2 languages, got ${captured.length}: '
            '${captured.join(", ")}');
  }, timeout: const Timeout(Duration(minutes: 40)));

  // Registered LAST on purpose: it runs after the wipe and rebuilds the ledger
  // the rest of the runtime evidence is measured against.
  demo_seed.main();
}
