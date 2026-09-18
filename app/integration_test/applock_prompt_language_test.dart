import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/features/settings/settings_providers.dart';
import 'package:money_companion/core/security/app_lock_service.dart';
import 'package:money_companion/core/security/secure_storage_options.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/features/app/app_shell.dart';
import 'package:money_companion/l10n/app_localizations.dart';
import 'package:money_companion/main.dart' as app;
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import 'demo_seed_test.dart' as demo_seed;

/// APP LOCK PROMPT LANGUAGE — what string does the gate actually hand to iOS?
///
/// `AppLockService.authenticate` passes `localizedReason` to `local_auth`, and
/// iOS renders that string verbatim in its own sheet. The sheet cannot be
/// photographed from inside a test — it is a native view, and while it is up
/// the engine stops delivering vsync, so `tester.pump()` never returns. It can
/// barely be photographed from the host either: the previous attempt did so
/// against a container that turned out to hold NO persisted settings at all, so
/// the app was in its default language and the Arabic prompt it showed proved
/// nothing.
///
/// This reads the string off the platform channel instead. The pigeon message
/// for `LocalAuthApi.authenticate` carries `localizedReason` as UTF-8, so a mock
/// handler on that channel can record the exact bytes the plugin was about to
/// send and then decline to reply. Declining makes pigeon raise a connection
/// error, which `AppLockService.authenticate` catches and reports as a failed
/// authentication — so the gate STAYS LOCKED, which is both the honest outcome
/// on a Simulator with no enrolled biometric and the safe one here.
///
/// Nothing about the gate is stubbed: the real widget, the real lifecycle
/// transition, the real 30-second background delay, the real keychain flag, and
/// the real persisted language. Only the platform call at the very end is
/// intercepted, and only to read what it was given.
const _qaEmail = String.fromEnvironment('QA_EMAIL');
const _qaPassword = String.fromEnvironment('QA_PASSWORD');
const _qaUserId = String.fromEnvironment('QA_USER_ID');

/// The pigeon channel `local_auth_darwin` sends `authenticate` over.
const _authChannel =
    'dev.flutter.pigeon.local_auth_darwin.LocalAuthApi.authenticate';

const _kAppLockEnabled = 'app_lock_enabled';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Leaves the device launchable if this file dies mid-run.
  setUpAll(() async {
    await SecureStorageOptions.storage
        .write(key: _kAppLockEnabled, value: '0');
  });
  demo_seed.main();

  Future<void> settle(WidgetTester tester,
      {Duration budget = const Duration(seconds: 20)}) async {
    final deadline = DateTime.now().add(budget);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 150));
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

  testWidgets('the unlock prompt speaks the persisted language',
      (tester) async {
    WidgetController.hitTestWarningShouldBeFatal = false;
    final report = <String>[];

    app.main();
    await settle(tester, budget: const Duration(seconds: 45));

    if (_qaEmail.isEmpty) fail('QA_EMAIL/QA_PASSWORD/QA_USER_ID are required');
    final owner = await AppSession.instance.readLocalDataOwnerUid();
    if (owner != null && owner != _qaUserId) {
      fail('ABORT — the local database belongs to another account.');
    }
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
    } catch (_) {
      // A restored session is enough to reach the shell.
    }
    await AppSession.instance.markWelcomeManifestoSeen();
    await settle(tester, budget: const Duration(seconds: 30));
    if (!AppSession.instance.hasCompletedOnboarding) {
      await AppSession.instance.finishOnboarding();
      await settle(tester, budget: const Duration(seconds: 20));
    }
    expect(await waitFor(tester, find.byType(AppShell)), isTrue,
        reason: 'shell never mounted');

    final container =
        ProviderScope.containerOf(tester.element(find.byType(AppShell)));
    final repo = container.read(userSettingsRepositoryProvider);

    Uint8List? sent;
    tester.binding.defaultBinaryMessenger
        .setMockMessageHandler(_authChannel, (ByteData? message) async {
      sent = message!.buffer
          .asUint8List(message.offsetInBytes, message.lengthInBytes);
      // No reply: pigeon raises a connection error, AppLockService catches it
      // and reports a failed authentication. The gate stays locked.
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMessageHandler(_authChannel, null));

    /// Everything the plugin was handed, as text — the pigeon envelope writes
    /// strings as UTF-8, so the prompt is in here verbatim.
    String decode(Uint8List bytes) =>
        const Utf8Decoder(allowMalformed: true).convert(bytes);

    /// Drive the real lifecycle sequence. Flutter's state machine rejects a
    /// jump from `resumed` straight to `paused` — "Invalid state transition" —
    /// so the intermediate states are not decoration.
    Future<void> background() async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    }

    Future<void> foreground() async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }

    /// The provider container of whatever tree is currently mounted.
    ProviderContainer currentContainer() {
      final shell = find.byType(AppShell);
      final anchor = shell.evaluate().isNotEmpty
          ? tester.element(shell.first)
          : tester.element(find.byType(Scaffold).first);
      return ProviderScope.containerOf(anchor);
    }

    Future<void> check(String lang) async {
      // ── the persisted setting, and proof of it ──────────────────────────
      final repo = currentContainer().read(userSettingsRepositoryProvider);
      final before = await repo.getSettings();
      await repo.saveSettings(before.copyWith(language: lang));
      final persisted = await repo.getSettings();
      expect(persisted.language, lang,
          reason: 'the language must be persisted before anything is measured');
      report.add('[$lang] PERSISTED language=${persisted.language} '
          '(read back from the settings repository)');

      // Tell the app, the way the settings screen does. Writing through the
      // repository alone leaves `userSettingsProvider` holding its old value,
      // so the TREE stays in the previous language — and the first version of
      // this file then measured a prompt against an app that had never
      // switched, which says nothing about the prompt.
      currentContainer().invalidate(userSettingsProvider);
      final localeDeadline = DateTime.now().add(const Duration(seconds: 30));
      var resolvedNow = '';
      while (DateTime.now().isBefore(localeDeadline)) {
        final s = find.byType(Scaffold);
        if (s.evaluate().isNotEmpty) {
          resolvedNow =
              Localizations.localeOf(tester.element(s.first)).languageCode;
          if (resolvedNow == lang) break;
        }
        await settle(tester, budget: const Duration(seconds: 2));
      }
      report.add('[$lang] RESOLVED app locale before locking=$resolvedNow');
      expect(resolvedNow, lang,
          reason: 'the app itself must be in "$lang" before the lock is '
              'triggered, or this measures the wrong thing');

      // ── arm, then take the COLD-START path into the lock ────────────────
      //
      // Not the background/resume path. `handleAppLifecycleStateChanged(paused)`
      // stops frame production, so `tester.pump()` after it never returns — the
      // whole run hangs. That, not the native sheet, is what froze the earlier
      // attempt at this surface, and the diagnosis in
      // `visual_closure_capture_test` was wrong about which of the two did it.
      //
      // The cold start is also the path under suspicion: `AppLockGate` locks
      // from a post-frame callback in `initState`, which is the moment the
      // persisted language may not have been read yet. Re-running `app.main()`
      // mounts a fresh gate on a fresh tree, exactly as a launch does.
      sent = null;
      await SecureStorageOptions.storage
          .write(key: _kAppLockEnabled, value: '1');
      // Read the flag back through the SERVICE, not the raw key: if the gate
      // and this test disagree about whether the lock is on, everything below
      // measures nothing.
      final armed = await AppLockService.instance.isEnabled();
      report.add('[$lang] AppLockService.isEnabled()=$armed');
      expect(armed, isTrue, reason: 'the lock flag did not take');

      // BACKGROUND, WAIT, RESUME — the real way a user meets this lock, and the
      // only one reachable from here. Re-running `app.main()` does NOT work:
      // the gate's State is reused, so `initState` never fires again and the
      // app simply stays unlocked on the dashboard (measured: onScreen showed
      // AppShell + DashboardScreen with the flag armed).
      //
      // The 33s wait is NOT pumped. `tester.pump()` after a `paused` lifecycle
      // state never returns, because frame production has stopped — that is
      // what hung the first version of this file for twenty minutes, and what
      // hung the earlier attempt to capture this surface. A plain timer is
      // unaffected.
      await background();
      await Future<void>.delayed(const Duration(seconds: 33));
      await foreground();

      final promptDeadline = DateTime.now().add(const Duration(seconds: 90));
      var sawLockScreen = false;
      while (sent == null && DateTime.now().isBefore(promptDeadline)) {
        await tester.pump(const Duration(milliseconds: 100));
        if (!sawLockScreen &&
            find.text('قِرش مقفل').evaluate().isNotEmpty) {
          sawLockScreen = true;
        }
      }
      final onScreen = tester
          .widgetList<Widget>(find.byWidgetPredicate((w) =>
              w.runtimeType.toString().endsWith('Screen') ||
              w.runtimeType.toString().endsWith('Shell') ||
              w.runtimeType.toString() == 'AppLockGate'))
          .map((w) => w.runtimeType.toString())
          .toSet()
          .toList();
      report.add('[$lang] after relaunch: lockScreenSeen=$sawLockScreen '
          'onScreen=$onScreen sent=${sent != null}');
      expect(sent, isNotNull,
          reason: 'the gate never asked the platform to authenticate, so there '
              'is no prompt to measure. lockScreenSeen=$sawLockScreen '
              'onScreen=$onScreen');

      // What the app had resolved by then, for the record.
      final scaffolds = find.byType(Scaffold);
      final resolved = scaffolds.evaluate().isEmpty
          ? 'no-scaffold'
          : Localizations.localeOf(tester.element(scaffolds.first))
              .languageCode;
      report.add('[$lang] RESOLVED app locale at prompt time=$resolved');

      // ── what did iOS get? ───────────────────────────────────────────────
      final payload = decode(sent!);
      final ar = (await AppL10n.delegate.load(const Locale('ar'))).lockPrompt;
      final en = (await AppL10n.delegate.load(const Locale('en'))).lockPrompt;
      final sawAr = payload.contains(ar);
      final sawEn = payload.contains(en);
      report.add('[$lang] PROMPT handed to iOS carries ar=$sawAr en=$sawEn');
      report.add('[$lang] expected="${lang == 'en' ? en : ar}"');

      expect(lang == 'en' ? sawEn : sawAr, isTrue,
          reason: 'the unlock prompt handed to iOS was not in the persisted '
              'language. Payload carried ar=$sawAr en=$sawEn while the '
              'persisted setting was "$lang".');
      expect(lang == 'en' ? sawAr : sawEn, isFalse,
          reason: 'the unlock prompt carried the OTHER language');

      // ── put the device back ─────────────────────────────────────────────
      await SecureStorageOptions.storage
          .write(key: _kAppLockEnabled, value: '0');
      await background();
      await Future<void>.delayed(const Duration(seconds: 2));
      await foreground();
      await settle(tester, budget: const Duration(seconds: 15));
    }

    try {
      await check('ar');
      await check('en');
    } finally {
      for (final line in report) {
        debugPrint('[LOCKPROMPT] $line');
      }
      await SecureStorageOptions.storage
          .write(key: _kAppLockEnabled, value: '0');
      final last = await repo.getSettings();
      await repo.saveSettings(last.copyWith(language: 'ar'));
      await settle(tester, budget: const Duration(seconds: 5));
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}
