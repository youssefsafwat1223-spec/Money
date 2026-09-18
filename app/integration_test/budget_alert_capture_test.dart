import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/security/secure_storage_options.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/features/app/app_shell.dart';
import 'package:money_companion/features/budgets/budget_form_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';
import 'package:money_companion/main.dart' as app;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import 'demo_seed_test.dart' as demo_seed;

/// VISUAL ACCEPTANCE FOR THE BUDGET ALERT CONTROL, on the real app.
///
/// The phase arrives in a file (`<lang>:<theme>`) because a `--dart-define` is
/// fixed at compile time and every phase must run the same binary — the same
/// reason `language_restart_persistence_test` works this way.
///
/// The test drives the REAL screens: the shell's own budgets tab, the real
/// budget form sheet, the real slider. It ends with the form open so the host's
/// screenshot lands on the control itself.
const _qaEmail = String.fromEnvironment('QA_EMAIL');
const _qaPassword = String.fromEnvironment('QA_PASSWORD');
const _qaUserId = String.fromEnvironment('QA_USER_ID');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await SecureStorageOptions.storage
        .write(key: 'app_lock_enabled', value: '0');
  });
  demo_seed.main();

  Future<void> settle(WidgetTester tester,
      {Duration budget = const Duration(seconds: 25)}) async {
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

  testWidgets('budget alert control', (tester) async {
    WidgetController.hitTestWarningShouldBeFatal = false;
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'qa_phase.txt'));
    final raw = file.existsSync() ? file.readAsStringSync().trim() : 'ar:light';
    final parts = raw.split(':');
    final lang = parts.first;
    final theme = parts.length > 1 ? parts[1] : 'light';
    debugPrint('[BA-CAP] lang=$lang theme=$theme');

    // Both are set through the app's own persisted sources, before it starts.
    await SecureStorageOptions.storage
        .write(key: 'app_theme_mode', value: theme);

    app.main();
    await settle(tester, budget: const Duration(seconds: 60));

    if (_qaEmail.isEmpty) fail('QA_EMAIL/QA_PASSWORD/QA_USER_ID are required');
    final owner = await AppSession.instance.readLocalDataOwnerUid();
    if (owner != null && owner != _qaUserId) fail('ABORT — wrong account');
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
    } catch (_) {/* a restored session reaches the shell */}
    await AppSession.instance.markWelcomeManifestoSeen();
    await settle(tester);
    if (!AppSession.instance.hasCompletedOnboarding) {
      await AppSession.instance.finishOnboarding();
      await settle(tester);
    }
    expect(await waitFor(tester, find.byType(AppShell)), isTrue,
        reason: 'shell never mounted');

    // The language, through the app's own write path.
    final container =
        ProviderScope.containerOf(tester.element(find.byType(AppShell)));
    await container.read(saveLanguageUseCaseProvider).call(lang);
    await settle(tester);

    // Open the real budget form the way the app does.
    await BudgetFormScreen.showSheet(
        tester.element(find.byType(AppShell)));
    await settle(tester, budget: const Duration(seconds: 20));

    final l10n = await AppL10n.delegate.load(Locale(lang));
    expect(await waitFor(tester, find.text(l10n.bfBudgetAlert),
            timeout: const Duration(seconds: 30)),
        isTrue,
        reason: 'the budget alert control never rendered');
    expect(find.byType(Slider), findsOneWidget);

    final resolved = Localizations.localeOf(
            tester.element(find.byType(Slider)))
        .languageCode;
    final direction = Directionality.of(tester.element(find.byType(Slider)));
    final brightness = Theme.of(tester.element(find.byType(Slider))).brightness;
    debugPrint('[BA-CAP] resolved=$resolved direction=${direction.name} '
        'brightness=${brightness.name} sliderPresent=true');
    expect(resolved, lang);
    expect(direction, lang == 'en' ? TextDirection.ltr : TextDirection.rtl);
    expect(brightness,
        theme == 'dark' ? Brightness.dark : Brightness.light);
    debugPrint('[BA-CAP] DONE');
    // Left open: the host screenshots the control itself.
  }, timeout: const Timeout(Duration(minutes: 15)));
}
