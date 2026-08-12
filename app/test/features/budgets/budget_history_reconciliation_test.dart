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
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/budgets/budgets_providers.dart';
import 'package:money_companion/features/transactions/transactions_providers.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

/// MALI-062n tail — the per-period budget transaction list nets to the same
/// total shown beside it.
void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late DriftTransactionRepository txRepo;
  late DriftAccountRepository accountRepo;
  late DriftCategoryRepository categoryRepo;
  late DriftBudgetRepository budgetRepo;

  final now = DateTime.now();
  final monthStart = DateTime(now.year, now.month, 1);
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
    container.read(transactionsDateRangeProvider.notifier).state =
        transactionsRangeForPreset(TransactionsDatePreset.thisMonth);
    txRepo = DriftTransactionRepository(db);
    accountRepo = DriftAccountRepository(db);
    categoryRepo = DriftCategoryRepository(db);
    budgetRepo = DriftBudgetRepository(db);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<void> put(String id, double amount, TransactionTypeEntity type,
      String accountId, String categoryKey) async {
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
      categoryKey: categoryKey,
    );
  }

  Future<AccountEntity> account(String id, {bool excluded = false}) async {
    return accountRepo.create(AccountEntity(
      id: id,
      name: id,
      currency: 'SAR',
      type: AccountType.bank,
      isDefault: id == 'main',
      sortOrder: 0,
      excludeFromTotals: excluded,
      createdAt: monthStart,
      updatedAt: monthStart,
    ));
  }

  Future<BudgetHistoryEntry> currentGroceriesHistory(String categoryId) async {
    final view = await container.read(budgetsViewProvider.future);
    return view.historyEntries.firstWhere(
      (e) => e.isCurrent && e.progress.budget.categoryId == categoryId,
    );
  }

  test('list signed sum (refund netted) equals the net total', () async {
    await account('main');
    final groceries =
        (await categoryRepo.getAll()).firstWhere((c) => c.key == 'groceries');
    await put('pay', 500, TransactionTypeEntity.payment, 'main', 'groceries');
    await put('ref', 100, TransactionTypeEntity.refund, 'main', 'groceries');
    await budgetRepo.save(BudgetEntity(
      id: 'b',
      categoryId: groceries.id,
      currency: 'SAR',
      amountMoney: Money.parse('1000', 'SAR'),
      period: BudgetPeriod.monthly,
      startDate: monthStart,
      isActive: true,
      lastNotifiedSpentMoney: Money(0, 'SAR'),
      lastNotifiedPeriodStart: DateTime.utc(2000),
    ));

    final entry = await currentGroceriesHistory(groceries.id);
    final signed = entry.transactions
        .fold<double>(0, (s, tx) => s + budgetHistoryRowSigned(tx));
    expect(entry.progress.spent, 400); // 500 − 100
    expect(signed, entry.progress.spent);
    // The refund row is visible so the user can understand the net.
    expect(entry.transactions.map((t) => t.id), containsAll(['pay', 'ref']));
  });

  test('excluded account is absent from both the list and the total', () async {
    await account('main');
    final excluded = await account('excluded', excluded: true);
    final groceries =
        (await categoryRepo.getAll()).firstWhere((c) => c.key == 'groceries');
    await put(
        'main-pay', 500, TransactionTypeEntity.payment, 'main', 'groceries');
    await put('excl-pay', 70, TransactionTypeEntity.payment, excluded.id,
        'groceries');
    await budgetRepo.save(BudgetEntity(
      id: 'b',
      categoryId: groceries.id,
      currency: 'SAR',
      amountMoney: Money.parse('1000', 'SAR'),
      period: BudgetPeriod.monthly,
      startDate: monthStart,
      isActive: true,
      lastNotifiedSpentMoney: Money(0, 'SAR'),
      lastNotifiedPeriodStart: DateTime.utc(2000),
    ));

    final entry = await currentGroceriesHistory(groceries.id);
    final signed = entry.transactions
        .fold<double>(0, (s, tx) => s + budgetHistoryRowSigned(tx));
    expect(
        entry.progress.spent, 500); // excluded account dropped from the total
    expect(signed, 500);
    expect(entry.transactions.map((t) => t.id), isNot(contains('excl-pay')));
  });
}
