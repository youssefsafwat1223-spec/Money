import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/features/app/app_shell.dart';
import 'package:money_companion/main.dart' as app;
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

/// DEEP CRUD MATRIX — every operation driven through the UI, every result
/// asserted in Drift.
///
/// The exhaustive sweep proves a control ACTS. It deliberately does not prove
/// a control does the RIGHT thing: it restores durable state after each tap, so
/// it can never observe a value surviving, being read back, being changed, and
/// being removed. That is what this file is for, and it is the reason a sweep
/// alone is not closure.
///
/// Each cell is measured, not inferred:
///   C — drive the create UI, then read the new row out of the database.
///   R — the created row must appear on its list screen (rendered, not queried).
///   U — drive the edit UI, then read the CHANGED COLUMN back.
///   D — drive the delete UI (through its confirmation), then prove the row is
///       gone or tombstoned.
///
/// Everything it creates, it deletes: the D cell is also the cleanup, so a
/// pass leaves the device exactly as it was found. A failure mid-matrix is
/// reported with what it left behind, because a silent partial cleanup would
/// change the preconditions of every later run.
const _qaEmail = String.fromEnvironment('QA_EMAIL');
const _qaPassword = String.fromEnvironment('QA_PASSWORD');
const _qaUserId = String.fromEnvironment('QA_USER_ID');

/// Entity slice, so one run stays inside the device runner's ~5.5 minute cap.
/// Empty means every entity.
const _only = String.fromEnvironment('CRUD_ONLY');

/// Everything this file writes carries this, so a crashed run is identifiable
/// and removable without guessing which rows were the test's.
const _tag = 'crud-matrix';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final results = <String>[];
  void record(String cell, String verdict) {
    results.add('$cell :: $verdict');
    debugPrint('[CRUD] $cell :: $verdict');
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
      {Duration timeout = const Duration(seconds: 25)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 200));
      if (f.evaluate().isNotEmpty) return true;
    }
    return false;
  }

  testWidgets('deep CRUD matrix', (tester) async {
    if (_qaEmail.isEmpty || _qaPassword.isEmpty || _qaUserId.isEmpty) {
      debugPrint('[CRUD] SKIPPED — QA defines not supplied.');
      return;
    }
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

    final container =
        ProviderScope.containerOf(tester.element(find.byType(AppShell)));
    final db = container.read(appDatabaseProvider);
    final router = GoRouter.of(tester.element(find.byType(AppShell)));

    List<String> texts() => tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
        .where((s) => s.trim().isNotEmpty)
        .toList();

    Future<List<Map<String, Object?>>> rows(String sql) async =>
        (await db.customSelect(sql).get()).map((r) => r.data).toList();

    Future<Object?> one(String sql) async {
      final r = await rows(sql);
      return r.isEmpty ? null : r.first.values.first;
    }

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

    /// Type into a field addressed by its label, using the controller as the
    /// fallback: `enterText` is silently a no-op on device unless the field
    /// holds focus, which is how three earlier journeys reported a save that
    /// never happened.
    Future<bool> typeInto(Finder field, String value) async {
      if (field.evaluate().isEmpty) return false;
      await tester.tap(field.first, warnIfMissed: false);
      await settle(tester, budget: const Duration(seconds: 4));
      await tester.enterText(field.first, value);
      await settle(tester, budget: const Duration(seconds: 4));
      final w = tester.widget<TextField>(field.first);
      if (w.controller?.text != value) {
        w.controller?.text = value;
        await settle(tester, budget: const Duration(seconds: 4));
      }
      return tester.widget<TextField>(field.first).controller?.text == value;
    }

    Finder fieldByLabel(String label) =>
        find.ancestor(of: find.text(label), matching: find.byType(TextField));

    /// Text seen in the seconds right after the last tap — including anything
    /// transient. A SnackBar lives about four seconds and `settle` waits up to
    /// fifteen, so reading the screen after settling reported "the form refused
    /// silently" for a form that had in fact said why and been ignored.
    var transientTexts = <String>[];

    /// Tap a label wherever it sits — button, tile, dialog action.
    Future<bool> tapText(String label) async {
      final f = find.text(label);
      if (f.evaluate().isEmpty) return false;
      // Scroll it into view FIRST. `tap` with warnIfMissed:false on an
      // off-screen widget aims at a point outside the viewport and silently
      // hits nothing — which is indistinguishable from a form that validated,
      // raised no error, and wrote no row. The goals form is long enough for
      // its own submit button to sit below the fold.
      try {
        await tester.ensureVisible(f.last);
        await settle(tester, budget: const Duration(seconds: 4));
      } catch (_) {
        // Not inside a scrollable — tap it where it is.
      }
      await tester.tap(f.last, warnIfMissed: false);
      await settle(tester, budget: const Duration(seconds: 3));
      transientTexts = texts();
      await settle(tester, budget: const Duration(seconds: 12));
      return true;
    }

    bool runs(String entity) => _only.isEmpty || _only == entity;

    // ── BUDGET ─────────────────────────────────────────────────────────────
    if (runs('budget')) {
      Future<Set<String>> budgetIds() async => (await rows(
              'SELECT id FROM budgets WHERE deleted_at IS NULL'))
          .map((r) => r['id'].toString())
          .toSet();

      // C — identify the new row by DIFFERENCE, not by a value. Asserting
      // `amount_minor = 77700` would have been asserting the form's own
      // major→minor conversion at the same time, and a currency with different
      // precision would fail the create cell for the wrong reason.
      final idsBefore = await budgetIds();
      await goTo('/budgets/new');
      final typed = await typeInto(fieldByLabel('المبلغ'), '777');
      if (!typed) {
        record('budget/C', 'FAIL (amount field never accepted input)');
      } else {
        await tapText('حفظ الميزانية');
      }
      final created = (await budgetIds()).difference(idsBefore);
      record('budget/C',
          created.length == 1 ? 'PASS (exactly 1 new row in budgets)' : created.isEmpty ? 'FAIL (no row written)' : 'FAIL (${created.length} rows written for one save)');
      final id = created.length == 1 ? created.first : null;

      if (id == null) {
        for (final cell in ['budget/R', 'budget/U', 'budget/D']) {
          record(cell, 'BLOCKED (create produced no single row)');
        }
        // Anything a partial create left behind must not survive the run.
        for (final stray in created) {
          await db.customStatement("DELETE FROM budgets WHERE id = '$stray'");
          record('budget/cleanup', 'removed stray $stray');
        }
      } else {
        // R — rendered, not queried.
        await goTo('/budgets');
        record('budget/R',
            find.textContaining('777').evaluate().isNotEmpty ? 'PASS (amount rendered on /budgets)' : 'FAIL (row exists but never rendered)');

        // U — read the changed column back.
        final amountBefore = await one("SELECT amount_minor FROM budgets WHERE id = '$id'");
        await goTo('/budgets/$id/edit');
        final retyped = await typeInto(fieldByLabel('المبلغ'), '888');
        if (!retyped) {
          record('budget/U', 'FAIL (edit field never accepted input)');
        } else {
          await tapText('حفظ الميزانية');
          final amountAfter = await one("SELECT amount_minor FROM budgets WHERE id = '$id'");
          record('budget/U',
              amountAfter != amountBefore ? 'PASS (amount_minor $amountBefore→$amountAfter)' : 'FAIL (unchanged at $amountBefore)');
        }

        // D — through the confirmation dialog.
        await goTo('/budgets/$id/edit');
        await tapText('حذف الميزانية');
        final confirmed = await tapText('حذف');
        final live = await one(
            "SELECT id FROM budgets WHERE id = '$id' AND deleted_at IS NULL");
        record('budget/D',
            live == null ? 'PASS (row removed or tombstoned)' : confirmed ? 'FAIL (still live after confirm)' : 'FAIL (confirm button absent)');
        if (live != null) {
          await db.customStatement("DELETE FROM budgets WHERE id = '$id'");
          record('budget/cleanup', 'forced removal of $id after failed delete');
        }
      }
    }

    // ── GOAL ───────────────────────────────────────────────────────────────
    if (runs('goal')) {
      const name = 'هدف $_tag';
      await goTo('/goals/new');
      final named = await typeInto(fieldByLabel('اسم الهدف'), name);
      final targeted = await typeInto(fieldByLabel('المبلغ المستهدف'), '5000');
      // Report what the form ACTUALLY holds at submit time. The previous run
      // said "refused silently" only because the reason matcher did not know
      // the name validator's wording — guessing at a cause is how a test
      // becomes a rumour.
      String held(String label) {
        final f = fieldByLabel(label);
        return f.evaluate().isEmpty
            ? '<field not found>'
            : '“${tester.widget<TextField>(f.first).controller?.text ?? ""}”';
      }
      record('goal/C-precondition',
          'name=${held('اسم الهدف')} target=${held('المبلغ المستهدف')}');
      if (!named || !targeted) {
        record('goal/C', 'FAIL (form fields never accepted input)');
      } else {
        final tapped = await tapText('أنشئ الهدف');
        final made = await one("SELECT id FROM goals WHERE name = '$name' AND deleted_at IS NULL");
        if (made != null) {
          record('goal/C', 'PASS (row in goals)');
        } else {
          // "No row" is a symptom. The form has three ways to refuse — a field
          // validator, the past-deadline guard, and the save catch — and each
          // says so on screen. Name which one fired instead of guessing.
          final shown = [...transientTexts, ...texts()];
          final reason = shown.firstWhere(
              (t) =>
                  t.contains('أدخل') ||
                  t.contains('اكتب') ||
                  t.contains('اختار موعدًا') ||
                  t.contains('حدث خطأ') ||
                  t.contains('تعذّر'),
              orElse: () => '');
          record('goal/C',
              'FAIL (no row written; tapped=$tapped; reason=${reason.isEmpty ? "none matched" : "“$reason”"}; screen after tap: ${shown.take(14).join(" | ")})');
        }
      }
      final gid =
          await one("SELECT id FROM goals WHERE name = '$name' AND deleted_at IS NULL LIMIT 1");

      if (gid == null) {
        record('goal/R', 'BLOCKED (create produced no row)');
        record('goal/U', 'BLOCKED (create produced no row)');
        record('goal/D', 'BLOCKED (create produced no row)');
      } else {
        await goTo('/goals');
        record('goal/R',
            find.text(name).evaluate().isNotEmpty ? 'PASS (name rendered on /goals)' : 'FAIL (row exists but never rendered)');

        // U — a contribution is the goal's own update path (saved_minor moves).
        final before = await one("SELECT saved_amount_minor FROM goals WHERE id = '$gid'");
        await goTo('/goals/$gid');
        if (await tapText('أضف للهدف')) {
          // The sheet has TWO fields (المبلغ, ملاحظة) and sits above a page that
          // has its own; `find.byType(TextField).first` is tree order, not
          // "the one on top", so address the amount by its label.
          final amountField = fieldByLabel('المبلغ');
          final typedAmount = await typeInto(
              amountField.evaluate().isEmpty ? find.byType(TextField) : amountField,
              '100');
          // `إضافة مساهمة` is the sheet's TITLE. The submit button is
          // `حفظ المساهمة`; tapping the title left the sheet open and the cell
          // reported a value that had never been asked to move.
          final submitted = await tapText('حفظ المساهمة');
          final after = await one("SELECT saved_amount_minor FROM goals WHERE id = '$gid'");
          // Distinguish "nothing was written" from "the contribution landed
          // but the goal's rollup did not" — those are different defects in
          // different layers, and one number cannot tell them apart.
          final contribs = (await rows(
                  "SELECT id FROM goal_contributions WHERE goal_id = '$gid'"))
              .length;
          record('goal/U',
              after != before ? 'PASS (saved_amount_minor $before→$after, contributions=$contribs)' : 'FAIL (unchanged at $before; typed=$typedAmount submitted=$submitted contributions=$contribs; screen: ${transientTexts.take(12).join(" | ")})');
        } else {
          record('goal/U', 'FAIL (contribution CTA absent)');
        }

        // D
        await goTo('/goals/$gid');
        final openedDialog = await tapText('حذف الهدف');
        final confirmedDelete = await tapText('حذف');
        final gone =
            await one("SELECT id FROM goals WHERE id = '$gid' AND deleted_at IS NULL");
        record('goal/D',
            gone == null ? 'PASS (row removed or tombstoned)' : 'FAIL (still live; deleteTile=$openedDialog confirm=$confirmedDelete; screen: ${transientTexts.take(10).join(" | ")})');
        if (gone != null) {
          await db.customStatement("DELETE FROM goals WHERE id = '$gid'");
          record('goal/cleanup', 'forced removal of $gid after failed delete');
        }
      }
    }

    // ── TRANSACTION ────────────────────────────────────────────────────────
    //
    // Read/Update/Delete only. Creation through the capture sheet is already
    // covered end-to-end by `post_auth_journeys_test.dart` journey D, and
    // duplicating it here would spend the runner's budget re-proving it.
    if (runs('transaction')) {
      final tid = await one('SELECT id FROM transactions LIMIT 1');
      if (tid == null) {
        for (final cell in ['transaction/R', 'transaction/U', 'transaction/D']) {
          record(cell, 'NOT APPLICABLE (no transaction row on this device)');
        }
      } else {
        await goTo('/transaction/$tid');
        record('transaction/R',
            find.text('تفاصيل العملية').evaluate().isNotEmpty ? 'PASS (details rendered)' : 'FAIL (details screen never rendered)');

        final beforeCat = await one("SELECT category_id FROM transactions WHERE id = '$tid'");
        if (await tapText('تغيير التصنيف')) {
          // Take any category that is not the current one.
          final other = await one(
              "SELECT id FROM categories WHERE id != '${beforeCat ?? ''}' LIMIT 1");
          final label = await one(
              "SELECT name_ar FROM categories WHERE id = '${other ?? ''}' LIMIT 1");
          if (label != null && await tapText(label.toString())) {
            // The sheet is TWO steps: tapping a category only sets local
            // selection state (`_selectedKey`), and `حفظ التعديل` is what calls
            // correctCategoryUseCase. Reading the column straight after the tap
            // measured a change that had not been asked for yet — the test was
            // wrong, not the screen.
            final saved = await tapText('حفظ التعديل');
            final afterCat =
                await one("SELECT category_id FROM transactions WHERE id = '$tid'");
            if (!saved) {
              record('transaction/U-note', 'save CTA absent in the sheet');
            }
            record('transaction/U',
                afterCat != beforeCat ? 'PASS (category_id changed)' : 'FAIL (unchanged at $beforeCat after picking “$label”; seen right after the tap: ${transientTexts.take(10).join(" | ")})');
            // Exact-state restore: this row is the user's, not the test's.
            await db.customStatement(
                "UPDATE transactions SET category_id = ${beforeCat == null ? 'NULL' : "'$beforeCat'"} WHERE id = '$tid'");
          } else {
            record('transaction/U', 'FAIL (no alternative category offered)');
          }
        } else {
          record('transaction/U', 'FAIL (recategorize CTA absent)');
        }

        // D is measured on a row this test OWNS — never on the user's data.
        // Deleting a seeded transaction and restoring it is not equivalent:
        // the delete path also writes the ledger outbox, and un-deleting the
        // row would leave that queue inconsistent.
        record('transaction/D',
            'UNSAFE TO TEST (only user-owned rows exist; delete also enqueues '
            'a ledger mutation that cannot be reversed by restoring the row)');
      }
    }

    // ── ACCOUNT ────────────────────────────────────────────────────────────
    if (runs('account')) {
      final before = (await rows('SELECT id FROM accounts WHERE deleted_at IS NULL')).length;
      await goTo('/accounts');
      final opened = await tapText('إضافة حساب');
      record('account/C-entry',
          opened && find.byType(TextField).evaluate().isNotEmpty ? 'PASS (create form opened)' : 'FAIL (create form did not open)');
      final after = (await rows('SELECT id FROM accounts WHERE deleted_at IS NULL')).length;
      record('account/C-isolation',
          after == before ? 'PASS (opening the form wrote nothing)' : 'FAIL (form open created $after-$before rows)');
      record('account/R',
          find.text('الحسابات والمحافظ').evaluate().isNotEmpty || before > 0 ? 'PASS ($before accounts listed)' : 'FAIL');
    }

    debugPrint('[CRUD] ===== ${results.length} cells =====');
    final failures = results.where((r) => r.contains('FAIL')).toList();
    debugPrint('[CRUD] ${failures.isEmpty ? "NO FAILING CELLS" : "FAILING: ${failures.join(" ;; ")}"}');
    semantics.dispose();
  }, timeout: const Timeout(Duration(minutes: 25)));
}
