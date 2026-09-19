import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:money_companion/app.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/router/app_router.dart';
import 'package:money_companion/core/security/secure_storage_options.dart';
import 'package:money_companion/core/theme/theme_mode_controller.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/ads/ad_placement.dart';
import 'package:money_companion/features/ads/banner_ad_controller.dart';
import 'package:money_companion/features/ads/banner_ads_providers.dart';
import 'package:money_companion/features/ads/qirsh_ad_banner.dart';
import 'package:money_companion/features/ads/report_banner_suppression.dart';
import 'package:money_companion/features/app/app_shell.dart';
import 'package:money_companion/features/common/app_pill_tab_bar.dart';
import 'package:money_companion/features/goals/goals_providers.dart';
import 'package:money_companion/features/report_ads/report_entitlement.dart';
import 'package:money_companion/features/reports/reports_screen.dart';
import 'package:money_companion/main.dart' as app;

/// AD PLACEMENT QA — the real app, the real gates, on a device.
///
/// ## What is real here, and what is not
///
/// The whole app runs: `MoneyApp`, the real router, the real `AppShell` with
/// its floating navigation bar. The FLAG gate is real — the placements are
/// turned on by writing rows into this device's own `remote_feature_flags`
/// table, the same local cache a catalog sync fills, and they are deleted
/// again at the end. The build-config gate, the visual gates, the Reports
/// suppression and its cooldown, and the request throttle and its retry are
/// all the shipping ones.
///
/// TWO gates are stubbed, and only two: `bannerEntitlementProvider` and
/// `bannerConsentProvider`. Both reach outside the device — entitlement to
/// Supabase, consent to UMP — and a debug build without `SUPABASE_URL` has no
/// instance to reach. Supplying that, and the QA account behind it, is an owner
/// action. **Neither gate is verified by this walk**, and the report says so.
///
/// ## Isolation
///
/// The request throttle is static and per placement, so visiting one surface in
/// four locale/theme combinations inside a single session would leave three of
/// them looking at an empty slot for reasons that have nothing to do with the
/// combination. Every case starts from a cleared throttle and cleared
/// suppression. An earlier run without this reported `h0` three times in four
/// and it meant nothing.
///
/// ## Waiting for the ad, not for the widget
///
/// `AdWidget` is a platform view: Flutter reserves the box before the native
/// view has composited anything into it. An earlier run captured the reserved
/// box and produced screenshots of an "Advertisement" label over a blank
/// rectangle, which is not what the screen looks like. Captures here wait for a
/// non-zero height AND for real time to pass afterwards.
///
/// ## Ads: TEST UNITS ONLY
///
/// A debug build resolves `AdMobBuildConfig` to Google's test publisher ids.
/// Nothing here picks an ad unit; the build does.

const _flagKeys = <String>[
  'enable_banner_ads',
  'enable_banner_dashboard',
  'enable_banner_goals',
  'enable_banner_subscriptions',
  'enable_banner_reports',
  'enable_banner_achievements',
  'enable_banner_transactions_list',
];

const _seedMark = 'adqa-seed';

Future<void> _clearSeed(dynamic db) async {
  for (final sql in const [
    "DELETE FROM transactions WHERE raw_message LIKE '%$_seedMark%'",
    "DELETE FROM goals WHERE name LIKE '%$_seedMark%'",
    "DELETE FROM subscriptions WHERE name LIKE '%$_seedMark%'",
    "DELETE FROM accounts WHERE name LIKE '%$_seedMark%'",
  ]) {
    await db.customStatement(sql);
  }
}

/// A banner that is absent is never silently a pass.
enum _R { pass, fail, blocked }

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await SecureStorageOptions.storage
        .write(key: 'app_lock_enabled', value: '0');
  });

  testWidgets('ad placement QA', (tester) async {
    WidgetController.hitTestWarningShouldBeFatal = false;
    final report = <String>[];
    void record(_R r, String what, [String detail = '']) {
      final line = '${r.name.toUpperCase().padRight(7)} $what'
          '${detail.isEmpty ? '' : '  ($detail)'}';
      debugPrint('[ADQA] $line');
      report.add(line);
    }

    Future<void> settle(WidgetTester t,
        {Duration budget = const Duration(seconds: 10)}) async {
      final deadline = DateTime.now().add(budget);
      while (DateTime.now().isBefore(deadline)) {
        await t.pump(const Duration(milliseconds: 100));
        if (!t.binding.hasScheduledFrame) break;
      }
    }

    /// Real elapsed time, which a platform view needs in order to composite and
    /// which `pump` alone does not provide.
    Future<void> realDelay(WidgetTester t, Duration d) async {
      await t.runAsync(() => Future<void>.delayed(d));
      await settle(t, budget: const Duration(seconds: 2));
    }

    Future<bool> waitFor(WidgetTester t, Finder f,
        {Duration timeout = const Duration(seconds: 60)}) async {
      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        await t.pump(const Duration(milliseconds: 150));
        if (f.evaluate().isNotEmpty) return true;
      }
      return false;
    }

    // ── Bootstrap, purely for a real database ─────────────────────────────
    app.main();
    await settle(tester, budget: const Duration(seconds: 60));
    if (!await waitFor(tester, find.byType(AppShell))) {
      record(_R.blocked, 'boot', 'the shell never mounted');
      return;
    }
    final db = ProviderScope.containerOf(tester.element(find.byType(AppShell)))
        .read(appDatabaseProvider);
    final boot =
        ProviderScope.containerOf(tester.element(find.byType(AppShell)));

    // ── Flags ON, locally and for real ────────────────────────────────────
    final syncedAt = DateTime.now().toUtc().toIso8601String();
    for (final key in _flagKeys) {
      await db.customStatement(
        'INSERT OR REPLACE INTO remote_feature_flags'
        '(key, value_type, value, rollout_percent, target_countries,'
        ' is_active, synced_at) VALUES (?, ?, ?, ?, ?, ?, ?);',
        [key, 'boolean', 'true', 100, '[]', 1, syncedAt],
      );
    }
    await initFeatureFlagService(db, applyRemoteOverrides: false);

    // ── Seed enough data to reach the populated states ────────────────────
    const sar = 'SAR';
    final t0 = DateTime.now();
    await _clearSeed(db);
    final account = await boot.read(accountRepositoryProvider).create(
          AccountEntity(
            id: 'adqa-acc',
            name: 'حساب $_seedMark',
            currency: sar,
            type: AccountType.bank,
            isDefault: true,
            sortOrder: 0,
            createdAt: t0.subtract(const Duration(days: 60)),
            updatedAt: t0,
            initialBalanceMoney: Money(1500000, sar),
            currentBalanceMoney: Money(1500000, sar),
          ),
        );
    const basket = <(String, String, int)>[
      ('البيك', 'restaurants', 4200),
      ('بنده', 'groceries', 18000),
      ('كريم', 'transport', 3100),
      ('ساسكو', 'fuel', 12000),
      ('ستاربكس', 'cafes', 2600),
      ('نون', 'shopping', 24000),
    ];
    for (var day = 27; day >= 0; day--) {
      final pick = basket[day % basket.length];
      final at = t0.subtract(Duration(days: day, hours: 9));
      await boot.read(transactionRepositoryProvider).saveTransaction(
            transaction: TransactionEntity(
              id: 'adqa-tx-$day',
              amountMoney: Money(pick.$3 + day * 40, sar),
              currency: sar,
              type: TransactionTypeEntity.payment,
              source: TransactionSourceEntity.card,
              occurredAt: at,
              rawMessage: 'شراء لدى ${pick.$1} · $_seedMark',
              parseConfidence: 0.97,
              status: TransactionStatus.confirmed,
              createdAt: at,
              updatedAt: at,
              rawMerchant: pick.$1,
              accountId: account.id,
              direction: TransactionDirectionEntity.debit,
            ),
            categoryKey: pick.$2,
          );
    }
    for (final g in const <(String, int, int)>[
      ('رحلة الصيف', 1500000, 1275000),
      ('آيفون جديد', 600000, 240000),
      ('صندوق طوارئ', 2000000, 350000),
    ]) {
      await boot.read(goalRepositoryProvider).save(GoalEntity(
            id: 'adqa-goal-${g.$1.hashCode}',
            name: '${g.$1} · $_seedMark',
            currency: sar,
            targetMoney: Money(g.$2, sar),
            savedMoney: Money(g.$3, sar),
            lastNotifiedSavedMoney: Money(0, sar),
            vaultSkin: 'summer_trip',
            status: 'active',
            createdAt: t0.subtract(const Duration(days: 40)),
            accountId: account.id,
          ));
    }
    for (final b in const <(String, int, BillType)>[
      ('Netflix', 5600, BillType.subscription),
      ('STC', 22000, BillType.subscription),
      ('قسط السيارة', 150000, BillType.installment),
    ]) {
      await boot.read(billRepositoryProvider).save(BillEntity(
            id: 'adqa-bill-${b.$1.hashCode}',
            name: '${b.$1} · $_seedMark',
            amountMoney: Money(b.$2, sar),
            currency: sar,
            type: b.$3,
            frequency: BillFrequency.monthly,
            nextDueDate: t0.add(const Duration(days: 9)),
            reminderOn: true,
            isConfirmed: true,
            createdAt: t0.subtract(const Duration(days: 40)),
            accountId: account.id,
          ));
    }

    // ── The REAL app, with only the two outside-the-device gates stubbed ──
    await tester.pumpWidget(ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        bannerEntitlementProvider.overrideWith(
            (ref) async => ReportEntitlementState.verifiedInactive),
        bannerConsentProvider.overrideWith((ref) async => true),
      ],
      child: const MoneyApp(),
    ));
    await settle(tester, budget: const Duration(seconds: 30));
    if (!await waitFor(tester, find.byType(AppShell))) {
      record(_R.blocked, 'harness', 'the real shell did not mount');
      return;
    }
    final container =
        ProviderScope.containerOf(tester.element(find.byType(AppShell)));
    record(_R.pass, 'harness · real AppShell, real flag gate, real cooldown');

    Future<void> goto(String target) async {
      if (target.startsWith('tab:')) {
        appRouter.go('/');
        await settle(tester, budget: const Duration(seconds: 5));
        container.read(shellIndexProvider.notifier).state =
            int.parse(target.substring(4));
      } else {
        appRouter.go(target);
      }
      await settle(tester, budget: const Duration(seconds: 12));
    }

    Future<void> scrollToFoot(WidgetTester t) async {
      final s = find.byType(Scrollable);
      if (s.evaluate().isEmpty) return;
      final pos = t.state<ScrollableState>(s.first).position;
      for (var i = 0; i < 30; i++) {
        if (pos.pixels >= pos.maxScrollExtent) break;
        pos.jumpTo((pos.pixels + 600).clamp(0.0, pos.maxScrollExtent));
        await settle(t, budget: const Duration(seconds: 2));
      }
    }

    double? paintedHeight() {
      final f = find.byType(QirshAdBanner);
      if (f.evaluate().isEmpty) return null;
      return tester.getSize(f.first).height;
    }

    /// A SUPPRESSED banner is still in the tree.
    ///
    /// Every gate returns `SizedBox.shrink()` and leaves the widget mounted, so
    /// `find.byType(...).isEmpty` is not "the banner is hidden" — it is "the
    /// banner is offstage or gone". The first run of this harness used it for
    /// the suppression checks and reported three false FAILs against code the
    /// unit tests prove works. Zero painted height is what "hidden" means here.
    bool isHidden() {
      final h = paintedHeight();
      return h == null || h == 0;
    }

    bool mountedButUnpainted() =>
        find.byType(QirshAdBanner).evaluate().isEmpty &&
        find.byType(QirshAdBanner, skipOffstage: false).evaluate().isNotEmpty;

    /// Waits for a LOADED banner, then for the native view to composite.
    Future<double?> awaitLoadedAd(WidgetTester t,
        {Duration budget = const Duration(seconds: 25)}) async {
      final deadline = DateTime.now().add(budget);
      while (DateTime.now().isBefore(deadline)) {
        final h = paintedHeight();
        if (h != null && h > 0) {
          await realDelay(t, const Duration(milliseconds: 1200));
          return paintedHeight();
        }
        await realDelay(t, const Duration(milliseconds: 500));
      }
      return null;
    }

    /// Distance to the pill tab bar above it and to the screen foot below.
    String geometry() {
      final b = find.byType(QirshAdBanner);
      if (b.evaluate().isEmpty) return '';
      final r = tester.getRect(b.first);
      final parts = <String>['top=${r.top.round()}'];
      final tabs = find.byType(AppPillTabBar);
      if (tabs.evaluate().isNotEmpty) {
        final t = tester.getRect(tabs.first);
        parts.add('tabGap=${(t.top - r.bottom).round()}');
      }
      final h = tester.view.physicalSize.height / tester.view.devicePixelRatio;
      parts.add('below=${(h - r.bottom).round()}');
      return parts.join(' ');
    }

    Future<void> shoot(String tag) async {
      await settle(tester, budget: const Duration(seconds: 2));
      await binding.takeScreenshot('adqa-$tag');
    }

    void isolate() {
      BannerAdController.resetThrottleForTest();
      ReportBannerSuppression.resetForTest();
      for (final p in AdPlacement.values) {
        container.invalidate(bannerEligibilityProvider(p));
      }
    }

    const surfaces = <String, String>{
      'dashboard': 'tab:0',
      'reports': 'tab:4',
      'goals': '/goals',
      'subscriptions': '/subscriptions',
      'achievements': '/achievements',
    };
    const headerPlacements = {'reports', 'subscriptions'};

    for (final lang in const ['ar', 'en']) {
      await container.read(saveLanguageUseCaseProvider).call(lang);
      await settle(tester, budget: const Duration(seconds: 8));
      for (final theme in const ['light', 'dark']) {
        await container
            .read(themeModeProvider.notifier)
            .set(theme == 'dark' ? ThemeMode.dark : ThemeMode.light);
        await settle(tester, budget: const Duration(seconds: 6));
        final combo = '$lang-$theme';

        for (final entry in surfaces.entries) {
          final name = entry.key;
          isolate();
          try {
            await goto(entry.value);
            if (!headerPlacements.contains(name)) await scrollToFoot(tester);
            final h = await awaitLoadedAd(tester);
            if (h != null) {
              await shoot('$combo-$name');
              // A LOADED ad is not a VISIBLE ad. The first version of this
              // check stopped at "height > 0", which passed every surface —
              // including the dashboard, whose slot sits entirely below the
              // fold once the ad grows the list under a reader already at the
              // bottom. Being on screen is part of the pass.
              final r = tester.getRect(find.byType(QirshAdBanner).first);
              final screen =
                  tester.view.physicalSize.height / tester.view.devicePixelRatio;
              final offBottom = r.bottom - screen;
              record(offBottom > 1 ? _R.fail : _R.pass, '$combo · $name',
                  'h${h.round()} ${geometry()}'
                  '${offBottom > 1 ? "  OFF-SCREEN by ${offBottom.round()}px" : ""}');
            } else if (mountedButUnpainted()) {
              await shoot('$combo-$name-unpainted');
              record(_R.fail, '$combo · $name', 'mounted, never painted an ad');
            } else {
              await shoot('$combo-$name-absent');
              record(_R.fail, '$combo · $name',
                  'no banner in the tree — a gate closed or it was not reached');
            }
          } catch (e) {
            record(_R.blocked, '$combo · $name', '$e');
          }
        }
      }
    }

    // ── Tab switching, BY LABEL so RTL is not a coin toss ────────────────
    for (final name in headerPlacements) {
      isolate();
      try {
        await goto(surfaces[name]!);
        await awaitLoadedAd(tester);
        final bar = find.byType(AppPillTabBar);
        if (bar.evaluate().isEmpty) {
          record(_R.blocked, 'tabs · $name', 'no AppPillTabBar on screen');
          continue;
        }
        final labels = (tester.widget(bar.first) as AppPillTabBar).tabs;
        var ok = true;
        var detail = '';
        for (var i = 1; i < labels.length; i++) {
          // The previous harness tapped a fraction of the bar's width from the
          // left, which in RTL is a different tab entirely — with two tabs it
          // re-tapped the one already selected.
          final target =
              find.descendant(of: bar.first, matching: find.text(labels[i]));
          if (target.evaluate().isEmpty) {
            ok = false;
            detail = 'tab "${labels[i]}" not tappable';
            break;
          }
          await tester.tap(target.first);
          await settle(tester, budget: const Duration(seconds: 6));
          // Scoped to THIS screen. The shell is an IndexedStack that keeps
          // other tabs mounted, so counting banners across the whole tree
          // counts the dashboard's too — which is what made the first run
          // report two.
          final instances = find
              .descendant(
                of: find.byType(ReportsScreen),
                matching: find.byType(QirshAdBanner),
                skipOffstage: false,
              )
              .evaluate()
              .length;
          if (name == 'reports' && instances != 1) {
            ok = false;
            detail = '$instances banners after switching to "${labels[i]}"';
          }
          await shoot('tabs-$name-$i');
        }
        record(ok ? _R.pass : _R.fail, 'tabs · $name',
            detail.isEmpty ? 'one instance across ${labels.length} tabs' : detail);
      } catch (e) {
        record(_R.blocked, 'tabs · $name', '$e');
      }
    }

    // ── Reports: a pushed route suppresses the banner ────────────────────
    isolate();
    try {
      await goto(surfaces['reports']!);
      final before = await awaitLoadedAd(tester);
      final nav = Navigator.of(tester.element(find.byType(AppShell)));
      nav.push(MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Center(child: Text('over')))));
      await settle(tester, budget: const Duration(seconds: 6));
      final covered = isHidden();
      await shoot('reports-route-covered');
      nav.pop();
      await settle(tester, budget: const Duration(seconds: 6));
      record(before != null && covered ? _R.pass : _R.fail,
          'reports · a pushed route suppresses the banner',
          'loaded=${before?.round()} hiddenWhileCovered=$covered');
    } catch (e) {
      record(_R.blocked, 'reports · route suppression', '$e');
    }

    // ── Reports: the export ad journey ──────────────────────────────────
    isolate();
    try {
      await goto(surfaces['reports']!);
      await awaitLoadedAd(tester);
      ReportBannerSuppression.beginJourney();
      await settle(tester, budget: const Duration(seconds: 6));
      final hiddenDuring = isHidden();
      await shoot('reports-journey-active');
      ReportBannerSuppression.endJourney();
      await settle(tester, budget: const Duration(seconds: 8));
      final backAfter = !isHidden();
      record(hiddenDuring ? _R.pass : _R.fail,
          'reports · suppressed for the whole export ad journey',
          'during=$hiddenDuring after=$backAfter');
    } catch (e) {
      record(_R.blocked, 'reports · journey suppression', '$e');
    }

    // ── Reports: the cooldown ends without a rebuild ────────────────────
    isolate();
    try {
      ReportBannerSuppression.cooldown = const Duration(seconds: 4);
      await goto(surfaces['reports']!);
      await awaitLoadedAd(tester);
      ReportBannerSuppression.markAdShown();
      await settle(tester, budget: const Duration(seconds: 6));
      final hidden = isHidden();
      await realDelay(tester, const Duration(seconds: 6));
      BannerAdController.resetThrottleForTest();
      final back =
          await awaitLoadedAd(tester, budget: const Duration(seconds: 20));
      await shoot('reports-cooldown-returned');
      record(hidden && back != null ? _R.pass : _R.fail,
          'reports · the cooldown ends for a screen that never rebuilt',
          'hiddenDuring=$hidden returned=${back?.round()}');
    } catch (e) {
      record(_R.blocked, 'reports · cooldown expiry', '$e');
    } finally {
      ReportBannerSuppression.resetForTest();
    }

    // ── Responsive sizing across a surface resize ───────────────────────
    for (final name in const ['reports', 'goals']) {
      isolate();
      try {
        await goto(surfaces[name]!);
        if (name == 'goals') await scrollToFoot(tester);
        final portrait = await awaitLoadedAd(tester);
        await tester.binding.setSurfaceSize(const Size(932, 430));
        await settle(tester, budget: const Duration(seconds: 8));
        final atRotate = paintedHeight();
        await shoot('resize-$name-landscape');
        BannerAdController.resetThrottleForTest();
        if (name == 'goals') await scrollToFoot(tester);
        final landscape = await awaitLoadedAd(tester);
        await shoot('resize-$name-landscape-loaded');
        await tester.binding.setSurfaceSize(null);
        await settle(tester, budget: const Duration(seconds: 6));
        // The stale creative must be GONE at the moment of the resize; a
        // replacement afterwards is the throttle's business, not this check's.
        // Dropped means NOT PAINTED — which is a null finder or a zero box,
        // because a torn-down banner still renders `SizedBox.shrink()`.
        record((atRotate == null || atRotate == 0) ? _R.pass : _R.fail,
            'resize · $name',
            'portrait=${portrait?.round()} '
            'atResize=${atRotate == null ? "gone" : atRotate.round()} '
            'landscape=${landscape?.round()}');
      } catch (e) {
        await tester.binding.setSurfaceSize(null);
        record(_R.blocked, 'resize · $name', '$e');
      }
    }

    // ── Scroll far away and come back, on a list placement ──────────────
    isolate();
    try {
      await goto(surfaces['goals']!);
      await scrollToFoot(tester);
      final there = await awaitLoadedAd(tester);
      final pos =
          tester.state<ScrollableState>(find.byType(Scrollable).first).position;
      pos.jumpTo(0);
      await settle(tester, budget: const Duration(seconds: 6));
      final gone =
          find.byType(QirshAdBanner, skipOffstage: false).evaluate().isEmpty;
      await scrollToFoot(tester);
      await settle(tester, budget: const Duration(seconds: 8));
      final immediate = paintedHeight();
      await shoot('scroll-return-within-throttle');
      // Nothing loaded means the case never ran. Recording that as a pass is
      // how a gap becomes invisible.
      record(there == null ? _R.blocked : _R.pass,
          'goals · scrolled far away and back',
          'loaded=${there?.round()} unmounted=$gone '
          'immediateReturn=${immediate?.round() ?? "blank, throttled"}');
    } catch (e) {
      record(_R.blocked, 'goals · scroll return', '$e');
    }

    // ── Empty state ─────────────────────────────────────────────────────
    isolate();
    try {
      await _clearSeed(db);
      container.invalidate(goalsListProvider);
      await goto(surfaces['goals']!);
      await settle(tester, budget: const Duration(seconds: 10));
      await scrollToFoot(tester);
      final none =
          find.byType(QirshAdBanner, skipOffstage: false).evaluate().isEmpty;
      await shoot('goals-empty-state');
      record(none ? _R.pass : _R.fail, 'goals · the empty state carries no ad');
    } catch (e) {
      record(_R.blocked, 'goals · empty state', '$e');
    }

    // ── Restore the device ──────────────────────────────────────────────
    await _clearSeed(db);
    for (final key in _flagKeys) {
      await db.customStatement(
          'DELETE FROM remote_feature_flags WHERE key = ?;', [key]);
    }
    await initFeatureFlagService(db, applyRemoteOverrides: false);
    await container.read(saveLanguageUseCaseProvider).call('ar');
    await container.read(themeModeProvider.notifier).set(ThemeMode.system);
    await settle(tester, budget: const Duration(seconds: 5));

    debugPrint('[ADQA] ============== REPORT ==============');
    for (final line in report) {
      debugPrint('[ADQA-REPORT] $line');
    }
    final fails = report.where((l) => l.startsWith('FAIL')).length;
    final blocked = report.where((l) => l.startsWith('BLOCKED')).length;
    debugPrint('[ADQA] total=${report.length} fail=$fails blocked=$blocked');
  }, timeout: const Timeout(Duration(minutes: 60)));
}
