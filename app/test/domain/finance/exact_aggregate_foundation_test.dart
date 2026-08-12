import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/domain/finance/financial_semantics.dart';
import 'package:money_companion/domain/finance/money.dart';

// MALI-026 (B8-3 Step 5 §16 / stage 1) — the exact integer aggregate FOUNDATION.
// `SUM(FinancialSql.netExpenseSignedAmountMinor())` operates on the int64
// `amount_minor` column, within ONE currency, and is NOT wrapped in
// CAST(... AS REAL): an int64 overflow raises a SQLite error (fail-exact), never
// a floating approximation. Refund/status/exclusion semantics come from the same
// centralized FinancialSql predicates as the legacy REAL aggregates.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  setUp(() async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
  });
  tearDown(() async => db.close());

  var seq = 0;
  Future<void> tx({
    required int minor,
    required String currency,
    String type = 'payment',
    String status = 'confirmed',
    String? accountId,
  }) async {
    seq++;
    await db.customInsert(
      'INSERT INTO transactions(id, amount, amount_minor, currency, raw_merchant, '
      'type, source, occurred_at, raw_message, parse_confidence, status, '
      'created_at, updated_at, account_id) '
      'VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?);',
      variables: [
        Variable.withString('t$seq'),
        Variable.withReal(minor.toDouble()),
        Variable.withInt(minor),
        Variable.withString(currency),
        Variable.withString('m'),
        Variable.withString(type),
        Variable.withString('manual'),
        Variable.withString('2026-08-01T00:00:00.000Z'),
        Variable.withString('r'),
        Variable.withReal(1.0),
        Variable.withString(status),
        Variable.withString('2026-08-01T00:00:00.000Z'),
        Variable.withString('2026-08-01T00:00:00.000Z'),
        accountId == null ? const Variable(null) : Variable.withString(accountId),
      ],
    );
  }

  // The canonical exact net-expense total for ONE currency.
  Future<Money> netExpense(String currency, {String? accountId}) async {
    final acct = accountId == null ? '' : ' AND account_id = ?';
    final row = await db.customSelect(
      'SELECT COALESCE(SUM(${FinancialSql.netExpenseSignedAmountMinor()}), 0) AS t '
      'FROM transactions '
      "WHERE ${FinancialSql.confirmedPredicate()} "
      'AND ${FinancialSql.netExpenseTypePredicate()} '
      'AND UPPER(currency) = ?$acct;',
      variables: [
        Variable.withString(currency.toUpperCase()),
        if (accountId != null) Variable.withString(accountId),
      ],
    ).getSingle();
    return Money(row.read<int>('t'), currency);
  }

  test('empty → Money.zero', () async {
    expect(await netExpense('EGP'), Money(0, 'EGP'));
  });

  test('positive payments sum exactly in minor units', () async {
    await tx(minor: 1001, currency: 'EGP');
    await tx(minor: 2002, currency: 'EGP');
    expect(await netExpense('EGP'), Money(3003, 'EGP')); // 30.03 EGP
  });

  test('refund subtracts, withdrawal adds (net-expense signing)', () async {
    await tx(minor: 5000, currency: 'EGP', type: 'payment');
    await tx(minor: 1500, currency: 'EGP', type: 'withdrawal');
    await tx(minor: 500, currency: 'EGP', type: 'refund');
    expect(await netExpense('EGP'), Money(6000, 'EGP')); // 5000+1500-500
  });

  test('income type contributes 0 to net-expense', () async {
    await tx(minor: 9999, currency: 'EGP', type: 'income');
    expect(await netExpense('EGP'), Money(0, 'EGP'));
  });

  test('pending / ignored rows are excluded (confirmed only)', () async {
    await tx(minor: 1000, currency: 'EGP', status: 'pending');
    await tx(minor: 2000, currency: 'EGP', status: 'ignored');
    await tx(minor: 300, currency: 'EGP', status: 'confirmed');
    expect(await netExpense('EGP'), Money(300, 'EGP'));
  });

  test('single-currency scope never mixes currencies', () async {
    await tx(minor: 100, currency: 'EGP'); // 2-dec
    await tx(minor: 50, currency: 'SAR'); // 2-dec
    await tx(minor: 1000, currency: 'KWD'); // 3-dec
    expect(await netExpense('EGP'), Money(100, 'EGP'));
    expect(await netExpense('SAR'), Money(50, 'SAR'));
    expect(await netExpense('KWD'), Money(1000, 'KWD'));
  });

  test('0-decimal (JPY) sums in whole minor units', () async {
    await tx(minor: 700, currency: 'JPY');
    await tx(minor: 300, currency: 'JPY');
    expect(await netExpense('JPY'), Money(1000, 'JPY'));
  });

  test('account scope filters to one account', () async {
    await tx(minor: 100, currency: 'EGP', accountId: 'a1');
    await tx(minor: 200, currency: 'EGP', accountId: 'a2');
    expect(await netExpense('EGP', accountId: 'a1'), Money(100, 'EGP'));
  });

  test('excluded-from-totals accounts drop out of the combined total', () async {
    await db.customStatement(
      "INSERT INTO accounts(id,name,currency,type,exclude_from_totals,"
      "is_default,sort_order,created_at,updated_at) VALUES "
      "('ax','X','EGP','bank',1,0,1,'2026-08-01T00:00:00Z','2026-08-01T00:00:00Z');",
    );
    await tx(minor: 100, currency: 'EGP', accountId: 'ax'); // excluded
    await tx(minor: 40, currency: 'EGP'); // NULL account → stays in
    final row = await db.customSelect(
      'SELECT COALESCE(SUM(${FinancialSql.netExpenseSignedAmountMinor()}), 0) AS t '
      'FROM transactions '
      "WHERE ${FinancialSql.confirmedPredicate()} "
      'AND ${FinancialSql.netExpenseTypePredicate()} '
      'AND UPPER(currency) = ? '
      'AND ${FinancialSql.excludedAccountExclusion()};',
      variables: [Variable.withString('EGP')],
    ).getSingle();
    expect(Money(row.read<int>('t'), 'EGP'), Money(40, 'EGP'));
  });

  test('int64 SUM overflow FAILS EXACT (SQLite raises, no float fallback)',
      () async {
    // Two int64-max payments overflow signed int64 → SQLite integer-overflow.
    await tx(minor: 9223372036854775807, currency: 'EGP');
    await tx(minor: 9223372036854775807, currency: 'EGP');
    await expectLater(netExpense('EGP'), throwsA(anything));
  });
}
