import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;
import 'package:money_companion/main.dart' as app;
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/features/app/app_shell.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/data/sync/exact_transport_capability.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:money_companion/core/utils/app_lucide_icons.dart';

/// FULL POST-AUTH ON-DEVICE CLOSURE — real iPhone, real Supabase, real RLS.
///
/// Credentials arrive by --dart-define only; the email is masked in output and
/// the password only ever reaches GoTrue.
///
/// Navigation goes through Semantics, not text: the bottom bar renders icons
/// only and keeps each destination's name in `Semantics(label:)`
/// (app_shell.dart `_NavTab`). Matching on `find.text` produced a false PASS
/// once by hitting an unrelated dashboard heading, so every tab switch is now
/// confirmed against `shellIndexProvider` rather than against what is on
/// screen.
///
/// Journeys record their verdict instead of aborting, so one launch surfaces
/// every defect rather than only the first.
const _qaEmail = String.fromEnvironment('QA_EMAIL');
const _qaPassword = String.fromEnvironment('QA_PASSWORD');
const _qaUserId = String.fromEnvironment('QA_USER_ID');

String _mask(String e) {
  final at = e.indexOf('@');
  return at <= 1 ? '***' : '${e[0]}***${e.substring(at)}';
}

/// Shell page indices, from AppShell.build's IndexedStack.
const _tabs = <String, int>{
  'الرئيسية': 0,
  'العمليات': 1,
  'الميزانيات': 2,
  'المزيد': 3,
  'التحليلات': 4,
};

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

  /// Pumps until [f] appears. `settle` alone is not enough: it stops as soon
  /// as no frame is scheduled, which is precisely what happens while a sheet's
  /// provider awaits I/O — the probe then runs before the body renders.
  Future<bool> waitFor(WidgetTester tester, Finder f,
      {Duration timeout = const Duration(seconds: 25)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 200));
      if (f.evaluate().isNotEmpty) return true;
    }
    return false;
  }

  /// Types into a field and PROVES the text landed.
  ///
  /// `tester.enterText` alone is silently a no-op here: under
  /// IntegrationTestWidgetsFlutterBinding on a real device the field must hold
  /// focus for the test text input to route to it, and an unfocused field
  /// swallows the keystrokes with no error (observed: all three fields empty
  /// after three "successful" enterText calls, with _save rejecting on amount).
  /// Falls back to driving the widget's own controller, so its listeners and
  /// validation still run exactly as they do in the UI.
  Future<void> typeInto(WidgetTester tester, Finder field, String value) async {
    await tester.tap(field, warnIfMissed: false);
    await settle(tester, budget: const Duration(seconds: 4));
    await tester.enterText(field, value);
    await settle(tester, budget: const Duration(seconds: 4));
    if (tester.widget<TextField>(field).controller?.text == value) return;
    final controller = tester.widget<TextField>(field).controller;
    if (controller == null) fail('field has no controller; cannot set "$value"');
    controller.text = value;
    await settle(tester, budget: const Duration(seconds: 4));
    debugPrint('[QA] typeInto: enterText was a no-op, used the controller');
  }

  List<String> texts(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
      .where((s) => s.trim().isNotEmpty)
      .toList();

  /// A failed journey can leave a modal sheet open, which hides the nav bar
  /// and fails every journey after it for the wrong reason. Pop back to the
  /// shell before each one so verdicts stay independent.
  Future<void> ensureShell(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      // A sheet/dialog adds a ModalBarrier above the shell's own. The nav bar's
      // semantics survive underneath it, so checking for the nav bar proved
      // nothing; and returning early left later journeys stranded behind a
      // sheet an earlier failure had opened.
      if (find.byType(ModalBarrier).evaluate().length <= 1) return;
      // Pop through the barrier's OWN navigator: sheets are pushed on the
      // shell's nested navigator, so the root navigator has nothing to pop
      // and the old code returned without recovering.
      final barrier = find.byType(ModalBarrier).evaluate().last;
      final nav = Navigator.maybeOf(barrier);
      if (nav == null || !nav.canPop()) return;
      nav.pop();
      await settle(tester, budget: const Duration(seconds: 8));
      await waitFor(tester, find.bySemanticsLabel('الرئيسية'),
          timeout: const Duration(seconds: 6));
    }
  }

  Future<void> journey(
      WidgetTester tester, String id, Future<void> Function() body) async {
    try {
      await ensureShell(tester);
      await body();
      final err = tester.takeException();
      if (err != null) throw StateError(err.toString());
      debugPrint('[QA] $id PASS');
    } catch (e) {
      failures.add('$id: $e');
      debugPrint('[QA] $id FAIL: $e');
    }
  }

  testWidgets('post-auth closure', (tester) async {
    if (_qaEmail.isEmpty || _qaPassword.isEmpty || _qaUserId.isEmpty) {
      debugPrint('[QA] SKIPPED — QA_EMAIL/QA_PASSWORD/QA_USER_ID not supplied.');
      return;
    }
    final semantics = tester.ensureSemantics();

    app.main();
    await settle(tester, budget: const Duration(seconds: 60));

    final client = supabase.Supabase.instance.client;

    // OWNER GATE (must precede EVERY auth call). `signOut` wipes local data
    // outright and admitting a different uid trips the owner gate, which wipes
    // to hand the database to the incoming owner. Both are correct product
    // behaviour and neither asks first, so QA refuses to run on a database it
    // does not already own.
    final localOwner = await AppSession.instance.readLocalDataOwnerUid();
    if (localOwner != null && localOwner != _qaUserId) {
      fail('ABORT — local database belongs to another account. Signing in or '
          'out as QA here would wipe it.');
    }
    debugPrint('[QA] owner gate ok (local owner: ${localOwner ?? "unowned"})');

    final res = await client.auth
        .signInWithPassword(email: _qaEmail, password: _qaPassword);
    expect(res.session, isNotNull, reason: 'GoTrue returned no session');
    final uid = res.user!.id;
    expect(uid, _qaUserId, reason: 'signed in as an unexpected user');
    debugPrint('[QA] A signed in ${_mask(_qaEmail)} uid=$uid');

    // A Supabase session alone does not admit the app: AppSession ignores
    // auth-state events while `authMethod` is null. Replicate the auth
    // screen's own post-sign-in sequence — real session, no bypass.
    await AppSession.instance
        .setIdentity(method: 'email', email: _qaEmail, userId: uid);
    await AppSession.instance.reconcileAccountOnboarding(client);
    await settle(tester, budget: const Duration(seconds: 90));
    if (!AppSession.instance.hasCompletedOnboarding) {
      await AppSession.instance.finishOnboarding();
      await settle(tester, budget: const Duration(seconds: 60));
    }
    debugPrint('[QA] A status=${AppSession.instance.status} '
        'onboarded=${AppSession.instance.hasCompletedOnboarding}');

    final container =
        ProviderScope.containerOf(tester.element(find.byType(AppShell)));
    int shellIndex() => container.read(shellIndexProvider);

    /// Taps a destination by its accessibility name, expanding the collapsed
    /// pill first, and proves the switch happened via the shell's own state.
    Future<void> goTab(WidgetTester tester, String label) async {
      final expandPill = find.bySemanticsLabel(RegExp('^فتح شريط التنقل'));
      if (expandPill.evaluate().isNotEmpty) {
        await tester.tap(expandPill.first, warnIfMissed: false);
        await settle(tester, budget: const Duration(seconds: 8));
      }
      final dest = find.bySemanticsLabel(label);
      if (dest.evaluate().isEmpty) throw StateError('destination "$label" absent');
      await tester.tap(dest.first, warnIfMissed: false);
      await settle(tester);
      expect(shellIndex(), _tabs[label],
          reason: 'tapping "$label" did not switch the shell');
    }

    // ---- B. dashboard ----
    await journey(tester, 'B dashboard', () async {
      expect(find.byType(ErrorWidget), findsNothing);
      final t = texts(tester);
      debugPrint('[QA] B text(${t.length}): ${t.take(30).join(" | ")}');
      expect(shellIndex(), 0);
    });

    // ---- B2. cloud consent ----
    // Every user-data egress class is gated on cloudProcessingEnabled
    // (ConsentAuthority.decide), which defaults to DENY. Without granting it
    // through the real privacy screen, "push sync" cannot happen at all and a
    // green tick would be meaningless. This is the QA account's own setting.
    await journey(tester, 'B2 cloud consent', () async {
      final router0 = GoRouter.of(tester.element(find.byType(AppShell)));
      router0.go('/privacy');
      expect(await waitFor(tester, find.text('المعالجة السحابية والمزامنة')),
          isTrue, reason: 'privacy screen did not open');
      final card = find.ancestor(
          of: find.text('المعالجة السحابية والمزامنة'),
          matching: find.byType(SwitchListTile));
      final sw = card.evaluate().isNotEmpty
          ? card
          : find.descendant(
              of: find.ancestor(
                  of: find.text('المعالجة السحابية والمزامنة'),
                  matching: find.byType(Column)),
              matching: find.byType(Switch));
      expect(sw, findsWidgets, reason: 'cloud consent switch not found');
      final before = tester.widgetList<Switch>(find.byType(Switch)).toList();
      debugPrint('[QA] B2 switches=${before.length} '
          'values=${before.map((w) => w.value).toList()}');
      if (before.isNotEmpty && before.first.value == false) {
        await tester.tap(find.byType(Switch).first);
        await settle(tester, budget: const Duration(seconds: 10));
      }
      final after = tester.widgetList<Switch>(find.byType(Switch)).toList();
      debugPrint('[QA] B2 after=${after.map((w) => w.value).toList()}');
      expect(after.first.value, isTrue, reason: 'cloud consent did not turn on');
      router0.go('/');
      await waitFor(tester, find.bySemanticsLabel('الرئيسية'));
      await settle(tester);
    });

    // ---- C. navigation across all five destinations ----
    for (final label in _tabs.keys) {
      await journey(tester, 'C nav→$label', () async {
        await goTab(tester, label);
        expect(find.byType(ErrorWidget), findsNothing);
        debugPrint('[QA] C $label: ${texts(tester).take(12).join(" | ")}');
      });
    }

    // ---- D. manual entry through the real add flow ----
    final stamp = DateTime.now().millisecondsSinceEpoch.toString();
    final merchant = 'QA$stamp';
    await journey(tester, 'D create', () async {
      await goTab(tester, 'الرئيسية');
      final plus = find.byIcon(AppLucideIcons.plus);
      debugPrint('[QA] D1 shell=${shellIndex()} plus=${plus.evaluate().length} '
          'barriers=${find.byType(ModalBarrier).evaluate().length}');
      expect(plus, findsWidgets, reason: 'dashboard add button not found');

      // MaliGlass wraps its child in an InkWell only when interactive, and the
      // press-glow sits above it in a Stack. Tap the InkWell, not the Icon.
      final addTap =
          find.ancestor(of: plus, matching: find.byType(InkWell));
      await tester.tap(
          addTap.evaluate().isNotEmpty ? addTap.first : plus.first);
      expect(await waitFor(tester, find.text('إضافة عملية جديدة')), isTrue,
          reason: 'capture entry sheet did not open');
      debugPrint('[QA] D2 entry sheet open');

      final manualTile = find.ancestor(
          of: find.text('إضافة يدوية'), matching: find.byType(InkWell));
      expect(manualTile, findsWidgets, reason: 'manual-entry tile not found');
      await tester.tap(manualTile.first);
      expect(await waitFor(tester, find.text('إضافة العملية')), isTrue,
          reason: 'manual transaction sheet did not open');
      debugPrint('[QA] D3 manual sheet open; '
          'textFields=${find.byType(TextField).evaluate().length} '
          'texts=${texts(tester).take(20).join(" | ")}');

      final byHint = find.widgetWithText(TextField, '0');
      final anyField = find.byType(TextField);
      expect(anyField, findsWidgets, reason: 'no TextField in the manual sheet');
      final amount = byHint.evaluate().isNotEmpty ? byHint.first : anyField.first;
      await typeInto(tester, amount, '42');
      debugPrint('[QA] D4 amount='
          '"${tester.widget<TextField>(amount).controller?.text}"');

      final merchantField =
          find.widgetWithText(TextField, 'المتجر أو المصدر (اختياري)');
      if (merchantField.evaluate().isNotEmpty) {
        await typeInto(tester, merchantField.first, merchant);
      }
      debugPrint('[QA] D5 merchant=$merchant entered='
          '${merchantField.evaluate().isNotEmpty}');

      // Entering text raises the keyboard and the sheet rescrolls, so the save
      // button that waitFor found before D4 can be out of the tree by now.
      // Re-find it, scroll it back into view, then tap.
      // The keyboard is up and the sheet's scrollable disposed the footer, so
      // the save button is not merely off-screen — it is out of the tree, and
      // ensureVisible cannot scroll to something that does not exist. Drop
      // focus first; the sheet re-expands and rebuilds it.
      FocusManager.instance.primaryFocus?.unfocus();
      await settle(tester, budget: const Duration(seconds: 6));
      final save = find.text('إضافة العملية');
      if (save.evaluate().isEmpty) {
        debugPrint('[QA] D5b save still gone; '
            'textFields=${find.byType(TextField).evaluate().length} '
            'barriers=${find.byType(ModalBarrier).evaluate().length} '
            'scrollables=${find.byType(Scrollable).evaluate().length}');
        final sc = find.byType(Scrollable);
        if (sc.evaluate().isNotEmpty) {
          await tester.drag(sc.last, const Offset(0, -350));
          await settle(tester, budget: const Duration(seconds: 6));
        }
      }
      expect(await waitFor(tester, save), isTrue,
          reason: 'save button vanished after text entry');
      await tester.ensureVisible(save.first);
      await settle(tester, budget: const Duration(seconds: 5));
      // _save returns early (with a toast) until the catalog has resolved and
      // the sheet's build has defaulted the category. Profile renders the sheet
      // faster than that resolves, so Debug passed by accident. Tap, then
      // require the sheet to actually close; retry a bounded number of times.
      // What actually reached the amount field, and is a category selected?
      // _save rejects with a toast on either, and Profile renders the sheet
      // before the catalog resolves, so the auto-default may not have run.
      final amountText = tester
          .widgetList<TextField>(find.byType(TextField))
          .map((f) => f.controller?.text ?? '')
          .toList();
      debugPrint('[QA] D5b field texts=$amountText');

      // Pick a category explicitly rather than relying on the build-time
      // default — this is what a user does, and it does not depend on timing.
      final categoryDropdown = find.ancestor(
          of: find.text('التصنيف'),
          matching: find.byType(DropdownButtonFormField<String>));
      debugPrint('[QA] D5c category dropdowns=${categoryDropdown.evaluate().length}');
      if (categoryDropdown.evaluate().isNotEmpty) {
        await tester.tap(categoryDropdown.first, warnIfMissed: false);
        await settle(tester, budget: const Duration(seconds: 6));
        final items = find.byType(DropdownMenuItem<String>);
        debugPrint('[QA] D5d category items=${items.evaluate().length}');
        if (items.evaluate().isNotEmpty) {
          await tester.tap(items.first, warnIfMissed: false);
          await settle(tester, budget: const Duration(seconds: 6));
        }
      }

      var closed = false;
      for (var attempt = 1; attempt <= 3 && !closed; attempt++) {
        await tester.tap(save.first);
        await settle(tester, budget: const Duration(seconds: 6));
        closed = find.text('إضافة العملية').evaluate().isEmpty;
        if (!closed) {
          final rejectedAmount = find.text('اكتب مبلغًا صحيحًا.').evaluate().isNotEmpty;
          final rejectedCategory = find.text('اختر تصنيف العملية.').evaluate().isNotEmpty;
          debugPrint('[QA] D6 attempt $attempt rejected: '
              'amount=$rejectedAmount category=$rejectedCategory');
          await tester.pump(const Duration(seconds: 3));
        }
      }
      expect(closed, isTrue, reason: 'save never closed the sheet');
      debugPrint('[QA] D6 saved; barriers='
          '${find.byType(ModalBarrier).evaluate().length}');
    });

    // ---- E. manual paste surface ----
    await journey(tester, 'E paste', () async {
      await goTab(tester, 'الرئيسية');
      final plus = find.byIcon(AppLucideIcons.plus);
      expect(plus, findsWidgets, reason: 'dashboard add button not found');
      await tester.tap(plus.first, warnIfMissed: false);
      await settle(tester);
      final pasteTile = find.ancestor(
          of: find.text('ألصق رسالة بنك'), matching: find.byType(InkWell));
      expect(pasteTile, findsWidgets, reason: 'paste tile not found');
      await tester.tap(pasteTile.first);
      await settle(tester);
      debugPrint('[QA] E paste screen: ${texts(tester).take(15).join(" | ")}');
      expect(find.byType(ErrorWidget), findsNothing);
      final back = find.byType(BackButton);
      if (back.evaluate().isNotEmpty) {
        await tester.tap(back.first, warnIfMissed: false);
        await settle(tester);
      } else {
        Navigator.of(tester.element(find.byType(AppShell))).maybePop();
        await settle(tester);
      }
    });

    // ---- F. sync: the v1 fail-closed contract, not a push ----
    // Every exact-money push is PARKED while the PostgREST decimal transport is
    // unverified (Audit H-4 / MALI-026): exactPushTransportCapabilityProvider
    // is a hard-coded `unknown`, and shouldParkExactMoneyWrite() holds the row.
    // So the honest assertion is not "it reached Supabase" — it cannot — but:
    //   1. the row is held DURABLY in ledger_sync_outbox (pending/parked),
    //   2. nothing reached the server (remote count is exactly 0),
    //   3. the capability is still `unknown` — the moment someone verifies the
    //      transport this expectation flips and the test says so.
    await journey(tester, 'F sync fail-closed contract', () async {
      final cap = container.read(exactPushTransportCapabilityProvider);
      debugPrint('[QA] F push transport capability=$cap');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle(tester, budget: const Duration(seconds: 8));

      final db = container.read(appDatabaseProvider);
      final rows = await db.customSelect(
        'SELECT o.status AS status, o.failure_class AS failure_class '
        'FROM ledger_sync_outbox o JOIN transactions t ON t.id = o.transaction_id '
        'WHERE t.raw_merchant = ?1 ORDER BY o.created_at DESC LIMIT 1',
        variables: [Variable.withString(merchant)],
      ).get();
      final txCount = (await db.customSelect(
        'SELECT COUNT(*) AS n FROM transactions WHERE raw_merchant = ?1',
        variables: [Variable.withString(merchant)],
      ).getSingle()).read<int>('n');
      debugPrint('[QA] F local tx rows=$txCount outbox rows=${rows.length} '
          '${rows.isEmpty ? "" : "status=${rows.first.read<String>("status")} "
              "failure_class=${rows.first.readNullable<String>("failure_class")}"}');
      expect(txCount, 1, reason: 'created transaction missing from Drift');
      expect(rows, isNotEmpty,
          reason: 'transaction never entered ledger_sync_outbox — a write '
              'that is neither held nor sent is LOST, not fail-closed');
      expect(rows.first.read<String>('status'), anyOf('pending', 'parked'),
          reason: 'outbox row is not held for later push');

      final remote = await client
          .from('user_transactions')
          .select('id')
          .eq('merchant', merchant);
      debugPrint('[QA] F remote rows for $merchant: ${remote.length}');
      if (cap == ExactTransportCapability.verifiedExact) {
        fail('exact push transport is now VERIFIED — replace this contract '
            'with a real push assertion (remote row owned by $uid)');
      }
      expect(remote.length, 0,
          reason: 'money left the device over an unverified transport');
    });

    // ---- G. transactions list + details ----
    await journey(tester, 'G transactions', () async {
      await goTab(tester, 'العمليات');
      final all = texts(tester).join(' | ');
      debugPrint('[QA] G list: ${all.substring(0, all.length.clamp(0, 400))}');
    });

    // ---- H. settings / privacy / consent ----
    await journey(tester, 'H settings', () async {
      await goTab(tester, 'المزيد');
      debugPrint('[QA] H settings: ${texts(tester).take(40).join(" | ")}');
    });

    // ---- I. reports ----
    await journey(tester, 'I reports', () async {
      await goTab(tester, 'التحليلات');
      debugPrint('[QA] I reports: ${texts(tester).take(25).join(" | ")}');
    });

    // ---- K. the routed surfaces: accounts, cards, budgets, goals, privacy ----
    // These are full routes rather than shell tabs (app_router.dart), so they
    // are driven through the app's own router, not by faking state.
    const routes = <String, String>{
      'accounts': '/accounts',
      'cards': '/cards',
      'budgets': '/budgets',
      'goals': '/goals',
      'privacy': '/privacy',
    };
    final router = GoRouter.of(tester.element(find.byType(AppShell)));
    for (final entry in routes.entries) {
      await journey(tester, 'K ${entry.key}', () async {
        router.go(entry.value);
        await settle(tester);
        await tester.pump(const Duration(seconds: 2));
        expect(find.byType(ErrorWidget), findsNothing);
        debugPrint('[QA] K ${entry.key}: ${texts(tester).take(18).join(" | ")}');
        router.go('/');
        await waitFor(tester, find.bySemanticsLabel('الرئيسية'));
        await settle(tester);
      });
    }

    // ---- L. the created transaction survives a Drift round-trip ----
    // The list is rendered from the local database through the repository, so
    // seeing the merchant here proves the write landed in Drift and reads back.
    await journey(tester, 'L drift read-back', () async {
      await goTab(tester, 'العمليات');
      final onScreen = texts(tester).join(' | ');
      expect(onScreen.contains(merchant), isTrue,
          reason: 'created transaction $merchant absent from the list');
      debugPrint('[QA] L found $merchant in the transactions list');
    });

    // ---- M. transaction details ----
    await journey(tester, 'M details', () async {
      await goTab(tester, 'العمليات');
      final row = find.text(merchant);
      expect(row, findsWidgets, reason: 'transaction row not found');
      await tester.tap(row.first, warnIfMissed: false);
      await settle(tester);
      debugPrint('[QA] M details: ${texts(tester).take(20).join(" | ")}');
      expect(find.byType(ErrorWidget), findsNothing);
    });

    // ---- J. lifecycle: background then resume ----
    await journey(tester, 'J lifecycle', () async {
      await goTab(tester, 'الرئيسية');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await settle(tester, budget: const Duration(seconds: 10));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle(tester, budget: const Duration(seconds: 30));
      expect(find.byType(ErrorWidget), findsNothing);
      expect(AppSession.instance.status, SessionStatus.authenticated,
          reason: 'resume dropped the session');
      debugPrint('[QA] J after resume: ${texts(tester).take(12).join(" | ")}');
    });

    semantics.dispose();
    debugPrint('[QA] ===== ${failures.isEmpty ? "ALL PASS" : "FAILURES"} =====');
    for (final f in failures) {
      debugPrint('[QA] >>> $f');
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
  });
}
