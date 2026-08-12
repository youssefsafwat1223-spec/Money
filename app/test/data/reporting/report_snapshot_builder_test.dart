import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/reporting/report_snapshot_builder.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_category_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/reporting/date_range.dart';
import 'package:money_companion/domain/reporting/metrics/report_metrics_calculator.dart';
import 'package:money_companion/domain/reporting/report_request.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

void main() {
  late AppDatabase db;
  late DriftTransactionRepository txRepo;
  late DriftAccountRepository accountRepo;
  late ReportSnapshotBuilder builder;

  // Fixed reference instant → July 2026 monthly period.
  DateTime clock() => DateTime(2026, 7, 27, 12);

  TransactionEntity seed({
    required String id,
    required double amount,
    required TransactionTypeEntity type,
    required DateTime occurredAt,
    String currency = 'SAR',
    TransactionStatus status = TransactionStatus.confirmed,
    String? accountId,
    String? merchant,
  }) {
    return TransactionEntity(
      id: id,
      amountMoney: Money.fromLegacyReal(amount, currency),
      currency: currency,
      type: type,
      source: TransactionSourceEntity.bank,
      occurredAt: occurredAt,
      rawMessage: 'seed',
      parseConfidence: 1,
      status: status,
      createdAt: occurredAt,
      updatedAt: occurredAt,
      accountId: accountId,
      rawMerchant: merchant,
    );
  }

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    txRepo = DriftTransactionRepository(db);
    accountRepo = DriftAccountRepository(db);
    builder = ReportSnapshotBuilder(
      transactions: txRepo,
      accounts: accountRepo,
      categories: DriftCategoryRepository(db),
      clock: clock,
    );
  });

  tearDown(() async => db.close());

  Future<void> put(TransactionEntity t) =>
      txRepo.saveTransaction(transaction: t, categoryKey: null);

  test(
      'all-accounts snapshot: only confirmed income/expense count, per currency',
      () async {
    // SAR: income 12,400 · expense 5,000 + 3,730 = 8,730
    await put(seed(
        id: 'inc',
        amount: 12400,
        type: TransactionTypeEntity.income,
        occurredAt: DateTime.utc(2026, 7, 5)));
    await put(seed(
        id: 'p1',
        amount: 5000,
        type: TransactionTypeEntity.payment,
        occurredAt: DateTime.utc(2026, 7, 10),
        merchant: 'IKEA'));
    await put(seed(
        id: 'p2',
        amount: 3730,
        type: TransactionTypeEntity.payment,
        occurredAt: DateTime.utc(2026, 7, 20),
        merchant: 'Panda'));
    // Refund reduces expense; transfer (only internal stays transfer) and pending
    // remain excluded.
    await put(seed(
        id: 'ref',
        amount: 300,
        type: TransactionTypeEntity.refund,
        occurredAt: DateTime.utc(2026, 7, 12)));
    await put(seed(
        id: 'trf',
        amount: 1000,
        type: TransactionTypeEntity.transfer,
        occurredAt: DateTime.utc(2026, 7, 14)));
    await put(seed(
        id: 'pend',
        amount: 999,
        type: TransactionTypeEntity.payment,
        occurredAt: DateTime.utc(2026, 7, 15),
        status: TransactionStatus.pending));
    // A second currency — must stay separate (no FX).
    await put(seed(
        id: 'usd',
        amount: 200,
        currency: 'USD',
        type: TransactionTypeEntity.payment,
        occurredAt: DateTime.utc(2026, 7, 11),
        merchant: 'Steam'));

    final snap =
        await builder.build(const ReportRequest(period: MonthlyPeriod()));

    expect(snap.range, DateRange(DateTime(2026, 7), DateTime(2026, 8)));
    expect(snap.capturedAt, clock());

    final sar = snap.currencyTotals.firstWhere((c) => c.currency == 'SAR');
    expect(sar.income, Money(1240000, 'SAR'));
    expect(sar.expense, Money(843000, 'SAR'));

    final usd = snap.currencyTotals.firstWhere((c) => c.currency == 'USD');
    expect(usd.expense, Money(20000, 'USD'));
    expect(usd.income, Money(0, 'USD'));

    // Metrics computed from the snapshot's frozen totals.
    const metrics = ReportMetricsCalculator();
    expect(
        metrics.computeCashFlow(income: sar.income, expense: sar.expense).net,
        Money(397000, 'SAR'));

    // Largest = confirmed expenses only, sorted desc: 5000, 3730, 200.
    expect(snap.largestTransactions.map((t) => t.amount).toList(),
        [5000, 3730, 200]);
    expect(
      snap.largestTransactions.every((t) =>
          t.type == TransactionTypeEntity.payment ||
          t.type == TransactionTypeEntity.withdrawal),
      isTrue,
    );
  });

  test(
      'snapshot is frozen: later DB writes do not change an already-built snapshot',
      () async {
    await put(seed(
        id: 'p1',
        amount: 5000,
        type: TransactionTypeEntity.payment,
        occurredAt: DateTime.utc(2026, 7, 10)));

    final first =
        await builder.build(const ReportRequest(period: MonthlyPeriod()));
    expect(first.totalExpense, Money(500000, 'SAR'));

    // Mutate the DB after the snapshot was captured.
    await put(seed(
        id: 'p2',
        amount: 2000,
        type: TransactionTypeEntity.payment,
        occurredAt: DateTime.utc(2026, 7, 12)));

    // The already-built snapshot is unchanged (internally consistent).
    expect(first.totalExpense, Money(500000, 'SAR'));
    // A fresh build reflects the new data.
    final second =
        await builder.build(const ReportRequest(period: MonthlyPeriod()));
    expect(second.totalExpense, Money(700000, 'SAR'));
  });

  test(
      'single-account scope uses the account currency and only its transactions',
      () async {
    final now = clock();
    final usdAccount = await accountRepo.create(
      AccountEntity(
        id: 'usd-acc',
        name: 'Travel USD',
        currency: 'USD',
        type: AccountType.bank,
        isDefault: false,
        sortOrder: 1,
        createdAt: now,
        updatedAt: now,
      ),
    );
    // One USD expense on the USD account, one SAR expense elsewhere (default acct).
    await put(seed(
        id: 'u1',
        amount: 200,
        currency: 'USD',
        type: TransactionTypeEntity.payment,
        occurredAt: DateTime.utc(2026, 7, 9),
        accountId: usdAccount.id));
    await put(seed(
        id: 's1',
        amount: 999,
        currency: 'SAR',
        type: TransactionTypeEntity.payment,
        occurredAt: DateTime.utc(2026, 7, 9)));

    final snap = await builder.build(
      ReportRequest(
          period: const MonthlyPeriod(),
          scope: SingleAccountScope(usdAccount.id)),
    );

    expect(snap.currencyTotals.length, 1);
    expect(snap.currencyTotals.single.currency, 'USD');
    expect(snap.currencyTotals.single.expense,
        Money(20000, 'USD')); // SAR txn excluded by scope
    expect(snap.accountsInScope.single.name, 'Travel USD');
  });
}
