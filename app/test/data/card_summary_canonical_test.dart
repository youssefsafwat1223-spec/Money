import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

/// MALI-074n — card summaries are per-currency, net-spend refund-netted, income
/// only in inflow, confirmed-only, and pagination-independent (set-based).
void main() {
  late AppDatabase db;
  late DriftTransactionRepository txRepo;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    txRepo = DriftTransactionRepository(db);
  });

  tearDown(() async => db.close());

  Future<void> tx({
    required String id,
    required double amount,
    required String type,
    String last4 = '1234',
    String currency = 'SAR',
    String status = 'confirmed',
  }) async {
    await db.customInsert(
      '''
        INSERT INTO transactions(
          id, amount, currency, type, source, card_last4,
          occurred_at, raw_message, parse_confidence, status,
          created_at, updated_at
        ) VALUES (?, ?, ?, ?, 'sms', ?, ?, 'visa', 1, ?, ?, ?);
      ''',
      variables: [
        Variable.withString(id),
        Variable.withReal(amount),
        Variable.withString(currency),
        Variable.withString(type),
        Variable.withString(last4),
        Variable.withString(dateTimeToSql(DateTime.utc(2026, 7, 15).toUtc())),
        Variable.withString(status),
        Variable.withString(dateTimeToSql(DateTime.utc(2026, 7, 15).toUtc())),
        Variable.withString(dateTimeToSql(DateTime.utc(2026, 7, 15).toUtc())),
      ],
    );
  }

  test('spent nets refunds; inflow is income only (not refund)', () async {
    await tx(id: 'pay', amount: 500, type: 'payment');
    await tx(id: 'wd', amount: 40, type: 'withdrawal');
    await tx(id: 'ref', amount: 100, type: 'refund');
    await tx(id: 'inc', amount: 300, type: 'income');
    await tx(id: 'xfer', amount: 999, type: 'transfer');

    final summary = (await txRepo.getCardSummaries()).single;
    expect(summary.currency, 'SAR');
    expect(summary.totalOut, 440); // 500 + 40 − 100 refund
    expect(summary.totalIn, 300); // income only (refund NOT counted as income)
  });

  test('a card used in two currencies yields two per-currency summaries',
      () async {
    await tx(id: 'sar', amount: 100, type: 'payment', currency: 'SAR');
    await tx(id: 'usd', amount: 200, type: 'payment', currency: 'USD');

    final summaries = await txRepo.getCardSummaries();
    final byCur = {for (final s in summaries) s.currency: s};
    expect(byCur.keys.toSet(), {'SAR', 'USD'});
    expect(byCur['SAR']!.totalOut, 100); // never 300 cross-currency
    expect(byCur['USD']!.totalOut, 200);
  });

  test('pending / ignored never count toward card totals', () async {
    await tx(id: 'ok', amount: 100, type: 'payment');
    await tx(id: 'pending', amount: 50, type: 'payment', status: 'pending');
    await tx(id: 'ignored', amount: 70, type: 'payment', status: 'ignored');
    final summary = (await txRepo.getCardSummaries()).single;
    expect(summary.totalOut, 100);
  });

  test('501 rows aggregate set-based (pagination cannot change the total)',
      () async {
    for (var i = 0; i < 501; i++) {
      await tx(id: 'p$i', amount: 1, type: 'payment');
    }
    final summary = (await txRepo.getCardSummaries()).single;
    expect(summary.totalOut, 501);
  });
}
