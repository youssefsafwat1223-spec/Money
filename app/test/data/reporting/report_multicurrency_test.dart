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
import 'package:money_companion/domain/reporting/report_request.dart';
import 'package:money_companion/features/reporting/composition/report_composer.dart';
import 'package:money_companion/features/reporting/composition/report_money_formatter.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

/// MALI-063n / 074n — reports never sum currencies under one label; the donut is
/// scoped to the primary currency; the exponent formatter handles 0/2/3 digits.
void main() {
  group('ReportMoneyFormatter exponents', () {
    const fmt = ReportMoneyFormatter('en');
    test('0-decimal / 2-decimal / 3-decimal', () {
      expect(fmt.money(1000, 'JPY'), '1,000 JPY');
      expect(fmt.money(400, 'SAR'), '400.00 SAR');
      expect(fmt.money(30, 'KWD'), '30.000 KWD');
    });
  });

  group('multi-currency report', () {
    late AppDatabase db;
    late DriftTransactionRepository txRepo;
    late DriftAccountRepository accountRepo;
    late ReportSnapshotBuilder builder;

    DateTime clock() => DateTime(2026, 7, 27, 12);

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

    Future<void> acct(String id, String currency, {bool isDefault = false}) =>
        accountRepo.create(AccountEntity(
          id: id,
          name: id,
          currency: currency,
          type: AccountType.bank,
          isDefault: isDefault,
          sortOrder: 0,
          createdAt: DateTime(2026, 7),
          updatedAt: DateTime(2026, 7),
        ));

    Future<void> put({
      required String id,
      required double amount,
      required TransactionTypeEntity type,
      required String currency,
      required String accountId,
      DateTime? occurredAt,
    }) =>
        txRepo.saveTransaction(
          transaction: TransactionEntity(
            id: id,
            amountMoney: Money.fromLegacyReal(amount, currency),
            currency: currency,
            type: type,
            source: TransactionSourceEntity.bank,
            occurredAt: occurredAt ?? DateTime(2026, 7, 15, 9),
            rawMessage: id,
            parseConfidence: 1,
            status: TransactionStatus.confirmed,
            createdAt: DateTime(2026, 7, 15, 9),
            updatedAt: DateTime(2026, 7, 15, 9),
            accountId: accountId,
            rawMerchant: 'M',
          ),
          categoryKey: 'groceries',
        );

    test(
        'donut is scoped to the primary currency; percentages sum within it; '
        'no cross-currency sum', () async {
      await acct('sar', 'SAR', isDefault: true);
      await acct('egp', 'EGP');
      await acct('kwd', 'KWD');
      await put(
          id: 'sar-pay',
          amount: 500,
          type: TransactionTypeEntity.payment,
          currency: 'SAR',
          accountId: 'sar');
      await put(
          id: 'sar-ref',
          amount: 100,
          type: TransactionTypeEntity.refund,
          currency: 'SAR',
          accountId: 'sar');
      await put(
          id: 'egp-pay',
          amount: 1000,
          type: TransactionTypeEntity.payment,
          currency: 'EGP',
          accountId: 'egp');
      await put(
          id: 'kwd-pay',
          amount: 30,
          type: TransactionTypeEntity.payment,
          currency: 'KWD',
          accountId: 'kwd');

      final snapshot = await builder.build(const ReportRequest(
        period: MonthlyPeriod(),
        languageCode: 'en',
        content: ReportContentOptions(includeTransactionDetails: true),
      ));

      // Per-currency breakdown: each currency isolated (SAR nets the refund).
      final byCur = snapshot.categoryBreakdownByCurrency;
      expect(byCur.keys.toSet(), {'SAR', 'EGP', 'KWD'});
      expect(Money.sum(byCur['SAR']!.map((c) => c.total), 'SAR'),
          Money(40000, 'SAR'));
      expect(Money.sum(byCur['EGP']!.map((c) => c.total), 'EGP'),
          Money(100000, 'EGP'));
      expect(Money.sum(byCur['KWD']!.map((c) => c.total), 'KWD'),
          Money(30000, 'KWD'));

      // currencyTotals never merge currencies.
      final cur = {for (final t in snapshot.currencyTotals) t.currency: t};
      expect(cur['SAR']!.expense, Money(40000, 'SAR'));
      expect(cur['EGP']!.expense, Money(100000, 'EGP'));
      expect(cur['KWD']!.expense, Money(30000, 'KWD'));

      final vm = const ReportComposer().compose(snapshot);
      // Donut center is the PRIMARY (SAR) expense, not 1430 cross-currency.
      expect(vm.category.centerValue, '400.00 SAR');
      // Slice percentages sum to ~1.0 within the primary currency.
      final pctSum = vm.category.rows.fold<double>(0, (s, r) {
        final n = double.parse(r.percent.replaceAll('%', ''));
        return s + n;
      });
      expect(pctSum, closeTo(100, 0.5));
      // Summary expense tile is the primary currency's expense only.
      expect(
        vm.summary.tiles.any((t) => t.value.contains('400.00 SAR')),
        isTrue,
      );
    });

    test(
        'half-open period: a transaction at toExclusive is in neither totals '
        'nor appendix', () async {
      await acct('sar', 'SAR', isDefault: true);
      await put(
          id: 'in',
          amount: 200,
          type: TransactionTypeEntity.payment,
          currency: 'SAR',
          accountId: 'sar',
          occurredAt: DateTime(2026, 7, 31, 23));
      // Aug 1 00:00 is the exclusive upper bound of the July monthly period.
      await put(
          id: 'boundary',
          amount: 999,
          type: TransactionTypeEntity.payment,
          currency: 'SAR',
          accountId: 'sar',
          occurredAt: DateTime(2026, 8, 1));

      final snapshot = await builder.build(const ReportRequest(
        period: MonthlyPeriod(),
        languageCode: 'en',
        content: ReportContentOptions(includeTransactionDetails: true),
      ));
      expect(snapshot.totalExpense, Money(20000, 'SAR'));
      expect(snapshot.appendixTransactions.map((t) => t.id), ['in']);
    });
  });
}
