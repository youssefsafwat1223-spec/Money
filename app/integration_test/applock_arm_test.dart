import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/security/secure_storage_options.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/features/app/app_shell.dart';
import 'package:money_companion/main.dart' as app;
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import 'demo_seed_test.dart' as demo_seed;

/// APP LOCK — arm or disarm, so the locked screen can be photographed from the
/// host.
///
/// `SHELL-APPLOCK-DEFAULT` is the one shipping surface that cannot be captured
/// from inside an integration test. The locked state exists only while iOS is
/// presenting its authentication prompt; that prompt is a native view, and
/// while it is up the engine stops delivering vsync, so `tester.pump()` never
/// returns and the whole run freezes. Worse, `integration_test` only hands its
/// screenshots to the driver when the test body COMPLETES — so a freeze there
/// discards every capture the run had already taken. Two runs were lost that
/// way.
///
/// So the lock is armed here and photographed with `simctl io screenshot`,
/// which sees the entire device including the OS sheet. That is also the more
/// honest frame: on a Simulator with no enrolled biometric the OS sheet covers
/// the Flutter lock screen completely, and the sheet — carrying the app's own
/// `lockPrompt` string — is what the user actually looks at.
///
/// The flag takes effect on the NEXT launch, so this test finishes normally.
///
///   flutter test integration_test/applock_arm_test.dart -d <udid> \
///     --dart-define=QIRSH_APPLOCK=on --dart-define=QIRSH_APPLOCK_LANG=en
const _qaEmail = String.fromEnvironment('QA_EMAIL');
const _qaPassword = String.fromEnvironment('QA_PASSWORD');
const _qaUserId = String.fromEnvironment('QA_USER_ID');

/// `on` arms the lock, anything else disarms it.
const _arm = String.fromEnvironment('QIRSH_APPLOCK') == 'on';
const _lang = String.fromEnvironment('QIRSH_APPLOCK_LANG', defaultValue: 'ar');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Clears the flag before anything launches, so an already-armed device can
  // still reach its shell and be re-armed in the other language.
  setUpAll(() async {
    await SecureStorageOptions.storage
        .write(key: 'app_lock_enabled', value: '0');
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

  testWidgets('arm or disarm the app lock', (tester) async {
    WidgetController.hitTestWarningShouldBeFatal = false;
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
    } catch (e) {
      debugPrint('[ARM] sign in failed/timed out: $e');
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
      // The restored session is enough to reach the shell.
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
    final current = await repo.getSettings();
    await repo.saveSettings(current.copyWith(language: _lang));
    await settle(tester, budget: const Duration(seconds: 10));

    await SecureStorageOptions.storage
        .write(key: 'app_lock_enabled', value: _arm ? '1' : '0');
    debugPrint('[ARM] app lock ${_arm ? "ARMED" : "disarmed"}, language=$_lang');
  }, timeout: const Timeout(Duration(minutes: 15)));
}
