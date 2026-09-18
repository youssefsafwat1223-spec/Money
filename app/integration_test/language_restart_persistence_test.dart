import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/security/app_lock_service.dart';
import 'package:money_companion/core/security/lock_prompt_language.dart';
import 'package:money_companion/core/security/secure_storage_options.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/utils/app_lucide_icons.dart';
import 'package:money_companion/features/app/app_shell.dart';
import 'package:money_companion/features/settings/settings_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';
import 'package:money_companion/main.dart' as app;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import 'demo_seed_test.dart' as demo_seed;

/// THE SHIPPING LANGUAGE PATH, END TO END, ON ONE INSTALL.
///
/// Three launches per language, driven by `tool/language_restart_proof.sh`:
///
///   settings — open Settings by tapping the shell's own settings icon, tap
///              Language, tap the target language. The real screen, the real
///              tile, the real `SaveLanguageUseCase`. Nothing is written behind
///              the UI's back and no `--dart-define` forces a language.
///   verify   — a COLD START with the lock armed. Reads the prompt string off
///              the platform channel before iOS draws it, and checks the
///              persisted language, the resolved locale and the prompt all
///              agree.
///   ui       — the same install with the lock off, so the shell is reached and
///              the rendered copy can be read. This is the "unlock and look"
///              step: the Simulator's passcode sheet cannot be satisfied from
///              inside a test, so the gate is stood down for this launch rather
///              than faked open.
///
/// ## Why the phase arrives in a file
///
/// A `--dart-define` is fixed at compile time, and all three phases must run
/// the SAME binary — the whole point is that nothing is reinstalled between
/// them. `flutter test` UNINSTALLS the app when it finishes, and iOS destroys
/// the data container on uninstall; an earlier measurement taken across two
/// `flutter test` runs therefore reported that English "did not persist", when
/// what had happened is that the database holding it had been deleted. That
/// false finding is why the script installs once and only launches thereafter,
/// and why it compares the container path before and after.
///
/// ## Reading the output
///
/// Each phase ends with the framework reporting "Some tests failed" over a
/// leftover `SemanticsHandle`: the app turns semantics on for its own
/// accessibility and is still alive when the test body returns, so the handle
/// is the app's and cannot be disposed here. Every assertion runs BEFORE the
/// `[LANG-PROOF] DONE` marker, so DONE is the success signal and its absence is
/// the failure signal.
const _qaEmail = String.fromEnvironment('QA_EMAIL');
const _qaPassword = String.fromEnvironment('QA_PASSWORD');
const _qaUserId = String.fromEnvironment('QA_USER_ID');

/// The pigeon channel `local_auth_darwin` sends `authenticate` over.
const _authChannel =
    'dev.flutter.pigeon.local_auth_darwin.LocalAuthApi.authenticate';
const _kAppLockEnabled = 'app_lock_enabled';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  demo_seed.main();

  Future<String> readPhase() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'qa_phase.txt'));
    if (!file.existsSync()) return 'settings:en';
    return file.readAsStringSync().trim();
  }

  Future<void> settle(WidgetTester tester,
      {Duration budget = const Duration(seconds: 30)}) async {
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

  /// Sign in and reach the shell. Needed only by the phases that drive the UI;
  /// the language itself is device-local and needs no session.
  Future<void> reachShell(WidgetTester tester) async {
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
    if (userId != _qaUserId) fail('ABORT — signed in as the wrong account');
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
    await settle(tester);
    if (!AppSession.instance.hasCompletedOnboarding) {
      await AppSession.instance.finishOnboarding();
      await settle(tester);
    }
    expect(await waitFor(tester, find.byType(AppShell)), isTrue,
        reason: 'shell never mounted');
  }

  /// Open Settings the way a user does: tap the settings icon in the app's own
  /// bottom bar.
  Future<void> openSettings(WidgetTester tester) async {
    await tester.tap(find.byIcon(AppLucideIcons.settings).first,
        warnIfMissed: false);
    await settle(tester);
    expect(await waitFor(tester, find.byType(SettingsScreen)), isTrue,
        reason: 'Settings never opened from the shell bar');
  }

  testWidgets('the language survives a process restart', (tester) async {
    WidgetController.hitTestWarningShouldBeFatal = false;
    final raw = await readPhase();
    final parts = raw.split(':');
    final phase = parts.first;
    final target = parts.length > 1 ? parts[1] : 'en';
    final ar = await AppL10n.delegate.load(const Locale('ar'));
    final en = await AppL10n.delegate.load(const Locale('en'));
    final wanted = target == 'en' ? en : ar;
    final other = target == 'en' ? ar : en;
    debugPrint('[LANG-PROOF] phase=$phase target=$target');

    // The prompt handler goes on BEFORE the app starts: with the lock armed the
    // gate raises the prompt within the first frames, and a real native sheet
    // stops frame production and hangs the run. Returning no reply makes pigeon
    // raise a connection error, which `AppLockService.authenticate` catches and
    // reports as a failed authentication — so the gate stays LOCKED, which is
    // the safe outcome as well as the honest one.
    Uint8List? sent;
    tester.binding.defaultBinaryMessenger
        .setMockMessageHandler(_authChannel, (ByteData? message) async {
      sent ??= message!.buffer
          .asUint8List(message.offsetInBytes, message.lengthInBytes);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMessageHandler(_authChannel, null));

    app.main();
    await settle(tester, budget: const Duration(seconds: 90));

    if (phase == 'settings') {
      await reachShell(tester);
      final container =
          ProviderScope.containerOf(tester.element(find.byType(AppShell)));

      await openSettings(tester);

      // ── Settings → Language → the target language ───────────────────────
      const tile = ValueKey('settings-language');
      expect(await waitFor(tester, find.byKey(tile)), isTrue,
          reason: 'Settings has no Language control — English is unreachable');
      await tester.ensureVisible(find.byKey(tile));
      await settle(tester, budget: const Duration(seconds: 5));
      await tester.tap(find.byKey(tile), warnIfMissed: false);
      await settle(tester, budget: const Duration(seconds: 10));

      final option = find.descendant(
        of: find.byType(RadioListTile<String>),
        matching: find.text(target == 'en' ? 'English' : 'العربية'),
      );
      expect(await waitFor(tester, option, timeout: const Duration(seconds: 20)),
          isTrue,
          reason: 'the language picker never offered "$target"');
      await tester.tap(option.first, warnIfMissed: false);
      await settle(tester, budget: const Duration(seconds: 20));

      // ── it reached the database, and the app followed ───────────────────
      final persisted =
          (await container.read(userSettingsRepositoryProvider).getSettings())
              .language;
      final mirrored = await LockPromptLanguage.read();
      var resolved = '';
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (DateTime.now().isBefore(deadline)) {
        final s = find.byType(Scaffold);
        if (s.evaluate().isNotEmpty) {
          resolved = Localizations.localeOf(tester.element(s.first))
              .languageCode;
          if (resolved == target) break;
        }
        await settle(tester, budget: const Duration(seconds: 2));
      }
      debugPrint('[LANG-PROOF] phase=settings chose=$target '
          'persisted=$persisted resolved=$resolved mirrored=$mirrored');
      expect(persisted, target,
          reason: 'tapping the control did not reach user_settings.language');
      expect(resolved, target,
          reason: 'the app did not re-render in the chosen language');
      expect(mirrored, target,
          reason: 'the unlock prompt mirror did not follow the choice');

      // Arm the lock so the next launch meets it on a cold start.
      await SecureStorageOptions.storage
          .write(key: _kAppLockEnabled, value: '1');
      debugPrint('[LANG-PROOF] phase=settings lock armed='
          '${await AppLockService.instance.isEnabled()}');
      debugPrint('[LANG-PROOF] DONE');
      return;
    }

    // Any mounted element will do; these phases never sign in.
    final anchor = find.byType(Scaffold);
    expect(anchor, findsWidgets, reason: 'the app never rendered');
    final container = ProviderScope.containerOf(tester.element(anchor.first));
    final settingsRepo = container.read(userSettingsRepositoryProvider);

    if (phase == 'verify') {
      // ── a cold start, in a process that was killed and started again ────
      final persisted = (await settingsRepo.getSettings()).language;
      final resolved =
          Localizations.localeOf(tester.element(anchor.first)).languageCode;

      var promptAr = false;
      var promptEn = false;
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      while (sent == null && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      if (sent != null) {
        final payload = const Utf8Decoder(allowMalformed: true).convert(sent!);
        promptAr = payload.contains(ar.lockPrompt);
        promptEn = payload.contains(en.lockPrompt);
      }

      debugPrint('[LANG-PROOF] phase=verify persisted=$persisted '
          'resolved=$resolved mirrored=${await LockPromptLanguage.read()} '
          'promptSeen=${sent != null} promptAr=$promptAr promptEn=$promptEn');

      expect(persisted, target,
          reason: 'the language chosen in Settings did not survive the restart');
      expect(resolved, target,
          reason: 'the app resolved a different locale than the one persisted');
      expect(sent, isNotNull,
          reason: 'the gate never asked the platform to authenticate, so the '
              'lock did not engage on this launch');
      // THE ASSERTION THIS WHOLE HARNESS EXISTS FOR. The gate composes the
      // prompt on the first frame, before the database is open; it must still
      // come out in the language the user chose.
      expect(target == 'en' ? promptEn : promptAr, isTrue,
          reason: 'the prompt handed to iOS was not in the persisted language');
      expect(target == 'en' ? promptAr : promptEn, isFalse,
          reason: 'the prompt handed to iOS carried the OTHER language');

      // Stand the gate down for the `ui` launch — see the header.
      await SecureStorageOptions.storage
          .write(key: _kAppLockEnabled, value: '0');
      debugPrint('[LANG-PROOF] DONE');
      return;
    }

    // ── ui: the same install, gate off, so the rendered copy can be read ──
    await reachShell(tester);
    await openSettings(tester);
    expect(await waitFor(tester, find.byKey(const ValueKey('settings-language'))),
        isTrue);
    await tester.ensureVisible(find.byKey(const ValueKey('settings-language')));
    await settle(tester, budget: const Duration(seconds: 5));

    final persisted = (await settingsRepo.getSettings()).language;
    final element = tester.element(find.byType(SettingsScreen));
    final resolved = Localizations.localeOf(element).languageCode;
    final direction = Directionality.of(element).name;
    // RENDERED COPY, not a locale field: the label the user reads, and the
    // endonym beneath it. The other language's label must be absent — an app
    // showing both is an app that half-switched.
    final wantedVisible = find.text(wanted.setLanguage).evaluate().isNotEmpty;
    final otherVisible = find.text(other.setLanguage).evaluate().isNotEmpty;
    final endonym = find
        .text(target == 'en' ? 'English' : 'العربية')
        .evaluate()
        .isNotEmpty;
    debugPrint('[LANG-PROOF] phase=ui persisted=$persisted resolved=$resolved '
        'direction=$direction wantedCopyVisible=$wantedVisible '
        'otherCopyVisible=$otherVisible endonymVisible=$endonym');
    expect(persisted, target);
    expect(resolved, target);
    expect(direction, target == 'en' ? 'ltr' : 'rtl',
        reason: 'the app did not lay out in the direction its language reads');
    expect(wantedVisible, isTrue,
        reason: 'the Settings copy is not in the persisted language');
    expect(otherVisible, isFalse,
        reason: 'the other language is still on screen');
    expect(endonym, isTrue);

    // Leave the picker OPEN. The app is still alive when this body returns, so
    // the script's screenshot lands on the new surface itself — the Language
    // tile in the settings list with its picker over it — which is what the
    // visual matrix needs to add it to the inspected inventory.
    await tester.tap(find.byKey(const ValueKey('settings-language')),
        warnIfMissed: false);
    await settle(tester, budget: const Duration(seconds: 10));
    expect(
        find.descendant(
          of: find.byType(RadioListTile<String>),
          matching: find.text(target == 'en' ? 'English' : 'العربية'),
        ),
        findsWidgets,
        reason: 'the picker did not open for the capture');
    debugPrint('[LANG-PROOF] DONE');
  }, timeout: const Timeout(Duration(minutes: 20)));
}
