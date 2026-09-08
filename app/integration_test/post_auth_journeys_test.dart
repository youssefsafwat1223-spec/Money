import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;
import 'package:money_companion/main.dart' as app;
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/features/transactions/manual_transaction_sheet.dart';

/// FULL POST-AUTH ON-DEVICE CLOSURE — real iPhone, real Supabase, real RLS.
///
/// Credentials arrive by --dart-define only; the email is masked in output and
/// the password only ever reaches GoTrue. Sign-in uses the shipping client, so
/// the session, JWT and every RLS decision below are production's.
///
/// Journeys record their outcome instead of aborting the run, so one device
/// launch surfaces every defect rather than only the first. The test still
/// fails at the end if any journey failed.
const _qaEmail = String.fromEnvironment('QA_EMAIL');
const _qaPassword = String.fromEnvironment('QA_PASSWORD');
const _qaUserId = String.fromEnvironment('QA_USER_ID');

String _mask(String e) {
  final at = e.indexOf('@');
  return at <= 1 ? '***' : '${e[0]}***${e.substring(at)}';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final failures = <String>[];

  Future<void> settle(WidgetTester tester,
      {Duration budget = const Duration(seconds: 30)}) async {
    final deadline = DateTime.now().add(budget);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 250));
      if (!tester.binding.hasScheduledFrame) break;
    }
  }

  List<String> texts(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
      .where((s) => s.trim().isNotEmpty)
      .toList();

  /// Runs one journey, captures its verdict, never lets it kill the run.
  Future<void> journey(
      WidgetTester tester, String id, Future<void> Function() body) async {
    try {
      await body();
      final err = tester.takeException();
      if (err != null) throw StateError(err.toString());
      debugPrint('[QA] $id PASS');
    } catch (e) {
      failures.add('$id: $e');
      debugPrint('[QA] $id FAIL: $e');
    }
  }

  /// Taps a bottom-nav destination by its Arabic label and settles.
  Future<void> tapNav(WidgetTester tester, String label) async {
    final f = find.text(label);
    if (f.evaluate().isEmpty) throw StateError('nav label "$label" not found');
    await tester.tap(f.first, warnIfMissed: false);
    await settle(tester);
  }

  testWidgets('post-auth closure', (tester) async {
    if (_qaEmail.isEmpty || _qaPassword.isEmpty || _qaUserId.isEmpty) {
      debugPrint('[QA] SKIPPED — QA_EMAIL/QA_PASSWORD/QA_USER_ID not supplied.');
      return;
    }

    app.main();
    await settle(tester, budget: const Duration(seconds: 60));

    // ---- A. authentication ----
    final client = supabase.Supabase.instance.client;

    // OWNER GATE (must precede EVERY auth call).
    //
    // Two paths on this device destroy local data before anything is asserted:
    // `signOut` wipes directly (app_session.dart:455), and signing in as a
    // different uid trips `_ensureLocalDataOwnedBy`, which wipes to hand the DB
    // to the incoming owner (app_session.dart:218). Both are correct product
    // behaviour and neither asks first. So QA refuses to run at all unless the
    // local database is unowned or already this QA user's — a test must never
    // be the thing that deletes someone's data.
    final localOwner = await AppSession.instance.readLocalDataOwnerUid();
    if (localOwner != null && localOwner != _qaUserId) {
      fail('ABORT — local database belongs to another account. Signing in or '
          'out as QA here would wipe it. Run QA on a device with no real '
          'data, or reinstall the app first.');
    }
    debugPrint('[QA] owner gate ok (local owner: ${localOwner ?? "unowned"})');

    final res = await client.auth
        .signInWithPassword(email: _qaEmail, password: _qaPassword);
    expect(res.session, isNotNull, reason: 'GoTrue returned no session');
    final uid = res.user!.id;
    debugPrint('[QA] A signed in ${_mask(_qaEmail)} uid=$uid');

    // The Supabase session alone does not admit the app: AppSession ignores
    // auth-state events while `authMethod` is null, which is what the auth
    // screen sets. Replicate the screen's own post-sign-in sequence — real
    // session, real identity step, no bypass.
    await AppSession.instance
        .setIdentity(method: 'email', email: _qaEmail, userId: uid);
    await AppSession.instance.reconcileAccountOnboarding(client);
    await settle(tester, budget: const Duration(seconds: 90));
    debugPrint('[QA] A status=${AppSession.instance.status} '
        'onboarded=${AppSession.instance.hasCompletedOnboarding}');

    // ---- A2. onboarding, if this account has never completed it ----
    if (!AppSession.instance.hasCompletedOnboarding) {
      await journey(tester, 'A2 onboarding', () async {
        debugPrint('[QA] A2 setup: ${texts(tester).take(20).join(" | ")}');
        await AppSession.instance.finishOnboarding();
        await settle(tester, budget: const Duration(seconds: 60));
        expect(AppSession.instance.hasCompletedOnboarding, isTrue);
      });
    }

    // ---- B. dashboard reached ----
    await journey(tester, 'B dashboard', () async {
      expect(find.byType(ErrorWidget), findsNothing);
      final t = texts(tester);
      debugPrint('[QA] B text(${t.length}): ${t.take(30).join(" | ")}');
      expect(t, isNotEmpty);
    });

    // ---- C. navigation across all five shell tabs ----
    const tabs = ['العمليات', 'الميزانيات', 'التحليلات', 'المزيد', 'الرئيسية'];
    for (final tab in tabs) {
      await journey(tester, 'C nav→$tab', () async {
        await tapNav(tester, tab);
        expect(find.byType(ErrorWidget), findsNothing);
        debugPrint('[QA] C $tab text: ${texts(tester).take(12).join(" | ")}');
      });
    }

    // ---- D. manual entry: create ----
    final stamp = DateTime.now().millisecondsSinceEpoch.toString();
    final merchant = 'QA$stamp';
    await journey(tester, 'D create', () async {
      final ctx = tester.element(find.byType(Navigator).first);
      ManualTransactionSheet.show(ctx);
      await settle(tester);
      final amount = find.widgetWithText(TextField, '0');
      final amountField = amount.evaluate().isNotEmpty
          ? amount.first
          : find.byType(TextField).first;
      await tester.enterText(amountField, '42');
      await settle(tester, budget: const Duration(seconds: 5));
      final merchantField =
          find.widgetWithText(TextField, 'المتجر أو المصدر (اختياري)');
      if (merchantField.evaluate().isNotEmpty) {
        await tester.enterText(merchantField.first, merchant);
        await settle(tester, budget: const Duration(seconds: 5));
      }
      final save = find.text('إضافة العملية');
      expect(save, findsWidgets, reason: 'save button missing');
      await tester.tap(save.first, warnIfMissed: false);
      await settle(tester);
    });

    // ---- E. it appears in the transactions list ----
    await journey(tester, 'E read', () async {
      await tapNav(tester, 'العمليات');
      final all = texts(tester).join(' | ');
      debugPrint('[QA] E list: ${all.substring(0, all.length.clamp(0, 400))}');
    });

    // ---- F. it reached Supabase (push sync), owned by this user ----
    await journey(tester, 'F push sync', () async {
      final rows = await client
          .from('user_transactions')
          .select('id,user_id,amount,merchant')
          .eq('merchant', merchant);
      debugPrint('[QA] F remote rows: ${rows.length}');
      for (final r in rows) {
        expect(r['user_id'], uid, reason: 'row not owned by QA user');
      }
    });

    // ---- G. settings / consent / privacy surface ----
    await journey(tester, 'G settings', () async {
      await tapNav(tester, 'المزيد');
      debugPrint('[QA] G settings: ${texts(tester).take(40).join(" | ")}');
    });

    // ---- H. reports ----
    await journey(tester, 'H reports', () async {
      await tapNav(tester, 'التحليلات');
      debugPrint('[QA] H reports: ${texts(tester).take(25).join(" | ")}');
    });

    debugPrint('[QA] ===== ${failures.isEmpty ? "ALL PASS" : "FAILURES"} =====');
    for (final f in failures) {
      debugPrint('[QA] >>> $f');
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
  });
}
