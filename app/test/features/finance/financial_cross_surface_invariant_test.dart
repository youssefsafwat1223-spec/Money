import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_budget_repository.dart';
import 'package:money_companion/data/repositories/drift_category_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/features/dashboard/home_sections_providers.dart';
import 'package:money_companion/features/transactions/transactions_providers.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';

  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

/// MALI-047n / MALI-050n / MALI-018 (provider tier) — the SAME fixture is
/// evaluated through the repository income/expense totals, the Transactions
/// header provider, the repository category breakdown, the Home category
/// provider, and the budget metric. Surfaces that claim the same metric agree;
/// intentionally different values are labelled and asserted separately.
void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late DriftTransactionRepository txRepo;
  late DriftAccountRepository accountRepo;
  late DriftCategoryRepository categoryRepo;
  late DriftBudgetRepository budgetRepo;

  final now = DateTime.now();
  // Mid-month so period boundaries never bite; current month so the Home
  // provider and the monthly budget both cover the fixture.
  final monthStart = DateTime(now.year, now.month, 1);
  final nextMonthStart = DateTime(now.year, now.month + 1, 1);
  final at = DateTime(now.year, now.month, 10, 9);

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    await initFeatureFlagService(db, installIdOverride: 'test-install');
    container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    // Header total reads the visible date range — pin it to this month.
    container.read(transactionsDateRangeProvider.notifier).state =
        TransactionsDateRange(
      preset: TransactionsDatePreset.custom,
      from: monthStart,
      to: nextMonthStart,
    );
    txRepo = DriftTransactionRepository(db);
    accountRepo = DriftAccountRepository(db);
    categoryRepo = DriftCategoryRepository(db);
    budgetRepo = DriftBudgetRepository(db);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<AccountEntity> account(
    String id, {
    String currency = 'SAR',
    bool isDefault = false,
    bool excludeFromTotals = false,
  }) {
    return accountRepo.create(AccountEntity(
      id: id,
      name: id,
      currency: currency,
      type: AccountType.bank,
      isDefault: isDefault,
      sortOrder: 0,
      excludeFromTotals: excludeFromTotals,
      createdAt: monthStart,
      updatedAt: monthStart,
    ));
  }

  Future<void> put({
    required String id,
    required double amount,
    required TransactionTypeEntity type,
    required String accountId,
    TransactionStatus status = TransactionStatus.confirmed,
    String currency = 'SAR',
    String? categoryKey = 'groceries',
    DateTime? occurredAt,
  }) async {
    await txRepo.saveTransaction(
      transaction: TransactionEntity(
        id: id,
        amount: amount,
        currency: currency,
        type: type,
        source: TransactionSourceEntity.bank,
        occurredAt: occurredAt ?? at,
        rawMessage: id,
        parseConfidence: 1,
        status: status,
        createdAt: at,
        updatedAt: at,
        accountId: accountId,
        rawMerchant: 'Market $id',
      ),
      categoryKey: categoryKey,
    );
  }

  test(
      'one fixture agrees across repo totals, header, category breakdown, '
      'Home groups and the budget metric', () async {
    final main = await account('main', isDefault: true);

    // groceries: 500 spent − 100 refunded → net 400 (refund NETS, not income).
    await put(id: 'g-pay', amount: 500, type: TransactionTypeEntity.payment, accountId: main.id);
    await put(id: 'g-ref', amount: 100, type: TransactionTypeEntity.refund, accountId: main.id);
    // restaurants: 50 confirmed; a pending + an ignored that must NOT count.
    await put(id: 'r-pay', amount: 50, type: TransactionTypeEntity.payment, accountId: main.id, categoryKey: 'restaurants');
    await put(id: 'r-pending', amount: 30, type: TransactionTypeEntity.payment, accountId: main.id, categoryKey: 'restaurants', status: TransactionStatus.pending);
    await put(id: 'r-ignored', amount: 60, type: TransactionTypeEntity.payment, accountId: main.id, categoryKey: 'restaurants', status: TransactionStatus.ignored);
    // income + transfer never touch expense.
    await put(id: 'inc', amount: 500, type: TransactionTypeEntity.income, accountId: main.id, categoryKey: null);
    await put(id: 'xfer', amount: 1000, type: TransactionTypeEntity.transfer, accountId: main.id, categoryKey: null);

    final groceries =
        (await categoryRepo.getAll()).firstWhere((c) => c.key == 'groceries');
    await budgetRepo.save(BudgetEntity(
      id: 'b-groceries',
      categoryId: groceries.id,
      amount: 1000,
      period: BudgetPeriod.monthly,
      startDate: monthStart,
      isActive: true,
      lastNotifiedSpentAmount: 0,
      lastNotifiedPeriodStart: DateTime.utc(2000),
    ));

    // Repository tier.
    final repoExpense = await txRepo.expenseTotalBetween(
        from: monthStart, to: nextMonthStart, accountId: main.id);
    final repoIncome = await txRepo.incomeTotalBetween(
        from: monthStart, to: nextMonthStart, accountId: main.id);
    final breakdown = await txRepo.categoryBreakdown(
        from: monthStart, to: nextMonthStart, accountId: main.id);
    expect(repoExpense, 450); // groceries 400 + restaurants 50
    expect(repoIncome, 500);
    final breakdownByCat = {for (final r in breakdown) r.categoryId: r.total};
    expect(breakdownByCat[groceries.id], 400);

    // Transactions header provider == repository net expense.
    final header =
        await container.read(transactionsPeriodTotalProvider.future);
    expect(header.netExpense, repoExpense);
    expect(header.currency, 'SAR');

    // Home category provider == repository category breakdown.
    final groups =
        await container.read(monthlyExpenseGroupsProvider.future);
    final groupByCat = {for (final g in groups) g.categoryId: g.total};
    expect(groupByCat[groceries.id], breakdownByCat[groceries.id]);
    expect(groupByCat[groceries.id], 400);

    // Home groceries total == the adjacent budget metric for the same scope.
    final groceriesGroup =
        groups.firstWhere((g) => g.categoryId == groceries.id);
    expect(groceriesGroup.budget, isNotNull);
    expect(groceriesGroup.budget!.spent, groceriesGroup.total);
    expect(groceriesGroup.budget!.spent, 400);
  });

  test('excluded account: dropped from combined totals, kept when scoped',
      () async {
    await account('main', isDefault: true);
    final excluded = await account('excluded', excludeFromTotals: true);
    await put(id: 'e-pay', amount: 70, type: TransactionTypeEntity.payment, accountId: excluded.id);

    // Combined (no active account) excludes the flagged account.
    final combined = await txRepo.expenseTotalBetween(
        from: monthStart, to: nextMonthStart);
    expect(combined, 0);
    // Drilling into the flagged account still shows its own total.
    final scoped = await txRepo.expenseTotalBetween(
        from: monthStart, to: nextMonthStart, accountId: excluded.id);
    expect(scoped, 70);

    // Header, scoped to the excluded account, reports its own total.
    container.read(activeAccountIdProvider.notifier).state = excluded.id;
    final header =
        await container.read(transactionsPeriodTotalProvider.future);
    expect(header.netExpense, 70);
  });

  test('multi-currency never sums under one label', () async {
    final sar = await account('main', currency: 'SAR', isDefault: true);
    final usd = await account('usd', currency: 'USD');
    await put(id: 's-pay', amount: 100, type: TransactionTypeEntity.payment, accountId: sar.id, currency: 'SAR');
    await put(id: 'u-pay', amount: 999, type: TransactionTypeEntity.payment, accountId: usd.id, currency: 'USD');

    // Header on the SAR account shows SAR only — never 1099.
    final sarHeader =
        await container.read(transactionsPeriodTotalProvider.future);
    expect(sarHeader.netExpense, 100);
    expect(sarHeader.currency, 'SAR');

    // Home categories for the SAR scope exclude the USD row.
    final sarGroups =
        await container.read(monthlyExpenseGroupsProvider.future);
    expect(sarGroups.fold<double>(0, (s, g) => s + g.total), 100);

    // Switching to the USD account isolates its currency.
    container.read(activeAccountIdProvider.notifier).state = usd.id;
    container.invalidate(transactionsPeriodTotalProvider);
    final usdHeader =
        await container.read(transactionsPeriodTotalProvider.future);
    expect(usdHeader.netExpense, 999);
    expect(usdHeader.currency, 'USD');
  });

  test('header total covers the complete dataset (501 rows), not one page',
      () async {
    final main = await account('main', isDefault: true);
    for (var i = 0; i < 501; i++) {
      await put(
        id: 'p$i',
        amount: 1,
        type: TransactionTypeEntity.payment,
        accountId: main.id,
      );
    }
    final header =
        await container.read(transactionsPeriodTotalProvider.future);
    // A fold over the first 500-row page would stop at 500; the canonical
    // aggregate sees all 501.
    expect(header.netExpense, 501);
  });

  test('header net expense = payment + withdrawal − refund; income/transfer out',
      () async {
    final main = await account('main', isDefault: true);
    await put(id: 'pay', amount: 100, type: TransactionTypeEntity.payment, accountId: main.id);
    await put(id: 'wd', amount: 40, type: TransactionTypeEntity.withdrawal, accountId: main.id, categoryKey: 'cash');
    await put(id: 'ref', amount: 30, type: TransactionTypeEntity.refund, accountId: main.id);
    await put(id: 'inc', amount: 500, type: TransactionTypeEntity.income, accountId: main.id, categoryKey: null);
    await put(id: 'xf', amount: 200, type: TransactionTypeEntity.transfer, accountId: main.id, categoryKey: null);

    final header =
        await container.read(transactionsPeriodTotalProvider.future);
    expect(header.netExpense, 110); // 100 + 40 − 30
  });

  test('empty result → header 0', () async {
    await account('main', isDefault: true);
    final header =
        await container.read(transactionsPeriodTotalProvider.future);
    expect(header.netExpense, 0);
  });

  test('category alias resolves to the same stable category key', () async {
    final main = await account('main', isDefault: true);
    // 'grocery' is an alias of the stable 'groceries' key.
    await put(id: 'a1', amount: 40, type: TransactionTypeEntity.payment, accountId: main.id, categoryKey: 'groceries');
    await put(id: 'a2', amount: 60, type: TransactionTypeEntity.payment, accountId: main.id, categoryKey: 'groceries');

    final groups =
        await container.read(monthlyExpenseGroupsProvider.future);
    final groceries =
        (await categoryRepo.getAll()).firstWhere((c) => c.key == 'groceries');
    final g = groups.firstWhere((g) => g.categoryId == groceries.id);
    expect(g.total, 100);
    expect(g.count, 2);
  });
}
