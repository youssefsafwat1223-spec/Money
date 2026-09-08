import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;
import 'package:money_companion/main.dart' as app;
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/features/app/app_shell.dart';
import 'support/sweep_core.dart';

/// CAUSAL PROBE — does navigating a shell tab record a campaign impression?
///
/// The sweep observed `user_settings.notifications_json` changing on four nav
/// tabs, and NO no-tap baseline drift on any route, so the write is
/// interaction-associated rather than background activity. This measures the
/// semantic delta directly instead of inferring it from
/// GrowthCampaignService.recordImpression by reading code.
///
/// Answers, per tab: was a campaign banner visible, was it newly exposed, does
/// returning to the same tab increment again, and do unrelated tabs increment
/// the same campaign.
const _qaEmail = String.fromEnvironment('QA_EMAIL');
const _qaPassword = String.fromEnvironment('QA_PASSWORD');
const _qaUserId = String.fromEnvironment('QA_USER_ID');

const _tabs = <String, String>{
  'الرئيسية': 'home',
  'العمليات': 'transactions',
  'الميزانيات': 'budgets',
  'المزيد': 'settings',
  'التحليلات': 'analytics',
};

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> settle(WidgetTester tester,
      {Duration budget = const Duration(seconds: 20)}) async {
    final deadline = DateTime.now().add(budget);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 200));
      if (!tester.binding.hasScheduledFrame) break;
    }
  }

  Future<bool> waitFor(WidgetTester tester, Finder f,
      {Duration timeout = const Duration(seconds: 20)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 200));
      if (f.evaluate().isNotEmpty) return true;
    }
    return false;
  }

  testWidgets('nav-tab campaign impression causality', (tester) async {
    if (_qaEmail.isEmpty) {
      debugPrint('[IMP] SKIPPED — QA defines not supplied.');
      return;
    }
    final semantics = tester.ensureSemantics();
    app.main();
    await settle(tester, budget: const Duration(seconds: 60));

    final client = supabase.Supabase.instance.client;
    final owner = await AppSession.instance.readLocalDataOwnerUid();
    if (owner != null && owner != _qaUserId) fail('ABORT — foreign local data.');
    final res = await client.auth
        .signInWithPassword(email: _qaEmail, password: _qaPassword);
    await AppSession.instance
        .setIdentity(method: 'email', email: _qaEmail, userId: res.user!.id);
    await AppSession.instance.reconcileAccountOnboarding(client);
    await settle(tester, budget: const Duration(seconds: 60));
    if (!AppSession.instance.hasCompletedOnboarding) {
      await AppSession.instance.finishOnboarding();
      await settle(tester, budget: const Duration(seconds: 45));
    }
    expect(await waitFor(tester, find.byType(AppShell)), isTrue);
    final container =
        ProviderScope.containerOf(tester.element(find.byType(AppShell)));
    final db = container.read(appDatabaseProvider);

    Future<Object?> inboxState() async {
      final rows =
          await db.customSelect('SELECT notifications_json FROM user_settings').get();
      return rows.isEmpty ? null : rows.first.data['notifications_json'];
    }

    /// Is a campaign/announcement surface actually on screen right now?
    bool bannerVisible() =>
        find.byWidgetPredicate((w) =>
            w.runtimeType.toString().contains('Campaign') ||
            w.runtimeType.toString().contains('Announcement')).evaluate().isNotEmpty;

    Future<void> tapTab(String label) async {
      final pill = find.bySemanticsLabel(RegExp('^فتح شريط التنقل'));
      if (pill.evaluate().isNotEmpty) {
        await tester.tap(pill.first, warnIfMissed: false);
        await settle(tester, budget: const Duration(seconds: 8));
      }
      final dest = find.bySemanticsLabel(label);
      if (dest.evaluate().isEmpty) {
        debugPrint('[IMP] tab "$label" absent');
        return;
      }
      await tester.tap(dest.first, warnIfMissed: false);
      await settle(tester, budget: const Duration(seconds: 12));
    }

    Future<void> measure(String what, Future<void> Function() action) async {
      final before = await inboxState();
      final visBefore = bannerVisible();
      await action();
      final after = await inboxState();
      final visAfter = bannerVisible();
      final delta = jsonFieldDiff(before, after);
      debugPrint('[IMP] $what :: bannerVisible $visBefore→$visAfter :: '
          'inboxState delta ${delta.isEmpty ? "NONE" : delta.join(",")}');
      if (delta.isNotEmpty) {
        debugPrint('[IMP] $what :: before=${before.toString().substring(0, before.toString().length.clamp(0, 220))}');
        debugPrint('[IMP] $what :: after =${after.toString().substring(0, after.toString().length.clamp(0, 220))}');
      }
    }

    // Q1: does an equivalent window with NO interaction change anything?
    await measure('CONTROL no-tap window', () async {
      await settle(tester, budget: const Duration(seconds: 12));
    });

    // Q2: per-tab delta.
    for (final entry in _tabs.entries) {
      await measure('tab ${entry.value}', () => tapTab(entry.key));
    }

    // Q3: does returning to the SAME tab increment again?
    await measure('repeat home #1', () => tapTab('الرئيسية'));
    await measure('repeat home #2', () => tapTab('الرئيسية'));
    await measure('repeat home #3', () => tapTab('الرئيسية'));

    debugPrint('[IMP] ===== END =====');
    semantics.dispose();
  }, timeout: const Timeout(Duration(minutes: 15)));
}
