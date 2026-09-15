import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;
import 'package:money_companion/main.dart' as app;
import 'package:drift/drift.dart' show Variable;
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/card_entity.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/engine/parser/card_network.dart';
import 'package:money_companion/features/app/app_shell.dart';

/// DEMO SEED — fills the local database on this device so the app can be shown
/// to a client with realistic data.
///
/// Writes through the app's OWN repositories, not raw SQL, so balances, budget
/// progress, category rollups and report aggregates are computed exactly as
/// they are in normal use. Seeding the tables directly would produce numbers
/// the app never actually derives.
///
/// LOCAL ONLY. Cloud sync is dark in v1 (exactPush/PullTransportCapability are
/// `unknown`), so nothing here reaches Supabase and nothing in Supabase would
/// reach this device — the demo has to live in Drift.
///
/// Re-runnable: it clears anything it created previously (by marker) before
/// seeding, so running it twice does not double the data.
const _qaEmail = String.fromEnvironment('QA_EMAIL');
const _qaPassword = String.fromEnvironment('QA_PASSWORD');
const _qaUserId = String.fromEnvironment('QA_USER_ID');

/// Every seeded row carries this in a text field so a re-run can remove it.
const _marker = 'demo-seed';

const _sar = 'SAR';

/// (merchant, categoryKey, categoryId, minAmount, maxAmount, weight)
const _catalogue = <(String, String, String, int, int, int)>[
  ('البيك', 'restaurants', '20000000-0000-4000-8000-000000000001', 2500, 8500, 5),
  ('مطعم الطازج', 'restaurants', '20000000-0000-4000-8000-000000000001', 4500, 16000, 3),
  ('بنده', 'groceries', '20000000-0000-4000-8000-000000000002', 8000, 42000, 5),
  ('التميمي', 'groceries', '20000000-0000-4000-8000-000000000002', 12000, 38000, 3),
  ('كريم', 'transport', '20000000-0000-4000-8000-000000000003', 1800, 6500, 4),
  ('أوبر', 'transport', '20000000-0000-4000-8000-000000000003', 2200, 7800, 3),
  ('ساسكو', 'fuel', '20000000-0000-4000-8000-000000000004', 9000, 18000, 3),
  ('فاتورة الكهرباء', 'bills', '20000000-0000-4000-8000-000000000005', 22000, 48000, 1),
  ('STC', 'bills', '20000000-0000-4000-8000-000000000005', 15000, 25000, 1),
  ('نون', 'shopping', '20000000-0000-4000-8000-000000000006', 9500, 65000, 3),
  ('الدانوب', 'shopping', '20000000-0000-4000-8000-000000000006', 7000, 30000, 2),
  ('صيدلية النهدي', 'health', '20000000-0000-4000-8000-000000000007', 3500, 19000, 2),
  ('ستاربكس', 'cafes', '20000000-0000-4000-8000-000000000017', 1900, 5200, 5),
  ('دنكن', 'cafes', '20000000-0000-4000-8000-000000000017', 1500, 3800, 3),
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> settle(WidgetTester tester,
      {Duration budget = const Duration(seconds: 30)}) async {
    final deadline = DateTime.now().add(budget);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 200));
      if (!tester.binding.hasScheduledFrame) break;
    }
  }

  Future<bool> waitFor(WidgetTester tester, Finder f,
      {Duration timeout = const Duration(seconds: 90)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 200));
      if (f.evaluate().isNotEmpty) return true;
    }
    return false;
  }

  testWidgets('seed demo data into the local database', (tester) async {
    if (_qaEmail.isEmpty || _qaPassword.isEmpty || _qaUserId.isEmpty) {
      fail('QA_EMAIL/QA_PASSWORD/QA_USER_ID are required');
    }
    app.main();
    await settle(tester, budget: const Duration(seconds: 60));

    final client = supabase.Supabase.instance.client;
    final owner = await AppSession.instance.readLocalDataOwnerUid();
    if (owner != null && owner != _qaUserId) {
      fail('ABORT — the local database belongs to another account.');
    }
    final res = await client.auth
        .signInWithPassword(email: _qaEmail, password: _qaPassword);
    expect(res.user!.id, _qaUserId);
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
    final accounts = container.read(accountRepositoryProvider);
    final cards = container.read(cardRepositoryProvider);
    final txs = container.read(transactionRepositoryProvider);
    final budgets = container.read(budgetRepositoryProvider);
    final goals = container.read(goalRepositoryProvider);

    // Idempotent: drop what a previous run of THIS seed created. Scoped by the
    // marker so nothing the QA sweep or a real session made is touched.
    for (final sql in [
      "DELETE FROM transactions WHERE raw_message LIKE '%$_marker%'",
      "DELETE FROM goals WHERE name LIKE '%$_marker%'",
      "DELETE FROM cards WHERE nickname LIKE '%$_marker%'",
      "DELETE FROM accounts WHERE name LIKE '%$_marker%'",
    ]) {
      await db.customStatement(sql);
    }
    debugPrint('[SEED] cleared any previous demo rows');

    final now = DateTime.now();
    final rng = Random(42); // deterministic: the same demo every time

    // ---- accounts ----
    final seeded = <String, AccountEntity>{};
    var order = 0;
    for (final spec in <(String, AccountType, int)>[
      ('الحساب الجاري · $_marker', AccountType.bank, 1875000),
      ('محفظة النقد · $_marker', AccountType.cash, 92000),
      ('محفظة STC Pay · $_marker', AccountType.wallet, 143000),
    ]) {
      final account = await accounts.create(AccountEntity(
        id: 'demo-acc-${order + 1}',
        name: spec.$1,
        currency: _sar,
        type: spec.$2,
        isDefault: order == 0,
        sortOrder: order,
        createdAt: now.subtract(const Duration(days: 120)),
        updatedAt: now,
        initialBalanceMoney: Money(spec.$3, _sar),
        currentBalanceMoney: Money(spec.$3, _sar),
      ));
      seeded[spec.$1] = account;
      order++;
    }
    final main = seeded.values.first;
    debugPrint('[SEED] accounts: ${seeded.length}');

    // ---- cards on the bank account ----
    for (final spec in <(String, String, CardNetwork)>[
      ('4471', 'بطاقة مدى · $_marker', CardNetwork.mada),
      ('8823', 'فيزا الراجحي · $_marker', CardNetwork.visa),
    ]) {
      await cards.create(CardEntity(
        id: 'demo-card-${spec.$1}',
        accountId: main.id,
        last4: spec.$1,
        network: spec.$3,
        source: CardSource.manual,
        createdAt: now.subtract(const Duration(days: 110)),
        updatedAt: now,
        nickname: spec.$2,
      ));
    }
    debugPrint('[SEED] cards: 2');

    // ---- transactions across the last 3 months ----
    final weighted = <(String, String, String, int, int)>[
      for (final c in _catalogue)
        for (var i = 0; i < c.$6; i++) (c.$1, c.$2, c.$3, c.$4, c.$5),
    ];
    var made = 0;
    for (var day = 92; day >= 0; day--) {
      // 0–2 purchases a day, denser near the present so charts trend upward.
      final count = rng.nextInt(day < 30 ? 3 : 2);
      for (var i = 0; i < count; i++) {
        final pick = weighted[rng.nextInt(weighted.length)];
        final amount = pick.$4 + rng.nextInt(pick.$5 - pick.$4);
        final at = now.subtract(Duration(days: day, hours: rng.nextInt(12) + 8));
        await txs.saveTransaction(
          transaction: TransactionEntity(
            id: 'demo-tx-$day-$i',
            amountMoney: Money(amount, _sar),
            currency: _sar,
            type: TransactionTypeEntity.payment,
            source: TransactionSourceEntity.card,
            occurredAt: at,
            rawMessage: 'شراء بمبلغ ${(amount / 100).toStringAsFixed(2)} ريال '
                'لدى ${pick.$1} · $_marker',
            parseConfidence: 0.97,
            status: TransactionStatus.confirmed,
            createdAt: at,
            updatedAt: at,
            rawMerchant: pick.$1,
            accountId: main.id,
            cardLast4: rng.nextBool() ? '4471' : '8823',
            direction: TransactionDirectionEntity.debit,
          ),
          categoryKey: pick.$2,
        );
        made++;
      }
      // Salary on the 27th of each month.
      final d = now.subtract(Duration(days: day));
      if (d.day == 27) {
        await txs.saveTransaction(
          transaction: TransactionEntity(
            id: 'demo-tx-salary-${d.month}',
            amountMoney: Money(1850000, _sar),
            currency: _sar,
            type: TransactionTypeEntity.income,
            source: TransactionSourceEntity.bank,
            occurredAt: DateTime(d.year, d.month, d.day, 9),
            rawMessage: 'حوالة راتب 18,500.00 ريال · $_marker',
            parseConfidence: 0.99,
            status: TransactionStatus.confirmed,
            createdAt: d,
            updatedAt: d,
            rawMerchant: 'راتب',
            accountId: main.id,
            direction: TransactionDirectionEntity.credit,
          ),
          categoryKey: 'income',
        );
        made++;
      }
    }
    debugPrint('[SEED] transactions: $made');

    // ---- budgets with visibly different progress ----
    final monthStart = DateTime(now.year, now.month);
    // budgets.category_id has an FK to categories(id) — the LOCAL user-facing
    // table, not remote_categories and not the catalog JSON. Its ids are not
    // the catalog uuids, so resolve each key the same way the app does
    // (drift_category_repository.dart:170) instead of hardcoding.
    Future<String?> categoryIdFor(String key) async {
      final rows = await db.customSelect(
        'SELECT id FROM categories WHERE key = ? LIMIT 1',
        variables: [Variable.withString(key)],
      ).get();
      return rows.isEmpty ? null : rows.first.read<String>('id');
    }

    var b = 0;
    for (final spec in <(String, String, int)>[
      ('restaurants', 'restaurants', 120000),
      ('groceries', 'groceries', 250000),
      ('transport', 'transport', 60000),
    ]) {
      final catId = await categoryIdFor(spec.$1);
      if (catId == null) {
        debugPrint('[SEED] skipped budget: no category "${spec.$1}"');
        continue;
      }
      await budgets.save(BudgetEntity(
        id: 'demo-budget-${++b}',
        categoryId: catId,
        currency: _sar,
        amountMoney: Money(spec.$3, _sar),
        lastNotifiedSpentMoney: Money(0, _sar),
        period: BudgetPeriod.monthly,
        startDate: monthStart,
        isActive: true,
        lastNotifiedPeriodStart: monthStart,
        accountId: main.id,
      ));
    }
    debugPrint('[SEED] budgets: $b');

    // ---- goals: one nearly done, one mid-way ----
    for (final spec in <(String, int, int, int)>[
      ('رحلة الصيف · $_marker', 1500000, 1275000, 60),
      ('آيفون جديد · $_marker', 600000, 240000, 150),
    ]) {
      await goals.save(GoalEntity(
        id: 'demo-goal-${spec.$1.hashCode}',
        name: spec.$1,
        currency: _sar,
        targetMoney: Money(spec.$2, _sar),
        savedMoney: Money(spec.$3, _sar),
        lastNotifiedSavedMoney: Money(0, _sar),
        vaultSkin: 'default_vault',
        status: 'active',
        createdAt: now.subtract(const Duration(days: 90)),
        deadline: now.add(Duration(days: spec.$4)),
        accountId: main.id,
      ));
    }
    debugPrint('[SEED] goals: 2');

    // ---- coupons: OFF by design in v1, enabled locally for the demo ----
    //
    // enable_coupons ships false at 0% rollout. This flips it in the LOCAL
    // feature-flag cache only, and seeds offers whose partner_url points at
    // example.com so a tap during the demo cannot fire a real affiliate click.
    // Nothing here touches the remote flag or a real partner.
    await db.customStatement(
      "UPDATE remote_feature_flags SET value = 'true', rollout_percent = 100, "
      "is_active = 1 WHERE key = 'enable_coupons'",
    );
    await db.customStatement("DELETE FROM remote_coupons WHERE id LIKE 'demo-%'");

    const offers = <(String, String, String, String, String, String, int)>[
      ('نون', 'خصم 15% على الإلكترونيات', 'كوبون خصم على أجهزة مختارة من نون.',
          'NOON15', 'shopping', 'تسوق', 1),
      ('جرير', 'خصم 10% على اللابتوبات', 'عرض محدود على أجهزة اللابتوب.',
          'JARIR10', 'shopping', 'تسوق', 1),
      ('هنقرستيشن', 'توصيل مجاني لأول طلب',
          'توصيل مجاني على طلبك الأول هذا الشهر.', 'HS-FREE', 'restaurants',
          'مطاعم', 0),
      ('ستاربكس', 'مشروب مجاني مع كل ٥ مشروبات',
          'اجمع نقاطك واحصل على مشروبك السادس مجاناً.', 'SBX5', 'cafes',
          'مقاهي', 0),
      ('كريم', 'خصم 20% على ٣ رحلات', 'خصم على رحلاتك داخل المدينة.',
          'CAREEM20', 'transport', 'مواصلات', 0),
      ('بنده', 'خصم 25 ريال على سلة 200', 'وفّر على تسوق البقالة الأسبوعي.',
          'PANDA25', 'groceries', 'بقالة', 0),
    ];
    final nowIso = now.toUtc().toIso8601String();
    final fromIso =
        now.subtract(const Duration(days: 20)).toUtc().toIso8601String();
    final untilIso = now.add(const Duration(days: 45)).toUtc().toIso8601String();
    String q(String v) => "'${v.replaceAll("'", "''")}'";
    var c = 0;
    for (final o in offers) {
      c++;
      const cols = 'id, slug, partner_name, title_ar, description_ar, '
          'redemption_type, code, partner_url, display_category_key, '
          'display_category_label_ar, tags_json, spend_hints_json, '
          'country_codes_json, featured, priority, valid_from, valid_until, '
          'synced_at';
      final vals = [
        q('demo-coupon-$c'),
        q('demo-offer-$c'),
        q(o.$1),
        q(o.$2),
        q(o.$3),
        "'code'",
        q(o.$4),
        q('https://example.com/demo-offer-$c'),
        q(o.$5),
        q(o.$6),
        "'[]'",
        "'[]'",
        "'[]'",
        '${o.$7}',
        '${10 - c}',
        q(fromIso),
        q(untilIso),
        q(nowIso),
      ].join(', ');
      await db.customStatement('INSERT INTO remote_coupons ($cols) VALUES ($vals)');
    }
    final couponCount = (await db
            .customSelect('SELECT COUNT(*) AS n FROM remote_coupons')
            .getSingle())
        .read<int>('n');
    final flagOn = (await db
            .customSelect("SELECT value FROM remote_feature_flags "
                "WHERE key = 'enable_coupons'")
            .getSingle())
        .read<String>('value');
    debugPrint('[SEED] coupons: $couponCount (enable_coupons=$flagOn, '
        'partner urls are example.com)');
    expect(couponCount, greaterThanOrEqualTo(6));
    expect(flagOn, 'true');

    // ---- prove it landed, by reading back through the repositories ----
    final accountCount = (await accounts.getAll()).length;
    final cardCount = (await cards.getAll()).length;
    final budgetCount = (await budgets.getAll()).length;
    final goalCount = (await goals.getAll()).length;
    final txCount = (await db
            .customSelect('SELECT COUNT(*) AS n FROM transactions')
            .getSingle())
        .read<int>('n');
    debugPrint('[SEED] ===== accounts=$accountCount cards=$cardCount '
        'transactions=$txCount budgets=$budgetCount goals=$goalCount =====');

    expect(accountCount, greaterThanOrEqualTo(3));
    expect(cardCount, greaterThanOrEqualTo(2));
    expect(txCount, greaterThan(40));
    expect(budgetCount, greaterThanOrEqualTo(1));
    expect(goalCount, greaterThanOrEqualTo(2));

    // Let the UI rebuild off the seeded data before the app is handed over.
    await settle(tester, budget: const Duration(seconds: 20));
    debugPrint('[SEED] done — open the app on the device');
  }, timeout: const Timeout(Duration(minutes: 20)));
}
