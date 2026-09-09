import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;
import 'package:money_companion/main.dart' as app;
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/features/app/app_shell.dart';

/// FOCUSED PROBE — why are /settings navigation tiles unhittable?
///
/// The sweep reports 38 controls that Flutter's own hit test refuses, all with
/// rects at y≈0 (under the status bar / header) and all inside a scrollable
/// spanning the full screen. Repositioning never moved them and never failed.
/// Rather than infer from a 12-minute full sweep, this walks ONE tile and logs
/// every step: rect, scroll extent, drag, re-resolution, hit path.
const _qaEmail = String.fromEnvironment('QA_EMAIL');
const _qaPassword = String.fromEnvironment('QA_PASSWORD');
const _qaUserId = String.fromEnvironment('QA_USER_ID');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> settle(WidgetTester t,
      {Duration budget = const Duration(seconds: 20)}) async {
    final end = DateTime.now().add(budget);
    while (DateTime.now().isBefore(end)) {
      await t.pump(const Duration(milliseconds: 200));
      if (!t.binding.hasScheduledFrame) break;
    }
  }

  testWidgets('settings tile hittability', (tester) async {
    if (_qaEmail.isEmpty) return;
    tester.ensureSemantics();
    app.main();
    await settle(tester, budget: const Duration(seconds: 60));

    final client = supabase.Supabase.instance.client;
    final owner = await AppSession.instance.readLocalDataOwnerUid();
    if (owner != null && owner != _qaUserId) fail('foreign local data');
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
    final ctx = tester.element(find.byType(AppShell));
    GoRouter.of(ctx).go('/settings');
    await settle(tester, budget: const Duration(seconds: 25));

    const label = 'الحسابات والمحافظ';
    final tile = find.ancestor(
        of: find.text(label), matching: find.byType(ListTile));
    debugPrint('[P] tiles matching "$label": ${tile.evaluate().length}');
    if (tile.evaluate().isEmpty) {
      debugPrint('[P] ABSENT — not built');
      return;
    }

    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    debugPrint('[P] screen=${screen.width.toStringAsFixed(0)}x'
        '${screen.height.toStringAsFixed(0)}');

    void dump(String tag) {
      final r = tester.getRect(tile.first);
      final ro = tester.renderObject(tile.first);
      final hit = tester.hitTestOnBinding(r.center);
      final reaches = hit.path.any((e) => identical(e.target, ro));
      debugPrint('[P] $tag rect=${r.top.toStringAsFixed(0)}..'
          '${r.bottom.toStringAsFixed(0)} centre=${r.center.dy.toStringAsFixed(0)} '
          'reaches=$reaches top3=${hit.path.take(3).map((e) => e.target.runtimeType).join(">")}');
    }

    dump('initial');

    // What scrollables enclose it, and what are their extents?
    final scAll = find.ancestor(of: tile, matching: find.byType(Scrollable));
    debugPrint('[P] scrollable ancestors=${scAll.evaluate().length}');
    for (var i = 0; i < scAll.evaluate().length; i++) {
      final sr = tester.getRect(scAll.at(i));
      final st = tester.state<ScrollableState>(scAll.at(i));
      debugPrint('[P]   sc$i rect=${sr.top.toStringAsFixed(0)}..'
          '${sr.bottom.toStringAsFixed(0)} offset='
          '${st.position.pixels.toStringAsFixed(0)} '
          'max=${st.position.maxScrollExtent.toStringAsFixed(0)} '
          'axis=${st.position.axis}');
    }

    await tester.ensureVisible(tile.first);
    await settle(tester, budget: const Duration(seconds: 8));
    dump('after ensureVisible');

    // Drag DOWN from mid-viewport to bring it below the header.
    for (var i = 0; i < 3; i++) {
      await tester.dragFrom(Offset(screen.width / 2, screen.height * 0.5),
          const Offset(0, 200));
      await settle(tester, budget: const Duration(seconds: 6));
      dump('after dragFrom #${i + 1}');
      if (tile.evaluate().isEmpty) {
        debugPrint('[P] tile unbuilt after drag');
        return;
      }
    }

    // Ground truth: does a real tap work now?
    try {
      await tester.tap(tile.first);
      await settle(tester, budget: const Duration(seconds: 12));
      debugPrint('[P] TAP OK — navigated? '
          '${find.text('الحسابات والمحافظ').evaluate().length}');
    } catch (e) {
      debugPrint('[P] TAP REFUSED: ${e.toString().split("\n").first}');
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
