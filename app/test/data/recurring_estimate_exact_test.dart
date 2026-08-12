import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/report_models.dart';
import 'package:money_companion/domain/finance/money.dart';

// MALI-026 (B8-3 §16 correction) — the recurring-subscription MONETARY estimate
// is EXACT Money: SUM(amount_minor) / count, ROUND_HALF_AWAY_FROM_ZERO once, in
// the candidate's own currency. The recurrence-STABILITY gate stays a separate
// integer heuristic. Currencies are never combined; the monthly total is a
// same-currency Money.sum.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late DriftTransactionRepository repo;
  setUp(() async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    repo = DriftTransactionRepository(db);
  });
  tearDown(() async => db.close());

  var seq = 0;
  Future<void> merchant(String id, String name) => db.customStatement(
        "INSERT INTO merchants(id,raw_name,normalized_name,first_seen_at,"
        "last_seen_at) VALUES ('$id','$name','$name','2026-01-01T00:00:00Z',"
        "'2026-01-01T00:00:00Z');",
      );

  Future<void> pay(String merchantId, int minor, String currency, String month) async {
    seq++;
    await db.customInsert(
      'INSERT INTO transactions(id, amount, amount_minor, currency, merchant_id, '
      'raw_merchant, type, source, occurred_at, raw_message, parse_confidence, '
      'status, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?);',
      variables: [
        Variable.withString('t$seq'),
        Variable.withReal(minor.toDouble()),
        Variable.withInt(minor),
        Variable.withString(currency),
        Variable.withString(merchantId),
        Variable.withString('m'),
        Variable.withString('payment'),
        Variable.withString('manual'),
        Variable.withString('2026-$month-10T00:00:00.000Z'),
        Variable.withString('r'),
        Variable.withReal(1.0),
        Variable.withString('confirmed'),
        Variable.withString('2026-$month-10T00:00:00.000Z'),
        Variable.withString('2026-$month-10T00:00:00.000Z'),
      ],
    );
  }

  RecurringCandidate byName(List<RecurringCandidate> cs, String name) =>
      cs.firstWhere((c) => c.name == name);

  test('exact average estimate — 0/2/3-decimal currencies, exact minor', () async {
    await merchant('m-jpy', 'JPY-SUB');
    await pay('m-jpy', 700, 'JPY', '01');
    await pay('m-jpy', 700, 'JPY', '02'); // avg 700 → 700 JPY

    await merchant('m-sar', 'SAR-SUB');
    await pay('m-sar', 5600, 'SAR', '01');
    await pay('m-sar', 5600, 'SAR', '02'); // avg 5600 → 56.00 SAR

    await merchant('m-kwd', 'KWD-SUB');
    await pay('m-kwd', 1000, 'KWD', '01');
    await pay('m-kwd', 1002, 'KWD', '02'); // avg 1001 → 1.001 KWD

    final cs = await repo.recurringCandidates();
    expect(byName(cs, 'JPY-SUB').estimatedAmountMoney, Money(700, 'JPY'));
    expect(byName(cs, 'SAR-SUB').estimatedAmountMoney, Money(5600, 'SAR'));
    expect(byName(cs, 'KWD-SUB').estimatedAmountMoney, Money(1001, 'KWD'));
  });

  test('ROUND_HALF_AWAY_FROM_ZERO applied once to the exact average', () async {
    // 1000 + 1001 = 2001, /2 = 1000.5 → 1001 (half away, not banker's 1000).
    await merchant('m-a', 'HALF-A');
    await pay('m-a', 1000, 'SAR', '01');
    await pay('m-a', 1001, 'SAR', '02');
    // 1001 + 1002 = 2003, /2 = 1001.5 → 1002.
    await merchant('m-b', 'HALF-B');
    await pay('m-b', 1001, 'SAR', '01');
    await pay('m-b', 1002, 'SAR', '02');

    final cs = await repo.recurringCandidates();
    expect(byName(cs, 'HALF-A').estimatedAmountMoney, Money(1001, 'SAR'));
    expect(byName(cs, 'HALF-B').estimatedAmountMoney, Money(1002, 'SAR'));
  });

  test('mixed-currency candidates stay isolated; same-currency total sums exact',
      () async {
    // Two SAR subs + one EGP sub. SAR monthly total = sum of the SAR estimates;
    // EGP stays separate — never folded into one number.
    await merchant('m-s1', 'S1');
    await pay('m-s1', 5000, 'SAR', '01');
    await pay('m-s1', 5000, 'SAR', '02'); // 50.00 SAR
    await merchant('m-s2', 'S2');
    await pay('m-s2', 2500, 'SAR', '01');
    await pay('m-s2', 2500, 'SAR', '02'); // 25.00 SAR
    await merchant('m-e', 'E1');
    await pay('m-e', 9000, 'EGP', '01');
    await pay('m-e', 9000, 'EGP', '02'); // 90.00 EGP

    final cs = await repo.recurringCandidates();
    final sar = cs.where((c) => c.currency == 'SAR').toList();
    final egp = cs.where((c) => c.currency == 'EGP').toList();
    expect(sar.length, 2);
    expect(egp.length, 1);

    // Same-currency monthly total is an exact Money.sum (never cross-currency).
    final sarTotal = Money.sum(sar.map((c) => c.estimatedAmountMoney), 'SAR');
    expect(sarTotal, Money(7500, 'SAR')); // 50.00 + 25.00
    expect(egp.single.estimatedAmountMoney, Money(9000, 'EGP'));
    // Proof of no cross-currency fold: SAR total is 7500 SAR, NOT 16500 of some
    // merged currency.
    expect(sarTotal.currency, 'SAR');
  });
}
