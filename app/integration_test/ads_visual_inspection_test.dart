import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:money_companion/app.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/router/app_router.dart';
import 'package:money_companion/core/security/secure_storage_options.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/ads/banner_ad_controller.dart';
import 'package:money_companion/features/ads/banner_ads_providers.dart';
import 'package:money_companion/features/app/app_shell.dart';
import 'package:money_companion/features/report_ads/report_entitlement.dart';
import 'package:money_companion/main.dart' as app;

/// ADS VISUAL INSPECTION — leaves the app running for a human to look at.
///
/// Two questions are open that no measurement here can answer, and both need
/// eyes on the simulator:
///
///   1. Is the AdMob test creative actually drawn inside the banner, or is the
///      slot empty on the device too? Every screenshot this project has taken
///      shows the label over a blank box — but one early capture DID record a
///      creative, and the native glass navigation bar, also a platform view,
///      photographs fine in the same shots. So either the ad is not rendering
///      or `takeScreenshot` does not composite `AdWidget`. The difference is
///      large: the first is a blocking defect, the second is a limitation of
///      the measuring instrument.
///   2. On Reports and Subscriptions, is a 10pt gap to the tab pills
///      acceptable, and is the hard-edged slot cutting the blue gradient
///      between the header card and the tab bar acceptable?
///
/// ## Why this exists rather than `flutter run`
///
/// A plain launch cannot show a banner. The entitlement gate resolves through
/// Supabase and a debug build without `SUPABASE_URL` has nothing to reach, so
/// every placement stays closed. This harness mounts the REAL app with only
/// entitlement and consent stubbed — every other gate, including the flags, is
/// the shipping one — and then simply waits, so the app stays live on the
/// simulator and answers to touch while it is inspected.
///
/// Test ad units only: a debug build resolves `AdMobBuildConfig` to Google's
/// test publisher ids.

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

/// Wraps the REAL loader so a session can state how many ad requests it made.
///
/// "No fill" and "we asked forty times" look identical from the outside. One
/// surface, one request, and the count is printed with the result.
class _CountingLoader implements BannerAdLoader {
  _CountingLoader() : _inner = AdMobBannerAdLoader();

  final BannerAdLoader _inner;
  static int requests = 0;

  @override
  Object? get loadedAd => _inner.loadedAd;

  @override
  Future<int?> resolveHeight(int widthPx) => _inner.resolveHeight(widthPx);

  @override
  Future<bool> load({
    required String adUnitId,
    required int widthPx,
    required int heightPx,
    VoidCallback? onImpression,
  }) {
    requests++;
    return _inner.load(
      adUnitId: adUnitId,
      widthPx: widthPx,
      heightPx: heightPx,
      onImpression: onImpression,
    );
  }

  @override
  void dispose() => _inner.dispose();
}

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
enum _R { pass, blocked }

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await SecureStorageOptions.storage
        .write(key: 'app_lock_enabled', value: '0');
  });

  testWidgets('ads visual inspection — HOLDS THE APP OPEN', (tester) async {
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
        bannerAdLoaderFactoryProvider.overrideWithValue(_CountingLoader.new),
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

    // Reports first: it carries both open questions at once — the creative and
    // the tab-bar gap.
    await goto('tab:4');
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 3)));
    await settle(tester, budget: const Duration(seconds: 5));

    record(_R.pass, 'READY — the app is live on the simulator');
    debugPrint('[ADQA] ');
    debugPrint('[ADQA] ---------------------------------------------------');
    debugPrint('[ADQA]  Flags are ON for this device only. Test ads only.');
    debugPrint('[ADQA]  The app answers to touch. Look at, in order:');
    debugPrint('[ADQA]   * Reports  (open now) — is the creative drawn, and');
    debugPrint('[ADQA]     how does the slot sit against the tab pills?');
    debugPrint('[ADQA]   * Subscriptions — same header placement');
    debugPrint('[ADQA]   * Goals / Achievements — scroll to the foot');
    debugPrint('[ADQA]   * Home — scroll to the foot');
    debugPrint('[ADQA]  Ad requests so far: ${_CountingLoader.requests}');
    debugPrint('[ADQA]  Holding for 30 minutes. Ctrl-C when you are done.');
    debugPrint('[ADQA] ---------------------------------------------------');

    // Hold. Real time, so the app keeps painting and stays interactive.
    final until = DateTime.now().add(const Duration(minutes: 30));
    while (DateTime.now().isBefore(until)) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 5)));
      await tester.pump(const Duration(milliseconds: 100));
    }

    // The flags are LEFT IN PLACE deliberately — the inspection may continue
    // after this process ends. `_clearSeed` and the flag rows can be removed by
    // re-running the QA walk, which tidies up after itself.
    debugPrint('[ADQA] hold finished; flags left enabled on this device');
  }, timeout: const Timeout(Duration(minutes: 45)));
}
