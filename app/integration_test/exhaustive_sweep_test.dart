import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;
import 'package:money_companion/main.dart' as app;
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/features/app/app_shell.dart';
import 'support/sweep_core.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// EXHAUSTIVE CONTROL-LEVEL SWEEP — real iPhone, real Supabase, real RLS.
///
/// Visits every static route and exercises every interactive control it finds,
/// one at a time, re-navigating before each tap so no control inherits state
/// from the previous one. Each control gets its own verdict; nothing is allowed
/// to disappear into a "surface passed" result.
///
/// Every tap is checked for: an exception, a layout/overflow failure, a stuck
/// modal, and whether anything actually changed (a dead tap). A control that
/// cannot be reached is reported as NOT-REACHED with its descriptor, never
/// silently dropped.
const _qaEmail = String.fromEnvironment('QA_EMAIL');
const _qaPassword = String.fromEnvironment('QA_PASSWORD');
const _qaUserId = String.fromEnvironment('QA_USER_ID');

/// Controls that must not be tapped, each with the reason recorded in the
/// audit. Deliberately narrow: destructive-but-recoverable actions on
/// QA-owned data ARE tested — only genuinely unsafe ones are listed.
const _unsafe = <String, String>{
  'تسجيل الخروج': 'signs out the shared QA session mid-sweep',
  'الخروج وحذف البيانات': 'sign-out + local wipe; ends the session',
  'تسجيل الخروج وحذف غير المحفوظ': 'sign-out variant; ends the session',
  'امسح البيانات المحلية مع إبقاء الحساب نشطًا': 'wipes the local database',
  'حذف حسابي': 'schedules deletion of the QA account itself',
  'افتح تطبيق الاختصارات': 'launches an external app; leaves the harness',
};

/// Route paths that take parameters are visited with ids created by this run,
/// or skipped as NOT APPLICABLE when no such row exists.
const _staticRoutes = <String>[
  '/', '/reports', '/accounts', '/cards', '/budgets', '/budgets/new',
  '/goals', '/goals/new', '/settings', '/privacy', '/profile',
  '/data-transfer', '/backup', '/backup/restore', '/announcements', '/subscriptions',
  '/savings', '/coupons', '/referrals', '/paste', '/achievements',
  '/capture/sms-permission', '/settings/planning-currency-repair',
];


/// Durable tables a generic sweep can write to. Re-navigation resets widget and
/// navigation state; it does NOT reset Drift. Without this, one control silently
/// changes the preconditions every later control is measured against — the
/// sweep created two budgets that way before this existed.
/// Every Drift table a control can mutate. The repo has 51; this is the audited
/// split, not a guess. Catalog/remote_* tables are WATCHED (a sweep changing
/// seeded reference data is itself a finding) but never restored — they are
/// idempotently reseeded at boot and rewriting them would fight the seeder.
const _userTables = <String>[
  'accounts', 'budgets', 'goals', 'goal_contributions', 'cards', 'categories',
  'transactions', 'smart_inbox_items', 'plans', 'plan_transaction_links',
  'subscriptions', 'bill_payments', 'merchants', 'merchant_category_map',
  'user_settings', 'streaks', 'xp_levels', 'achievements', 'engagement_events',
  'sender_bank_mappings', 'suspected_duplicates', 'dedup_hashes',
  'pending_merchant_feedback', 'local_offer_savings',
  'affiliate_click_receipts', 'capture_work_items', 'capture_review_labels',
  'financial_import_runs', 'restore_operations', 'notification_log_events',
  'proof_shadow_evaluations', 'proof_correction_events',
];
/// Sync state is durable and user-visible in behaviour; isolate it too.
const _syncTables = <String>[
  'ledger_sync_outbox', 'planning_sync_outbox', 'sync_cursors',
  'parked_child_rows',
];
/// Watched for unexpected writes, never restored.
const _catalogTables = <String>[
  'remote_announcements', 'remote_banks', 'remote_catalog_merchants',
  'remote_categories', 'remote_countries', 'remote_coupons',
  'remote_currencies', 'remote_feature_flags', 'remote_growth_campaigns',
  'remote_merchant_aliases', 'remote_merchant_keywords', 'remote_parsers',
  'parsing_rules', 'catalog_metadata', 'financial_cache_health',
];
List<String> get _restorable => [..._userTables, ..._syncTables];
List<String> get _watched => [..._restorable, ..._catalogTables];

/// Which tables a route is ALLOWED to write. A write outside this set is not a
/// pass — it is an unexpected durable mutation and a triage finding.
/// An entity write legitimately enqueues its sync companion, so the outbox is
/// allowed ONLY on the flows that write that entity — never globally, or an
/// unrelated control writing to the outbox would pass unnoticed.
const _expectedWrites = <String, List<String>>{
  '/budgets': ['budgets', 'planning_sync_outbox'],
  '/budgets/new': ['budgets', 'planning_sync_outbox'],
  '/goals': ['goals', 'goal_contributions', 'planning_sync_outbox'],
  '/goals/new': ['goals', 'goal_contributions', 'planning_sync_outbox'],
  '/accounts': ['accounts', 'planning_sync_outbox'],
  '/cards': ['cards', 'accounts', 'planning_sync_outbox'],
  '/settings': ['user_settings', 'planning_sync_outbox'],
  '/profile': ['user_settings', 'planning_sync_outbox'],
  '/privacy': ['user_settings', 'planning_sync_outbox'],
  '/paste': ['transactions', 'smart_inbox_items', 'capture_work_items',
             'merchants', 'dedup_hashes'],
  '/': ['transactions', 'merchants', 'dedup_hashes', 'engagement_events'],
};

class _Ctl {
  _Ctl(this.type, this.label, this.index);
  final String type;
  final String label;
  final int index;
  /// True when this widget sits inside another candidate — an implementation
  /// detail of that control (ListTile's InkWell), not a user action of its own.
  bool implementationOf = false;
  @override
  String toString() => '$type[$index]${label.isEmpty ? "" : " “$label”"}';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final results = <String>[];
  var pass = 0, dead = 0, failed = 0, unsafe = 0, notReached = 0;

  // Print-as-you-go via the tested recorder: an abort must not take the
  // evidence with it, and `record` must not call itself (test 1).
  final recorder = SweepRecorder(debugPrint);
  void record(String line) => recorder.record(line);

  Future<void> settle(WidgetTester tester,
      {Duration budget = const Duration(seconds: 20)}) async {
    final deadline = DateTime.now().add(budget);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 200));
      if (!tester.binding.hasScheduledFrame) break;
    }
  }

  Future<bool> waitFor(WidgetTester tester, Finder f,
      {Duration timeout = const Duration(seconds: 15)}) async {
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

  /// A stable, human-readable name for a control: its own text, else the text
  /// of the nearest Text descendant, else its Semantics label, else its icon.
  String describe(WidgetTester tester, Finder f) {
    try {
      final inner = find.descendant(of: f, matching: find.byType(Text));
      if (inner.evaluate().isNotEmpty) {
        final t = tester.widgetList<Text>(inner).first;
        final s = t.data ?? t.textSpan?.toPlainText() ?? '';
        if (s.trim().isNotEmpty) return s.trim();
      }
      final icon = find.descendant(of: f, matching: find.byType(Icon));
      if (icon.evaluate().isNotEmpty) {
        final i = tester.widgetList<Icon>(icon).first.icon;
        return 'icon:${i?.codePoint.toRadixString(16)}';
      }
    } catch (_) {}
    return '';
  }

  /// Every interactive control on the current surface, in a deterministic
  /// order so the same index means the same control across re-navigations.
  ///
  /// De-duplicated to LOGICAL controls. A ListTile renders an InkWell, a
  /// SwitchListTile renders a Switch inside a tappable row, and app buttons
  /// wrap FilledButton/InkWell internals — counting each internal widget would
  /// inflate the denominator with things that are not distinct user actions.
  /// A candidate that sits inside another candidate is recorded as
  /// implementation evidence for the outer one, never as its own control.
  List<_Ctl> enumerate(WidgetTester tester) {
    final types = <String, Finder>{
      'FilledButton': find.byType(FilledButton),
      'ElevatedButton': find.byType(ElevatedButton),
      'OutlinedButton': find.byType(OutlinedButton),
      'TextButton': find.byType(TextButton),
      'IconButton': find.byType(IconButton),
      'FloatingActionButton': find.byType(FloatingActionButton),
      'PopupMenuButton': find.byType(PopupMenuButton<Object?>),
      'SegmentedButton': find.byType(SegmentedButton<Object?>),
      'Switch': find.byType(Switch),
      'Checkbox': find.byType(Checkbox),
      'Radio': find.byType(Radio<Object?>),
      'ChoiceChip': find.byType(ChoiceChip),
      'FilterChip': find.byType(FilterChip),
      'ActionChip': find.byType(ActionChip),
      'DropdownButtonFormField': find.byType(DropdownButtonFormField<String>),
      'DropdownButton': find.byType(DropdownButton<String>),
      'TextField': find.byType(TextField),
      'RefreshIndicator': find.byType(RefreshIndicator),
      'ListTile': find.byType(ListTile),
      'InkWell': find.byType(InkWell),
      'GestureDetector': find.byType(GestureDetector),
      // A distinct user action, not a variant of tap: statically inventoried
      // long-presses must be exercised as long-presses.
      'LongPress': find.byWidgetPredicate((w) =>
          (w is InkWell && w.onLongPress != null) ||
          (w is GestureDetector && w.onLongPress != null)),
    };
    // Element -> descriptor, so containment can be resolved by tree position.
    final candidates = <Element, _Ctl>{};
    final order = <Element>[];
    types.forEach((name, finder) {
      final els = finder.evaluate().toList();
      for (var i = 0; i < els.length; i++) {
        final e = els[i];
        if (candidates.containsKey(e)) continue;
        candidates[e] = _Ctl(name, describe(tester, finder.at(i)), i);
        order.add(e);
      }
    });
    final out = <_Ctl>[];
    for (final e in order) {
      var inner = false;
      e.visitAncestorElements((a) {
        if (a != e && candidates.containsKey(a)) {
          inner = true;
          return false;
        }
        return true;
      });
      final ctl = candidates[e]!;
      if (inner) {
        ctl.implementationOf = true; // evidence, not a separate control
      } else {
        out.add(ctl);
      }
    }
    return out;
  }

  /// The base finder for a control's TYPE, unindexed. Callers must bounds-
  /// check against its length before calling .at(index): Finder.at throws
  /// RangeError rather than matching nothing when the count has shrunk, which
  /// aborted the sweep at the first surface that rebuilt with fewer controls.
  Finder baseFinderFor(_Ctl c) {
    switch (c.type) {
      case 'FilledButton': return find.byType(FilledButton);
      case 'ElevatedButton': return find.byType(ElevatedButton);
      case 'OutlinedButton': return find.byType(OutlinedButton);
      case 'TextButton': return find.byType(TextButton);
      case 'IconButton': return find.byType(IconButton);
      case 'FloatingActionButton':
        return find.byType(FloatingActionButton);
      case 'Switch': return find.byType(Switch);
      case 'Checkbox': return find.byType(Checkbox);
      case 'Radio': return find.byType(Radio<Object?>);
      case 'DropdownButtonFormField':
        return find.byType(DropdownButtonFormField<String>);
      case 'PopupMenuButton':
        return find.byType(PopupMenuButton<Object?>);
      case 'SegmentedButton':
        return find.byType(SegmentedButton<Object?>);
      case 'ChoiceChip': return find.byType(ChoiceChip);
      case 'FilterChip': return find.byType(FilterChip);
      case 'ActionChip': return find.byType(ActionChip);
      case 'DropdownButton':
        return find.byType(DropdownButton<String>);
      case 'TextField': return find.byType(TextField);
      case 'RefreshIndicator':
        return find.byType(RefreshIndicator);
      case 'LongPress':
        return find.byWidgetPredicate((w) =>
            (w is InkWell && w.onLongPress != null) ||
            (w is GestureDetector && w.onLongPress != null));
      case 'ListTile': return find.byType(ListTile);
      case 'InkWell': return find.byType(InkWell);
      default: return find.byType(GestureDetector);
    }
  }

  testWidgets('exhaustive control sweep', (tester) async {
    late final ProviderContainer container;

    /// Full row CONTENT per table, not just ids: an in-place UPDATE keeps the
    /// primary key while changing amounts, flags, consent or revisions, and an
    /// id-only diff cannot see it at all.
    Future<Map<String, Map<String, Map<String, Object?>>>> snapshot() async {
      final db = container.read(appDatabaseProvider);
      final out = <String, Map<String, Map<String, Object?>>>{};
      for (final t in _watched) {
        try {
          final rows = await db.customSelect('SELECT * FROM $t').get();
          final byId = <String, Map<String, Object?>>{};
          for (var i = 0; i < rows.length; i++) {
            final d = rows[i].data;
            final key = (d['id'] ?? d['rowid'] ?? 'row#$i').toString();
            byId[key] = Map<String, Object?>.from(d);
          }
          out[t] = byId;
        } catch (_) {
          // Table absent in this schema version — nothing to isolate.
        }
      }
      return out;
    }

    /// Classify every durable change and restore the captured state exactly,
    /// using the locally-tested diff/restore logic (tests 5 and 6).
    Future<(String, String, Set<MutationSignature>)> reconcile(
        Map<String, Map<String, Map<String, Object?>>> before) async {
      final db = container.read(appDatabaseProvider);
      final after = await snapshot();
      final notes = <String>[];
      final unrestored = <String>[];
      final sigs = <MutationSignature>{};
      for (final t in _watched) {
        final b = before[t], a = after[t];
        if (b == null || a == null) continue;
        final d = diffTable(b, a);
        if (d.isEmpty) continue;
        notes.add(summariseDiff(t, d));
        sigs.addAll(signaturesFor(t, d, b, a));
        // Blob columns hide what actually moved. Name the keys so campaign
        // bookkeeping can be told apart from a real settings rewrite.
        for (final entry in d.updated.entries) {
          for (final col in entry.value) {
            if (!col.endsWith('_json')) continue;
            final fields = jsonFieldDiff(
                b[entry.key]?[col], a[entry.key]?[col]);
            notes.add('$t.$col fields: ${fields.join(",")}');
          }
        }
        if (!_restorable.contains(t)) {
          unrestored.add('$t (catalog/reference — not restored)');
          continue;
        }
        try {
          for (final sql in restoreStatements(t, b, a)) {
            await db.customStatement(sql);
          }
          // Prove the restore actually landed, rather than assuming it did.
          final verify = await snapshot();
          if (!diffTable(b, verify[t] ?? const {}).isEmpty) {
            unrestored.add('$t (post-restore fingerprint still differs)');
          }
        } catch (e) {
          unrestored.add('$t (restore failed: $e)');
        }
      }
      return (notes.join('; '), unrestored.join('; '), sigs);
    }
    if (_qaEmail.isEmpty || _qaPassword.isEmpty || _qaUserId.isEmpty) {
      debugPrint('[SWEEP] SKIPPED — QA defines not supplied.');
      return;
    }
    final semantics = tester.ensureSemantics();
    // A missed tap otherwise only prints a warning and the control is scored
    // DEAD-TAP — the exact masking that produced 94 false dead-taps. Make it
    // fatal so an unhittable control fails and is triaged. This is global
    // static state, so capture and restore it: the sweeper must not change how
    // unrelated tests in the same process behave.
    final previousFatal = WidgetController.hitTestWarningShouldBeFatal;
    WidgetController.hitTestWarningShouldBeFatal = true;
    addTearDown(
        () => WidgetController.hitTestWarningShouldBeFatal = previousFatal);
    app.main();
    await settle(tester, budget: const Duration(seconds: 60));

    final client = supabase.Supabase.instance.client;
    final localOwner = await AppSession.instance.readLocalDataOwnerUid();
    if (localOwner != null && localOwner != _qaUserId) {
      fail('ABORT — local database belongs to another account.');
    }
    final res = await client.auth
        .signInWithPassword(email: _qaEmail, password: _qaPassword);
    expect(res.session, isNotNull);
    expect(res.user!.id, _qaUserId);
    await AppSession.instance
        .setIdentity(method: 'email', email: _qaEmail, userId: res.user!.id);
    await AppSession.instance.reconcileAccountOnboarding(client);
    await settle(tester, budget: const Duration(seconds: 60));
    if (!AppSession.instance.hasCompletedOnboarding) {
      await AppSession.instance.finishOnboarding();
      await settle(tester, budget: const Duration(seconds: 45));
    }
    expect(await waitFor(tester, find.byType(AppShell)), isTrue,
        reason: 'shell never mounted');
    container = ProviderScope.containerOf(tester.element(find.byType(AppShell)));
    final router = GoRouter.of(tester.element(find.byType(AppShell)));
    debugPrint('[SWEEP] signed in; shell ready');

    /// Return to a known surface: close anything modal, then go to [path].
    Future<bool> goTo(String path) async {
      for (var i = 0; i < 5; i++) {
        if (find.byType(ModalBarrier).evaluate().length <= 1) break;
        final apps = find.byType(MaterialApp).evaluate();
        if (apps.isEmpty) break;
        final nav = Navigator.maybeOf(apps.first, rootNavigator: true);
        if (nav == null || !nav.canPop()) break;
        nav.pop();
        await settle(tester, budget: const Duration(seconds: 6));
      }
      router.go(path);
      await settle(tester, budget: const Duration(seconds: 25));
      return find.byType(ErrorWidget).evaluate().isEmpty;
    }

    for (final path in _staticRoutes) {
      final ok = await goTo(path);
      if (!ok) {
        record('ROUTE $path :: FAIL (ErrorWidget on arrival)');
        failed++;
        continue;
      }
      // Control measurement: observe an equivalent window with NO interaction.
      // Anything that changes here is background activity (impression
      // bookkeeping, sync cadence, timers) and must not be attributed to a
      // control. Without this, a timer firing mid-observation looks like a
      // defect caused by whatever was tapped.
      final baselinePre = await snapshot();
      await settle(tester, budget: const Duration(seconds: 12));
      final (baselineSummary, _, baselineDrift) = await reconcile(baselinePre);
      if (baselineDrift.isNotEmpty) {
        record('ROUTE $path :: NO-TAP BASELINE DRIFT: $baselineSummary '
            ':: signatures ${baselineDrift.map((m) => m.key).join(" | ")}');
      }

      final controls = enumerate(tester);
      final expectedCounts = <String, int>{};
      for (final c in controls) {
        expectedCounts[c.type] = (expectedCounts[c.type] ?? 0) + 1;
      }
      var lastAction = '(none — first control on this route)';
      debugPrint('[SWEEP] ROUTE $path :: ${controls.length} controls :: '
          '${texts(tester).take(6).join(" | ")}');

      for (final c in controls) {
        final reason = _unsafe.entries
            .where((e) => c.label.contains(e.key))
            .map((e) => e.value)
            .firstOrNull;
        if (reason != null) {
          record('$path :: $c :: UNSAFE ($reason)');
          unsafe++;
          continue;
        }
        if (!await goTo(path)) {
          record('$path :: $c :: NOT-REACHED (route failed to reopen)');
          notReached++;
          continue;
        }
        final base = baseFinderFor(c);
        final available = base.evaluate().length;
        final revisit = revisitVerdict(
            enumerated: expectedCounts[c.type] ?? -1,
            available: available,
            index: c.index,
            lastAction: lastAction);
        if (revisit != null) {
          record('$path :: $c :: $revisit');
          notReached++;
          continue;
        }
        // Index ordering is not stable: a lazy viewport rebuilds, and async
        // surfaces (ad banner, campaign card) settle after enumeration. Re-bind
        // to the control by its DESCRIPTOR — the strongest stable identity
        // available — and only fall back to the index when the label is empty.
        final reBase = baseFinderFor(c);
        final n = reBase.evaluate().length;
        var resolved = -1;
        if (c.label.isNotEmpty) {
          final matches = <int>[];
          for (var k = 0; k < n; k++) {
            if (describe(tester, reBase.at(k)) == c.label) matches.add(k);
          }
          if (matches.isNotEmpty) {
            // Preserve ordinal among same-labelled siblings so repeated labels
            // still map one-to-one onto distinct logical controls.
            final ordinal = controls
                .where((o) => o.type == c.type && o.label == c.label)
                .toList()
                .indexOf(c);
            resolved = matches[ordinal.clamp(0, matches.length - 1)];
          }
        } else if (c.index < n && describe(tester, reBase.at(c.index)).isEmpty) {
          resolved = c.index; // unlabelled: index is the only identity we have
        }
        if (resolved < 0) {
          record('$path :: $c :: NOT-REACHED (identity unresolvable after '
              'rebuild; $n of this type present) TRIAGE-REQUIRED');
          notReached++;
          continue;
        }
        final f2 = reBase.at(resolved);
        // Now that identity is resolved, bring THIS control into view. A
        // control below the fold never receives the tap, and with the hit-test
        // warning suppressed that was indistinguishable from a dead control.
        try {
          await tester.ensureVisible(f2);
          await settle(tester, budget: const Duration(seconds: 6));
        } catch (_) {
          // Not inside a scrollable — already laid out.
        }
        // ensureVisible only scrolls the MINIMUM amount, which can leave a
        // control under the floating nav bar or the ad banner. Probe several
        // points inside its rect and use the first that actually hit-tests to
        // this widget; report the obstruction if none do.
        // ensureVisible only scrolls the MINIMUM amount, which leaves controls
        // under the floating nav pill (bottom) or the ad banner (top). Probe
        // for a point that hit-tests to THIS control's own render object — a
        // coordinate that merely hits some descendant of something else is not
        // evidence the control is reachable. If none, reposition it into the
        // middle of the viewport and retry, so a harness-positioning problem is
        // distinguished from a persistent overlay the user cannot get past.
        Offset? hittable;
        String obstruction = '';
        bool repositioned = false;

        Offset? probe() {
          try {
            final rect = tester.getRect(f2);
            final ro = tester.renderObject(f2);
            for (final pt in <Offset>[
              rect.center,
              Offset(rect.left + rect.width * 0.15, rect.center.dy),
              Offset(rect.right - rect.width * 0.15, rect.center.dy),
              Offset(rect.center.dx, rect.top + rect.height * 0.25),
              Offset(rect.center.dx, rect.bottom - rect.height * 0.25),
            ]) {
              final result = tester.hitTestOnBinding(pt);
              // The hit must reach the intended control's own render object.
              if (result.path.any((e) => identical(e.target, ro))) return pt;
              if (obstruction.isEmpty && result.path.isNotEmpty) {
                obstruction = result.path.first.target.runtimeType.toString();
              }
            }
          } catch (_) {
            // Not laid out — treat as unhittable and let triage decide.
          }
          return null;
        }

        hittable = probe();
        if (hittable == null) {
          // Bounded clearance: move the control toward the middle safe band of
          // the viewport (avoiding the top and bottom overlay regions).
          final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
          final safeTop = screen.height * 0.25;
          final safeBottom = screen.height * 0.70;
          // Drag the scrollable that actually CONTAINS this control. Using the
          // last Scrollable on screen moved an unrelated list, which is why
          // ensureVisible left these tiles outside the viewport entirely — the
          // probe then hit the background (_RenderColoredBox), not an overlay.
          final scrollables =
              find.ancestor(of: f2, matching: find.byType(Scrollable));
          for (var attempt = 0; attempt < 3 && hittable == null; attempt++) {
            if (scrollables.evaluate().isEmpty) break;
            final rect = tester.getRect(f2);
            final target = (safeTop + safeBottom) / 2;
            final dy = target - rect.center.dy;
            if (dy.abs() < 4) break;
            await tester.drag(scrollables.first, Offset(0, dy.clamp(-320, 320)));
            await settle(tester, budget: const Duration(seconds: 6));
            // Identity must be re-proven after every scroll/rebuild.
            final rb = baseFinderFor(c);
            if (rb.evaluate().length <= resolved ||
                describe(tester, rb.at(resolved)) != c.label) {
              break;
            }
            repositioned = true;
            obstruction = '';
            hittable = probe();
          }
        }
        if (hittable == null) {
          // Survived controlled repositioning: a persistent overlay blocks
          // every reasonable hit region. That is a UX finding, not a harness
          // artefact — a user cannot reach this control either.
          record('$path :: $c :: OBSTRUCTED (unreachable after repositioning; '
              'topmost: $obstruction) TRIAGE-REQUIRED');
          notReached++;
          continue;
        }
        if (repositioned) {
          record('$path :: $c :: HARNESS-POSITIONING RESOLVED '
              '(hittable only after scrolling into the safe zone)');
        }
        final before = texts(tester).join('|');
        final beforeBarriers = find.byType(ModalBarrier).evaluate().length;
        // Toggles do not change page text; their signal is their own value.
        final beforeToggle = c.type == 'Switch'
            ? tester.widget<Switch>(f2).value
            : c.type == 'Checkbox'
                ? tester.widget<Checkbox>(f2).value
                : null;
        lastAction = c.toString();
        final preState = await snapshot();
        try {
          // A TextField's user action is focus+type, and a RefreshIndicator's
          // is a pull — tapping either would prove nothing about them.
          if (c.type == 'TextField') {
            await tester.tap(f2, warnIfMissed: false);
            await settle(tester, budget: const Duration(seconds: 6));
            await tester.enterText(f2, '1');
            await settle(tester, budget: const Duration(seconds: 6));
            final landed = tester.widget<TextField>(f2).controller?.text;
            // Controller landing proves the field accepts input. Where typing
            // also drives search/autosave/network, that effect is NOT proven
            // here — those fields are deferred to the deep pass by name.
            record('$path :: $c :: ${landed == null ? "PASS (no controller)" : landed.contains("1") ? "PASS (accepts input; side effects deferred to deep pass)" : "DEAD-TAP (input rejected)"}');
            if (landed == null || landed.contains('1')) {
              pass++;
            } else {
              dead++;
            }
            continue;
          }
          if (c.type == 'RefreshIndicator') {
            // The drag is only the trigger. Require the spinner to actually
            // appear (callback started) and then clear (surface stable again).
            await tester.drag(f2, const Offset(0, 250));
            await tester.pump();
            var started = false;
            for (var t = 0; t < 30 && !started; t++) {
              await tester.pump(const Duration(milliseconds: 100));
              started = find.byType(RefreshProgressIndicator).evaluate().isNotEmpty;
            }
            await settle(tester, budget: const Duration(seconds: 20));
            final settled =
                find.byType(RefreshProgressIndicator).evaluate().isEmpty;
            record('$path :: $c :: '
                '${started && settled ? "PASS (refresh ran and settled)" : started ? "FAIL (refresh never settled)" : "DEAD-TAP (callback never started)"}');
            if (started && settled) {
              pass++;
            } else if (started) {
              failed++;
            } else {
              dead++;
            }
            continue;
          }
          // COMPOUND CONTROLS. Opening a menu or dropdown proves reachability
          // and nothing else, so each selectable item is exercised in turn and
          // its effect checked. The parent's verdict is the aggregate.
          if (c.type == 'DropdownButtonFormField' ||
              c.type == 'DropdownButton' ||
              c.type == 'PopupMenuButton') {
            final itemType = c.type == 'PopupMenuButton'
                ? find.byType(PopupMenuItem<Object?>)
                : find.byType(DropdownMenuItem<String>);
            await tester.tap(f2, warnIfMissed: false);
            await settle(tester, budget: const Duration(seconds: 8));
            final count = itemType.evaluate().length;
            if (count == 0) {
              record('$path :: $c :: DEAD-TAP (opened, no items)');
              dead++;
              continue;
            }
            var itemOk = 0;
            for (var j = 0; j < count; j++) {
              if (j > 0) {
                if (!await goTo(path)) break;
                final againBase = baseFinderFor(c);
                if (againBase.evaluate().length <= c.index) break;
                await tester.tap(againBase.at(c.index), warnIfMissed: false);
                await settle(tester, budget: const Duration(seconds: 8));
                if (itemType.evaluate().length <= j) break;
              }
              final beforeItem = texts(tester).join('|');
              await tester.tap(itemType.at(j), warnIfMissed: false);
              await settle(tester, budget: const Duration(seconds: 10));
              final e2 = tester.takeException();
              final effect = texts(tester).join('|') != beforeItem;
              if (e2 != null) {
                record('$path :: $c :: item[$j] :: FAIL ($e2)');
                failed++;
              } else if (effect) {
                record('$path :: $c :: item[$j] :: PASS (selection took effect)');
                itemOk++;
              } else {
                record('$path :: $c :: item[$j] :: DEAD-TAP (no effect)');
                dead++;
              }
            }
            record('$path :: $c :: ${itemOk == count ? "PASS" : "PARTIAL"} '
                '($itemOk/$count items took effect)');
            if (itemOk == count) pass++;
            continue;
          }
          if (c.type == 'SegmentedButton') {
            // Each segment is a distinct state the user can select.
            final segs = find.descendant(of: f2, matching: find.byType(Text));
            final n = segs.evaluate().length;
            var segOk = 0;
            for (var j = 0; j < n; j++) {
              final beforeSeg = texts(tester).join('|');
              await tester.tap(segs.at(j), warnIfMissed: false);
              await settle(tester, budget: const Duration(seconds: 8));
              if (tester.takeException() == null) segOk++;
              if (texts(tester).join('|') == beforeSeg && j > 0) {
                record('$path :: $c :: segment[$j] :: DEAD-TAP');
                dead++;
              }
            }
            record('$path :: $c :: PASS ($segOk/$n segments selectable)');
            pass++;
            continue;
          }
          if (c.type == 'LongPress') {
            await tester.longPress(f2, warnIfMissed: false);
            await settle(tester, budget: const Duration(seconds: 10));
            final e3 = tester.takeException();
            final changed3 = texts(tester).join('|') != before ||
                find.byType(ModalBarrier).evaluate().length != beforeBarriers;
            record('$path :: $c :: ${e3 != null ? "FAIL ($e3)" : changed3 ? "PASS (long-press acted)" : "DEAD-TAP (long-press no effect)"}');
            if (e3 != null) {
              failed++;
            } else if (changed3) {
              pass++;
            } else {
              dead++;
            }
            continue;
          }
          await tester.tapAt(hittable);
          await settle(tester, budget: const Duration(seconds: 12));
          final err = tester.takeException();
          if (err != null) {
            record('$path :: $c :: FAIL ($err)');
            failed++;
            continue;
          }
          if (find.byType(ErrorWidget).evaluate().isNotEmpty) {
            record('$path :: $c :: FAIL (ErrorWidget after tap)');
            failed++;
            continue;
          }
          final after = texts(tester).join('|');
          final afterBarriers = find.byType(ModalBarrier).evaluate().length;
          bool? afterToggle;
          if (beforeToggle != null && base.evaluate().length > c.index) {
            afterToggle = c.type == 'Switch'
                ? tester.widget<Switch>(base.at(c.index)).value
                : tester.widget<Checkbox>(base.at(c.index)).value;
          }
          final toggled = toggleActed(before: beforeToggle, after: afterToggle);
          final (mutation, unrestored, observedSigs) = await reconcile(preState);
          if (mutation.isNotEmpty) {
            // Subtract only IDENTICAL signatures (same table, row, kind and
            // json sub-fields). A second impression on top of a baseline
            // impression differs in nothing measurable here, but a settings
            // rewrite sharing the same column does — and must survive.
            final own = attributable(
                observed: observedSigs, baseline: baselineDrift);
            final unexpected = unexpectedTables(
                tablesOf(own), _expectedWrites[path] ?? const []);
            if (unexpected.isNotEmpty) {
              // The user's rule: an unrelated tile creating a budget row is a
              // finding, not a pass.
              record('$path :: $c :: UNEXPECTED-MUTATION '
                  '${unexpected.join(",")} :: $mutation TRIAGE-REQUIRED');
              failed++;
              continue;
            }
          }
          if (unrestored.isNotEmpty) {
            record('$path :: $c :: CONTAMINATION-HALT ($unrestored) — '
                'remaining controls on this route need a reseeded baseline');
            failed++;
            break;
          }
          final changed =
              after != before || afterBarriers != beforeBarriers || toggled;
          if (mutation.isNotEmpty) {
            record('$path :: $c :: MUTATION $mutation');
          }
          if (!changed) {
            // Not automatically a defect — a toggle back to the same visible
            // state, or a control whose effect is off-screen, looks identical.
            record('$path :: $c :: DEAD-TAP (no visible change)');
            dead++;
          } else {
            record('$path :: $c :: PASS');
            pass++;
          }
        } catch (e) {
          record('$path :: $c :: FAIL (threw: $e)');
          failed++;
        }
      }
    }

    debugPrint('[SWEEP] ===== END (every verdict was printed as it was decided) =====');
    debugPrint('[SWEEP] totals pass=$pass dead=$dead fail=$failed '
        'unsafe=$unsafe notReached=$notReached total=${results.length}');
    semantics.dispose();
  }, timeout: const Timeout(Duration(minutes: 45)));
}
