import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_budget_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/finance/budget_period.dart';
import 'package:money_companion/features/budgets/budgets_providers.dart';
import 'package:money_companion/features/transactions/transactions_providers.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

/// MALI-049n / 028 — the canonical budget-period resolver + consumption that the
/// dashboard ring, budget detail, report snapshot and alerts all share.
void main() {
  BudgetEntity budget(BudgetPeriod period) => BudgetEntity(
        id: 'b',
        categoryId: BudgetEntity.allExpensesCategoryId,
        currency: 'SAR',
        amountMoney: Money.parse('1000', 'SAR'),
        period: period,
        startDate: DateTime(2026, 1, 1),
        isActive: true,
        lastNotifiedSpentMoney: Money(0, 'SAR'),
        lastNotifiedPeriodStart: DateTime.utc(2000),
      );

  group('resolveBudgetPeriod is genuine half-open (no epsilon end)', () {
    test('monthly → [1st, 1st-of-next-month)', () {
      final r = resolveBudgetPeriod(
          budget(BudgetPeriod.monthly), DateTime(2026, 2, 15, 13));
      expect(r.from, DateTime(2026, 2, 1));
      expect(r.to, DateTime(2026, 3, 1)); // exclusive, not Feb 28 23:59:59
    });

    test('yearly → [Jan 1, next Jan 1)', () {
      final r = resolveBudgetPeriod(
          budget(BudgetPeriod.yearly), DateTime(2026, 6, 1));
      expect(r.from, DateTime(2026, 1, 1));
      expect(r.to, DateTime(2027, 1, 1));
    });

    test('weekly → Saturday-anchored, exactly 7 days', () {
      final r = resolveBudgetPeriod(
          budget(BudgetPeriod.weekly), DateTime(2026, 2, 15, 9));
      expect(r.from.weekday, DateTime.saturday);
      expect(r.to.difference(r.from).inDays, 7);
      expect(r.to.weekday, DateTime.saturday);
    });

    test('daily → exactly 1 day', () {
      final r = resolveBudgetPeriod(
          budget(BudgetPeriod.daily), DateTime(2026, 2, 15, 9));
      expect(r.from, DateTime(2026, 2, 15));
      expect(r.to, DateTime(2026, 2, 16));
    });

    test('leap day: Feb of a leap year ends on Mar 1', () {
      final r = resolveBudgetPeriod(
          budget(BudgetPeriod.monthly), DateTime(2028, 2, 29, 10));
      expect(r.from, DateTime(2028, 2, 1));
      expect(r.to, DateTime(2028, 3, 1));
    });
  });

  group('provider-tier consumption', () {
    late AppDatabase db;
    late ProviderContainer container;
    late DriftTransactionRepository txRepo;
    late DriftAccountRepository accountRepo;
    late DriftBudgetRepository budgetRepo;

    final now = DateTime.now();
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
      txRepo = DriftTransactionRepository(db);
      accountRepo = DriftAccountRepository(db);
      budgetRepo = DriftBudgetRepository(db);
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    Future<void> put(String id, double amount, TransactionTypeEntity type,
        String accountId) async {
      await txRepo.saveTransaction(
        transaction: TransactionEntity(
          id: id,
          amountMoney: Money.fromLegacyReal(amount, 'SAR'),
          currency: 'SAR',
          type: type,
          source: TransactionSourceEntity.bank,
          occurredAt: at,
          rawMessage: id,
          parseConfidence: 1,
          status: TransactionStatus.confirmed,
          createdAt: at,
          updatedAt: at,
          accountId: accountId,
          rawMerchant: 'M',
        ),
        categoryKey: 'groceries',
      );
    }

    test(
        'budget detail == canonical repo consumption (refund netted) and is '
        'filter-invariant', () async {
      final acc = await accountRepo.create(AccountEntity(
        id: 'main',
        name: 'main',
        currency: 'SAR',
        type: AccountType.bank,
        isDefault: true,
        sortOrder: 0,
        createdAt: monthStart,
        updatedAt: monthStart,
      ));
      await put('pay', 500, TransactionTypeEntity.payment, acc.id);
      await put('ref', 100, TransactionTypeEntity.refund, acc.id);
      await budgetRepo.save(budget(BudgetPeriod.monthly));

      final repoSpent = await txRepo.expenseTotalBetween(
          from: monthStart,
          to: nextMonthStart,
          currency: 'SAR',
          accountId: acc.id);
      expect(repoSpent, Money(40000, 'SAR')); // 500 − 100 refund

      final view = await container.read(budgetsViewProvider.future);
      final entry = view.snapshot.entries.single;
      expect(entry.spent, Money(40000, 'SAR'));
      expect(entry.spent, repoSpent);
      // Genuine half-open period on the entry, no epsilon end.
      expect(entry.periodStart, monthStart);
      expect(entry.periodEnd, nextMonthStart);

      // Changing ONLY the transactions date filter must not move the monthly
      // budget's consumption (it derives from the budget's own period).
      container.read(transactionsDateRangeProvider.notifier).state =
          transactionsRangeForPreset(TransactionsDatePreset.last90Days);
      final refiltered = await container.read(budgetsViewProvider.future);
      expect(refiltered.snapshot.entries.single.spent, Money(40000, 'SAR'));
    });

    test('excluded account dropped from an all-expenses budget', () async {
      await accountRepo.create(AccountEntity(
        id: 'main',
        name: 'main',
        currency: 'SAR',
        type: AccountType.bank,
        isDefault: true,
        sortOrder: 0,
        createdAt: monthStart,
        updatedAt: monthStart,
      ));
      final excluded = await accountRepo.create(AccountEntity(
        id: 'excluded',
        name: 'x',
        currency: 'SAR',
        type: AccountType.bank,
        isDefault: false,
        sortOrder: 1,
        excludeFromTotals: true,
        createdAt: monthStart,
        updatedAt: monthStart,
      ));
      await put('pay', 100, TransactionTypeEntity.payment, 'main');
      await put('excl', 70, TransactionTypeEntity.payment, excluded.id);
      await budgetRepo.save(budget(BudgetPeriod.monthly));

      final view = await container.read(budgetsViewProvider.future);
      // All-accounts scope excludes the flagged account: 100, not 170.
      expect(view.snapshot.entries.single.spent, Money(10000, 'SAR'));
    });
  });
}
