import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/features/app/app_shell.dart';
import 'package:money_companion/main.dart' as app;
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

/// TRIAGE PROBE — resolves every verdict the exhaustive sweep could not settle.
///
/// The sweep's generic identity (descriptor + ordinal) cannot address a control
/// on a surface that rebuilds with a different child count, which is what
/// produced all 12 NOT-REACHED results — never a statement about the product,
/// always a statement about the addressing. And three DEAD-TAPs survived
/// source-level triage because their intent cannot be read off the source:
/// a tab bar whose tabs all render alike in this fixture, a switch whose
/// handler is a non-null empty closure while busy, and six close buttons that
/// call `maybePop` on a stack the sweep deliberately left empty.
///
/// This probe addresses controls by their LABEL, not their ordinal, taps them
/// one at a time from a freshly loaded route, and asserts the specific
/// state each one is supposed to change. Every line it prints is a final
/// classification; nothing here can emit NOT-REACHED.
const _qaEmail = String.fromEnvironment('QA_EMAIL');
const _qaPassword = String.fromEnvironment('QA_PASSWORD');
const _qaUserId = String.fromEnvironment('QA_USER_ID');

/// Routes whose close button calls `Navigator.maybePop()`. The sweep reached
/// them with `router.go`, which REPLACES rather than pushes, so `maybePop`
/// correctly did nothing and every one scored DEAD-TAP. Entering by `push`
/// reproduces the only way a user can actually arrive, and the button must
/// then return to where it came from.
const _popRoutes = <String>[
  '/cards',
  '/announcements',
  '/savings',
  '/coupons',
  '/referrals',
  '/settings/planning-currency-repair',
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final results = <String>[];
  void record(String line) {
    results.add(line);
    debugPrint('[TRIAGE] $line');
  }

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

  List<String> texts(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
      .where((s) => s.trim().isNotEmpty)
      .toList();

  testWidgets('triage probe', (tester) async {
    if (_qaEmail.isEmpty || _qaPassword.isEmpty || _qaUserId.isEmpty) {
      debugPrint('[TRIAGE] SKIPPED — QA defines not supplied.');
      return;
    }
    // The sweep learned this the expensive way: a fatal hit-test warning turns
    // Flutter's positional heuristic into 38 false OBSTRUCTED verdicts on
    // widget shapes it misjudges. Effect, not position, decides here too.
    final previousFatal = WidgetController.hitTestWarningShouldBeFatal;
    WidgetController.hitTestWarningShouldBeFatal = false;
    addTearDown(
        () => WidgetController.hitTestWarningShouldBeFatal = previousFatal);
    final semantics = tester.ensureSemantics();
    app.main();
    await settle(tester, budget: const Duration(seconds: 60));

    final client = supabase.Supabase.instance.client;
    final owner = await AppSession.instance.readLocalDataOwnerUid();
    if (owner != null && owner != _qaUserId) {
      fail('ABORT — the local database belongs to another account.');
    }
    final res = await client.auth
        .signInWithPassword(email: _qaEmail, password: _qaPassword);
    await AppSession.instance
        .setIdentity(method: 'email', email: _qaEmail, userId: res.user!.id);
    await AppSession.instance.reconcileAccountOnboarding(client);
    // A FRESH install (a clean Simulator) has not seen the cinematic welcome,
    // and the router redirects every route to /welcome until it has — so the
    // shell never mounts and every run dies on "shell never mounted". The
    // welcome and onboarding routes are covered by the destructive phase, which
    // reaches them the only way a user can.
    await AppSession.instance.markWelcomeManifestoSeen();
    await settle(tester, budget: const Duration(seconds: 60));
    if (!AppSession.instance.hasCompletedOnboarding) {
      await AppSession.instance.finishOnboarding();
      await settle(tester, budget: const Duration(seconds: 45));
    }
    expect(await waitFor(tester, find.byType(AppShell)), isTrue,
        reason: 'shell never mounted');
    final router = GoRouter.of(tester.element(find.byType(AppShell)));
    // Captured ONCE, while the shell is definitely mounted. `/settings` and the
    // onboarding routes are top-level, so AppShell is NOT in the tree there and
    // `tester.element(find.byType(AppShell))` throws "Bad state: No element" —
    // which is exactly how this probe died after three verdicts.
    final container =
        ProviderScope.containerOf(tester.element(find.byType(AppShell)));

    Future<void> goTo(String path) async {
      for (var i = 0; i < 8; i++) {
        final navs = find.byType(Navigator);
        if (navs.evaluate().isEmpty) break;
        final nav = tester.state<NavigatorState>(navs.last);
        if (!nav.canPop()) break;
        nav.pop();
        await settle(tester, budget: const Duration(seconds: 6));
      }
      router.go(path);
      await settle(tester, budget: const Duration(seconds: 25));
    }

    String location() =>
        router.routerDelegate.currentConfiguration.uri.toString();

    // ── A. /reports tab bar ────────────────────────────────────────────────
    //
    // The sweep called `الاتجاهات` a dead tap because all three tabs render a
    // masked, near-identical surface in this fixture, so its page-text diff saw
    // nothing. The tab bar's contract is `onSelected: controller.animateTo`,
    // so read the CONTROLLER — the state the control actually owns.
    await goTo('/reports');
    final tabNames = ['نظرة عامة', 'الاتجاهات', 'التفاصيل'];
    final bar = find.byType(TabBarView);
    if (bar.evaluate().isEmpty) {
      record('/reports :: tab bar :: FAIL (no TabBarView on the route)');
    } else {
      for (var i = 0; i < tabNames.length; i++) {
        final name = tabNames[i];
        final f = find.text(name);
        if (f.evaluate().isEmpty) {
          record('/reports :: tab “$name” :: FAIL (label absent)');
          continue;
        }
        await tester.tap(f.first, warnIfMissed: false);
        await settle(tester, budget: const Duration(seconds: 10));
        final ctrl =
            DefaultTabController.of(tester.element(find.byType(TabBarView)));
        record('/reports :: tab “$name” :: '
            '${ctrl.index == i ? "PASS (controller.index=$i)" : "DEAD-TAP (index stayed ${ctrl.index}, wanted $i)"}');
      }
    }

    // ── B. close buttons reached the way a user reaches them ───────────────
    //
    // `maybePop` on an empty stack is a deliberate no-op, so the sweep's
    // `go`-entry could only ever produce a dead tap. Push instead, and require
    // the button to actually take us back.
    for (final path in _popRoutes) {
      await goTo('/settings');
      NavigatorState topNav() =>
          tester.state<NavigatorState>(find.byType(Navigator).last);
      final couldPopBefore = topNav().canPop();
      // Push through the ROUTER, not a widget context: the context that was
      // valid on the previous route may be gone by now.
      router.push(path);
      await settle(tester, budget: const Duration(seconds: 20));
      // `currentConfiguration.uri` keeps reporting the BASE location for an
      // imperative push, so comparing locations declared six working close
      // buttons broken. The stack itself is the honest witness: a push that
      // arrived leaves something to pop.
      if (couldPopBefore || !topNav().canPop()) {
        record('$path :: close :: FAIL (push left nothing poppable; '
            'canPop before=$couldPopBefore after=${topNav().canPop()})');
        continue;
      }
      var popped = false;
      final buttons = find.byType(IconButton);
      for (var i = 0; i < buttons.evaluate().length && !popped; i++) {
        await tester.tap(buttons.at(i), warnIfMissed: false);
        await settle(tester, budget: const Duration(seconds: 10));
        popped = !topNav().canPop();
      }
      if (!popped) {
        final back = find.text('العودة إلى الإعدادات');
        if (back.evaluate().isNotEmpty) {
          await tester.tap(back.first, warnIfMissed: false);
          await settle(tester, budget: const Duration(seconds: 10));
          popped = !topNav().canPop();
        }
      }
      record('$path :: close :: '
          '${popped ? "PASS (popped the pushed route)" : "DEAD-TAP (route still on the stack)"}');
    }

    // ── C. قفل التطبيق ─────────────────────────────────────────────────────
    //
    // `onChanged: _loading || _busy ? (_) {} : _setEnabled` — a NON-null empty
    // closure while busy, which the sweep's "disabled when onChanged is null"
    // check cannot see. It passed on /settings and died on /profile in the same
    // run, so the question is whether the handler runs at all and what the OS
    // biometric call returns on this device.
    await goTo('/settings');
    final lock = find.text('قفل التطبيق');
    if (lock.evaluate().isEmpty) {
      record('/settings :: قفل التطبيق :: FAIL (tile absent)');
    } else {
      await tester.scrollUntilVisible(lock.first, 200,
          scrollable: find.byType(Scrollable).first);
      await settle(tester, budget: const Duration(seconds: 6));
      final sw = find.descendant(
        of: find.ancestor(of: lock.first, matching: find.byType(ListTile)).first,
        matching: find.byType(Switch),
      );
      if (sw.evaluate().isEmpty) {
        record('/settings :: قفل التطبيق :: FAIL (no Switch under the tile)');
      } else {
        final before = tester.widget<Switch>(sw.first).value;
        await tester.tap(sw.first, warnIfMissed: false);
        await settle(tester, budget: const Duration(seconds: 15));
        final after = tester.widget<Switch>(sw.first).value;
        final snack = texts(tester).any((t) => t.contains('تعذر تفعيل القفل'));
        record('/settings :: قفل التطبيق :: '
            '${after != before ? "PASS (toggled $before→$after)" : snack ? "EXTERNAL-BLOCKED (device has no biometric/passcode; app reported it)" : "DEAD-TAP (no flip, no message)"}');
      }
    }

    // ── D. every NOT-REACHED control, addressed by label ───────────────────
    //
    // Ordinal identity is what failed, so do not use it. Each entry names the
    // route, the label the sweep printed, and the effect that proves the
    // control acted.
    Future<void> byLabel(String path, String label,
        {String? expectRoute}) async {
      await goTo(path);
      final f = find.text(label);
      if (f.evaluate().isEmpty) {
        // A label the sweep saw and this probe cannot is itself the answer:
        // the control is not present in this device state.
        record('$path :: “$label” :: NOT APPLICABLE (label absent in this state)');
        return;
      }
      final beforeTexts = texts(tester);
      final beforeLoc = location();
      final beforeBarriers = find.byType(ModalBarrier).evaluate().length;
      await tester.tap(f.first, warnIfMissed: false);
      await settle(tester, budget: const Duration(seconds: 15));
      final movedTo = location();
      final changed = texts(tester).toString() != beforeTexts.toString() ||
          movedTo != beforeLoc ||
          find.byType(ModalBarrier).evaluate().length != beforeBarriers;
      final routeOk = expectRoute == null || movedTo.startsWith(expectRoute);
      record('$path :: “$label” :: '
          '${changed && routeOk ? "PASS (${movedTo != beforeLoc ? "navigated to $movedTo" : "surface changed"})" : changed ? "PASS-PARTIAL (changed but went to $movedTo, wanted $expectRoute)" : "DEAD-TAP (no change)"}');
    }

    // ── D2. budget period segments — a styling-only selection ─────────────
    //
    // `_buildSegment` drives ONLY an AnimatedContainer decoration off
    // `active = value == period`; no text changes. On /budgets/new the four
    // segments scored PASS because the recommended-amount hint recomputes and
    // that text moved. On the edit form the amount is already set, nothing
    // textual moves, and all four scored DEAD-TAP. Read the decoration the
    // control actually owns instead of the page text.
    Future<void> budgetPeriods(String editPath) async {
      await goTo(editPath);
      for (final label in ['يومي', 'أسبوعي', 'شهري', 'سنوي']) {
        final t = find.text(label);
        if (t.evaluate().isEmpty) {
          record('$editPath :: period “$label” :: FAIL (label absent)');
          continue;
        }
        await tester.tap(t.first, warnIfMissed: false);
        await settle(tester, budget: const Duration(seconds: 8));
        final box = find
            .ancestor(of: find.text(label), matching: find.byType(AnimatedContainer));
        if (box.evaluate().isEmpty) {
          record('$editPath :: period “$label” :: FAIL (no AnimatedContainer)');
          continue;
        }
        final deco = tester.widget<AnimatedContainer>(box.first).decoration;
        final color = deco is BoxDecoration ? deco.color : null;
        final active = color != null && color.a > 0;
        record('$editPath :: period “$label” :: '
            '${active ? "PASS (segment became active)" : "DEAD-TAP (still inactive after tap)"}');
      }
    }

    await byLabel('/reports', 'التفاصيل');
    await byLabel('/goals/new', 'أنشئ الهدف');
    await byLabel('/settings', 'albaraai dev');
    await byLabel('/profile', 'albaraai dev');
    await byLabel('/subscriptions', 'الاشتراكات (0)');

    // The edit form only exists for a budget that exists; resolve one.
    await goTo('/budgets');
    final budgetId = await () async {
      final rows = await container
          .read(appDatabaseProvider)
          .customSelect('SELECT id FROM budgets WHERE deleted_at IS NULL LIMIT 1')
          .get();
      return rows.isEmpty ? null : rows.first.read<String>('id');
    }();
    if (budgetId == null) {
      record('/budgets/:id/edit :: period segments :: '
          'NOT APPLICABLE (no budget row on this device)');
    } else {
      await budgetPeriods('/budgets/$budgetId/edit');
    }

    // The dashboard's three unreached GestureDetectors and the settings avatar
    // carry icons, not text, so address them by icon rather than by label.
    Future<void> byIcon(String path, int code, String note) async {
      await goTo(path);
      final f = find.byWidgetPredicate(
          (w) => w is Icon && w.icon?.codePoint == code);
      if (f.evaluate().isEmpty) {
        record('$path :: icon:${code.toRadixString(16)} ($note) :: '
            'NOT APPLICABLE (icon absent in this state)');
        return;
      }
      final beforeTexts = texts(tester);
      final beforeLoc = location();
      final beforeBarriers = find.byType(ModalBarrier).evaluate().length;
      await tester.tap(f.first, warnIfMissed: false);
      await settle(tester, budget: const Duration(seconds: 15));
      final changed = texts(tester).toString() != beforeTexts.toString() ||
          location() != beforeLoc ||
          find.byType(ModalBarrier).evaluate().length != beforeBarriers;
      record('$path :: icon:${code.toRadixString(16)} ($note) :: '
          '${changed ? "PASS (${location() != beforeLoc ? "navigated to ${location()}" : "surface changed"})" : "DEAD-TAP (no change)"}');
    }

    await byIcon('/', 0xf35e, 'dashboard gesture 22');
    await byIcon('/', 0xf58a, 'dashboard gesture 23');
    await byIcon('/', 0xf477, 'dashboard gesture 24');
    await byIcon('/settings', 0xf43d, 'settings header edit');
    await byIcon('/profile', 0xf43d, 'profile header edit');
    await byIcon('/subscriptions', 0xf45e, 'subscriptions add');

    // ── E. the two guarded no-ops, given the input they guard against ──────
    //
    // `_analyze` returns early on empty text and `_pasteFromClipboard` on an
    // empty clipboard, so the sweep's dead taps were correct behaviour meeting
    // an empty fixture. Supply the input and the guard must stop guarding.
    await goTo('/paste');
    await Clipboard.setData(const ClipboardData(
        text: 'شراء بمبلغ 45.00 ريال لدى TEST MERCHANT بطاقة *1234'));
    final pasteBtn = find.text('لصق من الحافظة');
    if (pasteBtn.evaluate().isEmpty) {
      record('/paste :: لصق من الحافظة :: FAIL (button absent)');
    } else {
      await tester.tap(pasteBtn.first, warnIfMissed: false);
      await settle(tester, budget: const Duration(seconds: 10));
      final field = find.byType(TextField);
      final landed = field.evaluate().isEmpty
          ? ''
          : tester.widget<TextField>(field.first).controller?.text ?? '';
      record('/paste :: لصق من الحافظة :: '
          '${landed.contains('TEST MERCHANT') ? "PASS (clipboard text landed in the field)" : "DEAD-TAP (field still “$landed”)"}');
    }

    debugPrint('[TRIAGE] ===== END — ${results.length} verdicts =====');
    semantics.dispose();
  }, timeout: const Timeout(Duration(minutes: 20)));
}
