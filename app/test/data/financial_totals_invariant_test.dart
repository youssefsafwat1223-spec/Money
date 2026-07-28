import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/reporting/report_snapshot_builder.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_budget_repository.dart';
import 'package:money_companion/data/repositories/drift_category_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/reporting/report_request.dart';
import 'package:money_companion/domain/usecases/budget_progress_usecase.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';

  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

void main() {
  late AppDatabase db;
  late DriftTransactionRepository transactions;
  late DriftAccountRepository accounts;
  late DriftCategoryRepository categories;
  late DriftBudgetRepository budgets;

  final occurredAt = DateTime.utc(2026, 7, 15, 9);
  final from = DateTime.utc(2026, 7);
  final to = DateTime.utc(2026, 8);
  final now = DateTime(2026, 7, 15, 12);

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    transactions = DriftTransactionRepository(db);
    accounts = DriftAccountRepository(db);
    categories = DriftCategoryRepository(db);
    budgets = DriftBudgetRepository(db);
  });

  tearDown(() async => db.close());

  Future<void> put({
    required String id,
    required double amount,
    required TransactionTypeEntity type,
    required TransactionStatus status,
    String? accountId,
    String? categoryKey = 'groceries',
    String? merchant = 'Canonical Market',
  }) async {
    await transactions.saveTransaction(
      transaction: TransactionEntity(
        id: id,
        amount: amount,
        currency: 'SAR',
        type: type,
        source: TransactionSourceEntity.bank,
        occurredAt: occurredAt,
        rawMessage: id,
        parseConfidence: 1,
        status: status,
        createdAt: occurredAt,
        updatedAt: occurredAt,
        accountId: accountId,
        rawMerchant: merchant,
      ),
      categoryKey: categoryKey,
    );
  }

  test('canonical totals stay equal across headline, views, budget, and report',
      () async {
    // saveTransaction assigns the seeded default account, so clear it explicitly
    // to cover legacy/unassigned rows.
    await put(
      id: 'unassigned-expense',
      amount: 30,
      type: TransactionTypeEntity.payment,
      status: TransactionStatus.confirmed,
    );
    await db.customStatement(
      "UPDATE transactions SET account_id = NULL "
      "WHERE id = 'unassigned-expense';",
    );

    final normalAccount = await accounts.create(
      AccountEntity(
        id: 'normal-account',
        name: 'Included',
        currency: 'SAR',
        type: AccountType.bank,
        isDefault: true,
        sortOrder: 0,
        createdAt: occurredAt,
        updatedAt: occurredAt,
      ),
    );
    final excludedAccount = await accounts.create(
      AccountEntity(
        id: 'excluded-account',
        name: 'Excluded',
        currency: 'SAR',
        type: AccountType.bank,
        isDefault: false,
        sortOrder: 1,
        excludeFromTotals: true,
        createdAt: occurredAt,
        updatedAt: occurredAt,
      ),
    );

    await put(
      id: 'expense',
      amount: 120,
      type: TransactionTypeEntity.payment,
      status: TransactionStatus.confirmed,
      accountId: normalAccount.id,
    );
    await put(
      id: 'refund',
      amount: 20,
      type: TransactionTypeEntity.refund,
      status: TransactionStatus.confirmed,
      accountId: normalAccount.id,
    );
    await put(
      id: 'income',
      amount: 500,
      type: TransactionTypeEntity.income,
      status: TransactionStatus.confirmed,
      accountId: normalAccount.id,
      categoryKey: null,
      merchant: null,
    );
    await put(
      id: 'transfer',
      amount: 1000,
      type: TransactionTypeEntity.transfer,
      status: TransactionStatus.confirmed,
      accountId: normalAccount.id,
      categoryKey: null,
      merchant: null,
    );
    await put(
      id: 'pending-expense',
      amount: 50,
      type: TransactionTypeEntity.payment,
      status: TransactionStatus.pending,
      accountId: normalAccount.id,
    );
    await put(
      id: 'ignored-expense',
      amount: 60,
      type: TransactionTypeEntity.payment,
      status: TransactionStatus.ignored,
      accountId: normalAccount.id,
    );
    await put(
      id: 'pending-income',
      amount: 80,
      type: TransactionTypeEntity.income,
      status: TransactionStatus.pending,
      accountId: normalAccount.id,
      categoryKey: null,
      merchant: null,
    );
    await put(
      id: 'ignored-income',
      amount: 90,
      type: TransactionTypeEntity.income,
      status: TransactionStatus.ignored,
      accountId: normalAccount.id,
      categoryKey: null,
      merchant: null,
    );
    await put(
      id: 'excluded-expense',
      amount: 70,
      type: TransactionTypeEntity.payment,
      status: TransactionStatus.confirmed,
      accountId: excludedAccount.id,
    );
    await put(
      id: 'excluded-income',
      amount: 900,
      type: TransactionTypeEntity.income,
      status: TransactionStatus.confirmed,
      accountId: excludedAccount.id,
      categoryKey: null,
      merchant: null,
    );

    final groceries = (await categories.getAll())
        .firstWhere((category) => category.key == 'groceries');
    await budgets.save(
      BudgetEntity(
        id: 'groceries-budget',
        categoryId: groceries.id,
        amount: 1000,
        period: BudgetPeriod.monthly,
        startDate: DateTime(2026, 7),
        isActive: true,
        lastNotifiedSpentAmount: 0,
        lastNotifiedPeriodStart: DateTime.utc(2000),
      ),
    );
    final budgetProgress = BudgetProgressUseCase(
      budgetRepository: budgets,
      transactionRepository: transactions,
    );
    final reportBuilder = ReportSnapshotBuilder(
      transactions: transactions,
      accounts: accounts,
      categories: categories,
      budgets: budgetProgress,
      clock: () => now,
    );

    final headline = await transactions.expenseTotalBetween(from: from, to: to);
    final categoryTotal = (await transactions.categoryBreakdown(
      from: from,
      to: to,
    ))
        .fold<double>(0, (sum, row) => sum + row.total);
    final merchantTotal = (await transactions.merchantBreakdown(
      from: from,
      to: to,
      limit: 10,
    ))
        .fold<double>(0, (sum, row) => sum + row.total);
    final dailyTotal = (await transactions.dailyExpenseTotals(
      from: from,
      to: to,
    ))
        .fold<double>(0, (sum, row) => sum + row.total);
    final progress = await budgetProgress(now: now);
    final income = await transactions.incomeTotalBetween(from: from, to: to);
    final report = await reportBuilder.build(
      const ReportRequest(period: MonthlyPeriod()),
    );

    expect(headline, 130); // 120 + 30 unassigned - 20 refund
    expect(categoryTotal, headline);
    expect(merchantTotal, headline);
    expect(dailyTotal, headline);
    expect(progress.entries.single.spent, headline);
    expect(income, 500);
    expect(report.totalExpense, headline);
    expect(report.totalIncome, income);
    expect(report.currencyTotals.single.expense, headline);
    expect(report.currencyTotals.single.income, income);
    expect(
      report.categoryBreakdown.fold<double>(
        0,
        (sum, row) => sum + row.total,
      ),
      headline,
    );
    expect(
      report.topMerchants.fold<double>(0, (sum, row) => sum + row.total),
      headline,
    );
    expect(
      report.dailyExpense.fold<double>(0, (sum, row) => sum + row.total),
      headline,
    );
    expect(
      report.largestTransactions.map((transaction) => transaction.id),
      ['expense', 'unassigned-expense'],
    );
    expect(
      (await transactions.getById('unassigned-expense'))!.accountId,
      isNull,
    );
  });
}
