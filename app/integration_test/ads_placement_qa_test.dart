import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/security/secure_storage_options.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/achievements/achievements_screen.dart';
import 'package:money_companion/features/ads/ad_placement.dart';
import 'package:money_companion/features/ads/banner_ads_providers.dart';
import 'package:money_companion/features/ads/qirsh_ad_banner.dart';
import 'package:money_companion/features/app/app_shell.dart';
import 'package:money_companion/features/common/app_pill_tab_bar.dart';
import 'package:money_companion/features/dashboard/dashboard_screen.dart';
import 'package:money_companion/features/goals/goals_screen.dart';
import 'package:money_companion/features/reports/reports_screen.dart';
import 'package:money_companion/features/subscriptions/subscriptions_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';
import 'package:money_companion/main.dart' as app;

/// AD PLACEMENT QA — the five new banner surfaces, rendered on a real device.
///
/// ## What this walk is for, and what it is not
///
/// The GATE logic is already covered: 13 mechanics tests and 24 screen tests
/// assert who may see a banner and when. What no widget test can answer is how
/// the thing LOOKS on a device — whether it crowds the pinned tab bar on
/// Subscriptions and Reports, whether the floating nav bar covers it, how it
/// reads right-to-left, and what rotation does to it. Those are the questions
/// here.
///
/// ## Why it renders the screens directly instead of driving the app
///
/// First attempt drove the real app. It got as far as turning the flags on and
/// then stopped at the entitlement gate: `ReportEntitlementResolver` reaches
/// Supabase, and a debug build without `SUPABASE_URL`/`SUPABASE_ANON_KEY` has
/// no instance to reach. Supplying those, and the QA account behind them, is an
/// owner action — so the gate cannot open on this device on my own.
///
/// Rather than report "no banner anywhere" and call it QA, this bootstraps the
/// real app to get a real, seeded, decrypted database, then renders each screen
/// against it with the ENTITLEMENT GATE OVERRIDDEN. Every other gate — the
/// flags, the build config, the visual gates, the loader — is the shipping one.
///
/// **This does not verify the entitlement or consent gates.** They are unit
/// tested, and they still need a signed-in device pass before release. Said
/// here so the screenshots are not mistaken for wider coverage than they carry.
///
/// ## Ads: TEST UNITS ONLY
///
/// A debug build resolves `AdMobBuildConfig` to Google's test publisher ids
/// (`isTestMode` is `kDebugMode || kProfileMode`). Nothing here picks an ad
/// unit; the build does, and an architecture guard already forbids a production
/// id in source.
///
/// ## Flags: LOCAL ONLY
///
/// `_defaults` is untouched. This writes rows into THIS DEVICE's
/// `remote_feature_flags` table — the same local cache a catalog sync fills —
/// and deletes them again at the end. No Remote Config, no other device.

const _flagKeys = <String>[
  'enable_banner_ads',
  'enable_banner_dashboard',
  'enable_banner_goals',
  'enable_banner_subscriptions',
  'enable_banner_reports',
  'enable_banner_achievements',
  'enable_banner_transactions_list',
];

/// Every seeded row carries this so the teardown can find it again, and so a
/// re-run cannot double the data.
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

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await SecureStorageOptions.storage
        .write(key: 'app_lock_enabled', value: '0');
  });

  testWidgets('ad placement QA walk', (tester) async {
    WidgetController.hitTestWarningShouldBeFatal = false;
    final report = <String>[];
    void note(String s) {
      debugPrint('[ADQA] $s');
      report.add(s);
    }

    Future<void> settle(WidgetTester t,
        {Duration budget = const Duration(seconds: 10)}) async {
      final deadline = DateTime.now().add(budget);
      while (DateTime.now().isBefore(deadline)) {
        await t.pump(const Duration(milliseconds: 100));
        if (!t.binding.hasScheduledFrame) break;
      }
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

    // ── Bootstrap the real app, purely to get a real database ─────────────
    note('launching');
    app.main();
    await settle(tester, budget: const Duration(seconds: 60));
    if (!await waitFor(tester, find.byType(AppShell))) {
      fail('the shell never mounted — this device has no usable local state.');
    }
    final bootContainer =
        ProviderScope.containerOf(tester.element(find.byType(AppShell)));
    final db = bootContainer.read(appDatabaseProvider);

    final now = DateTime.now().toUtc().toIso8601String();
    for (final key in _flagKeys) {
      await db.customStatement(
        'INSERT OR REPLACE INTO remote_feature_flags'
        '(key, value_type, value, rollout_percent, target_countries,'
        ' is_active, synced_at) VALUES (?, ?, ?, ?, ?, ?, ?);',
        [key, 'boolean', 'true', 100, '[]', 1, now],
      );
    }
    await initFeatureFlagService(db, applyRemoteOverrides: false);
    note('flags on (local, this device only): ${_flagKeys.length} keys');

    // ── Seed just enough data to reach the populated states ───────────────
    //
    // The first run found the device database empty, so every screen showed
    // its empty state and every banner was correctly SUPPRESSED. That proves
    // the suppression rules and nothing else. Real QA needs the populated
    // screens, so this writes a small marked dataset through the app's own
    // repositories — the same path the demo seed uses, minus its sign-in,
    // which is only there for the walk that needs a session.
    //
    // Everything carries `$_seedMark` and is deleted at the end.
    const sar = 'SAR';
    final t0 = DateTime.now();
    final accounts = bootContainer.read(accountRepositoryProvider);
    final txs = bootContainer.read(transactionRepositoryProvider);
    final goals = bootContainer.read(goalRepositoryProvider);
    final bills = bootContainer.read(billRepositoryProvider);

    await _clearSeed(db);
    final account = await accounts.create(AccountEntity(
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
    ));

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
      await txs.saveTransaction(
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

    // THREE goals — the rule needs at least two before a banner is allowed.
    for (final g in const <(String, int, int)>[
      ('رحلة الصيف', 1500000, 1275000),
      ('آيفون جديد', 600000, 240000),
      ('صندوق طوارئ', 2000000, 350000),
    ]) {
      await goals.save(GoalEntity(
        id: 'adqa-goal-${g.$1.hashCode}',
        name: '${g.$1} · $_seedMark',
        currency: sar,
        targetMoney: Money(g.$2, sar),
        savedMoney: Money(g.$3, sar),
        lastNotifiedSavedMoney: Money(0, sar),
        vaultSkin: 'summer_trip',
        status: 'active',
        createdAt: t0.subtract(const Duration(days: 40)),
        // `goalsListProvider` filters by the selected/default account, so a
        // goal with a null accountId is invisible the moment any account
        // exists. The first run seeded three goals and the screen still showed
        // its empty state because of exactly this.
        accountId: account.id,
      ));
    }

    for (final b in const <(String, int, BillType)>[
      ('Netflix', 5600, BillType.subscription),
      ('STC', 22000, BillType.subscription),
      ('قسط السيارة', 150000, BillType.installment),
    ]) {
      await bills.save(BillEntity(
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
    note('seeded: 28 transactions, 3 goals, 3 bills, 1 account');

    // ── Render each screen against that database ──────────────────────────
    Widget host(Widget screen, {required String lang, required bool dark}) {
      return ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          // The ONE gate overridden, and the reason is in the header comment.
          for (final p in AdPlacement.values)
            bannerEligibilityProvider(p).overrideWith((ref) async => true),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          locale: Locale(lang),
          supportedLocales: AppL10n.supportedLocales,
          localizationsDelegates: const [
            ...AppL10n.localizationsDelegates,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: dark ? AppTheme.dark : AppTheme.light,
          home: screen,
        ),
      );
    }

    final screens = <String, Widget Function()>{
      'dashboard': DashboardScreen.new,
      'goals': GoalsScreen.new,
      'subscriptions': SubscriptionsScreen.new,
      'reports': ReportsScreen.new,
      'achievements': AchievementsScreen.new,
    };

    /// Drives the page's own scroll position to the bottom.
    ///
    /// NOT `tester.drag`. A drag has to land on the right scrollable and the
    /// gesture has to be absorbed by it, and on the dashboard it was not: the
    /// first two runs reported the dashboard banner ABSENT in all four
    /// combinations, and a probe driving the position directly found it mounts
    /// perfectly well. That was a harness defect reported as a product one.
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

    /// What the banner is doing: painted with a height, mounted but not
    /// painted, or genuinely not in the tree.
    ///
    /// `find.byType` skips offstage elements by DEFAULT, and that default cost
    /// a whole round of false findings: a header banner scrolled out of view
    /// reported ABSENT here, which was read as "disposed" and nearly recorded
    /// as a product defect. With `skipOffstage: false` it is plainly still
    /// there, holding its ad. The distinction is the finding, so it is measured
    /// rather than inferred.
    String bannerState() {
      final painted = find.byType(QirshAdBanner);
      if (painted.evaluate().isNotEmpty) {
        return 'h${tester.getSize(painted.first).height.round()}';
      }
      final any = find.byType(QirshAdBanner, skipOffstage: false);
      return any.evaluate().isEmpty ? 'NOT-IN-TREE' : 'OFFSTAGE';
    }

    /// The two accidental-click distances a screenshot alone cannot answer:
    /// how close the banner's bottom edge is to the tab bar below/above it,
    /// and how much room is left beneath it for the floating nav bar.
    String geometry() {
      final b = find.byType(QirshAdBanner);
      if (b.evaluate().isEmpty) return '';
      final banner = tester.getRect(b.first);
      final parts = <String>['top=${banner.top.round()}'];
      final tabs = find.byType(TabBar);
      if (tabs.evaluate().isNotEmpty) {
        final tab = tester.getRect(tabs.first);
        final gap = tab.top - banner.bottom;
        parts.add('tabGap=${gap.round()}');
      }
      final h = tester.view.physicalSize.height / tester.view.devicePixelRatio;
      parts.add('below=${(h - banner.bottom).round()}');
      return parts.join(' ');
    }

    Future<void> record(String tag) async {
      await settle(tester, budget: const Duration(seconds: 4));
      note('$tag :: banner=${bannerState()} ${geometry()}');
      await binding.takeScreenshot('adqa-$tag');
    }

    for (final lang in const ['ar', 'en']) {
      for (final dark in const [false, true]) {
        final combo = '$lang-${dark ? 'dark' : 'light'}';
        note('=== $combo ===');
        for (final entry in screens.entries) {
          try {
            await tester.pumpWidget(
                host(entry.value(), lang: lang, dark: dark));
            await settle(tester, budget: const Duration(seconds: 15));
            await record('$combo-${entry.key}-top');
            await scrollToFoot(tester);
            await record('$combo-${entry.key}-foot');

            // Tab switching, where there are tabs.
            //
            // These screens use `AppPillTabBar`, not Material's `TabBar`, so
            // the first version of this looked for `Tab` widgets, found none,
            // and silently skipped tab switching in every combination. Tapping
            // by fraction of the bar's own rect works for both capsule states
            // and in both text directions.
            final bar = find.byType(AppPillTabBar);
            if (bar.evaluate().isNotEmpty) {
              final rect = tester.getRect(bar.first);
              final n = (tester.widget(bar.first) as AppPillTabBar).tabs.length;
              for (var i = 1; i < n; i++) {
                await tester.tapAt(Offset(
                    rect.left + rect.width * (i + 0.5) / n, rect.center.dy));
                await settle(tester, budget: const Duration(seconds: 6));
                await record('$combo-${entry.key}-tab$i');
              }
            }
          } catch (e) {
            note('FAIL $combo-${entry.key}: $e');
          }
        }
      }
    }

    // ── Rotation, on the two header placements ────────────────────────────
    // The header banner sits between a header card and a pinned tab bar, which
    // is the layout most likely to crowd when the vertical budget halves.
    for (final name in const ['subscriptions', 'reports']) {
      try {
        await tester.pumpWidget(
            host(screens[name]!(), lang: 'ar', dark: true));
        await settle(tester, budget: const Duration(seconds: 12));
        await tester.binding.setSurfaceSize(const Size(932, 430));
        await settle(tester, budget: const Duration(seconds: 6));
        await record('landscape-$name');
        await tester.binding.setSurfaceSize(null);
        await settle(tester, budget: const Duration(seconds: 5));
        await record('back-to-portrait-$name');
      } catch (e) {
        await tester.binding.setSurfaceSize(null);
        note('FAIL rotation-$name: $e');
      }
    }

    // ── Return after a pushed route ───────────────────────────────────────
    // The banner is torn down under a full-screen route. What matters is the
    // way back: a collapsed slot is expected inside the 30-second throttle
    // window, and it must leave neither a gap nor a stale frame.
    try {
      await tester.pumpWidget(host(screens['goals']!(), lang: 'ar', dark: true));
      await settle(tester, budget: const Duration(seconds: 12));
      await scrollToFoot(tester);
      await record('route-before');
      final nav = Navigator.of(tester.element(find.byType(GoalsScreen)));
      nav.push(MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Center(child: Text('over')))));
      await settle(tester, budget: const Duration(seconds: 6));
      await record('route-covered');
      nav.pop();
      await settle(tester, budget: const Duration(seconds: 6));
      await scrollToFoot(tester);
      await record('route-back');
    } catch (e) {
      note('FAIL route-return: $e');
    }

    // ── Put the device back the way it was ────────────────────────────────
    for (final key in _flagKeys) {
      await db.customStatement(
          'DELETE FROM remote_feature_flags WHERE key = ?;', [key]);
    }
    await initFeatureFlagService(db, applyRemoteOverrides: false);
    await _clearSeed(db);
    note('flags removed, seed removed, device restored');

    note('--- REPORT ---');
    for (final line in report) {
      debugPrint('[ADQA-REPORT] $line');
    }
  }, timeout: const Timeout(Duration(minutes: 45)));
}
