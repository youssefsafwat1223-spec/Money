import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_bill_repository.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/finance/money.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

/// MALI-074n — the installment paid count is the number of DISTINCT settled
/// installments in the ledger, not `MAX(installment_index)`.
void main() {
  late AppDatabase db;
  late DriftBillRepository repo;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    repo = DriftBillRepository(db);
    await repo.save(BillEntity(
      id: 'bill',
      name: 'قرض',
      amountMoney: Money.fromLegacyReal(100, 'SAR'),
      currency: 'SAR',
      type: BillType.installment,
      frequency: BillFrequency.monthly,
      nextDueDate: DateTime(2026, 7, 1),
      reminderOn: false,
      isConfirmed: true,
      createdAt: DateTime(2026, 7, 1),
      totalInstallments: 6,
      paidCount: 0,
    ));
  });

  tearDown(() async => db.close());

  Future<void> pay({
    required String id,
    int? index,
    String currency = 'SAR',
    String? transactionId,
  }) async {
    await repo.recordPayment(BillPaymentEntity(
      id: id,
      billId: 'bill',
      amountMoney: Money.fromLegacyReal(100, currency),
      currency: currency,
      periodStart: DateTime(2026, 7, 1),
      periodEnd: DateTime(2026, 8, 1),
      paidAt: DateTime(2026, 7, 5),
      installmentIndex: index,
      transactionId: transactionId,
    ));
  }

  Future<int> paidCount() async => (await repo.getById('bill'))!.paidCount ?? 0;

  test('paying installments 1 and 3 → count 2, not 3', () async {
    await pay(id: 'p1', index: 1);
    await pay(id: 'p3', index: 3);
    expect(await paidCount(), 2);
  });

  test('paying only installment 5 → count 1 (not 5)', () async {
    await pay(id: 'p5', index: 5);
    expect(await paidCount(), 1);
  });

  test('a duplicate record for the same installment does not increase the count',
      () async {
    await pay(id: 'p3a', index: 3);
    await pay(id: 'p3b', index: 3); // duplicate index 3
    expect(await paidCount(), 1);
  });

  test('deleting a payment lowers the count (recomputed from the ledger)',
      () async {
    await pay(id: 'p1', index: 1);
    await pay(id: 'p3', index: 3);
    expect(await paidCount(), 2);
    await repo.deletePayment('p3');
    expect(await paidCount(), 1);
  });

  test('a foreign-currency payment does not count', () async {
    await pay(id: 'usd', index: 2, currency: 'USD');
    expect(await paidCount(), 0);
  });

  test('a payment linked to a transaction counts exactly once', () async {
    await pay(id: 'p1', index: 1, transactionId: 'tx-1');
    expect(await paidCount(), 1);
  });

  test('out-of-order settlement is safe (indexes 3 then 1 → count 2)',
      () async {
    await pay(id: 'p3', index: 3);
    await pay(id: 'p1', index: 1);
    expect(await paidCount(), 2);
  });
}
