import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_dedup_store.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';

  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

void main() {
  late AppDatabase db;
  late DriftTransactionRepository transactions;
  late DriftDedupStore dedup;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    transactions = DriftTransactionRepository(db);
    dedup = DriftDedupStore(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('deleting a transaction lets the same SMS be re-added (no stale dedup)',
      () async {
    final occurredAt = DateTime.utc(2026, 6, 26, 12);
    final now = DateTime.utc(2026, 6, 26, 12, 1);
    const hash = 'hash-abc';

    final saved = await transactions.saveTransaction(
      transaction: TransactionEntity(
        id: 'txn-1',
        amount: 42,
        currency: 'SAR',
        type: TransactionTypeEntity.payment,
        source: TransactionSourceEntity.card,
        occurredAt: occurredAt,
        rawMessage: 'POS purchase at SOME SHOP',
        rawMerchant: 'SOME SHOP',
        parseConfidence: 0.95,
        status: TransactionStatus.confirmed,
        createdAt: now,
        updatedAt: now,
      ),
      categoryKey: null,
    );
    await dedup.mark(hash, transactionId: saved.id, occurredAt: occurredAt);

    // While the transaction is alive, the same SMS is a duplicate.
    expect(await dedup.transactionIdFor(hash, occurredAt), saved.id);

    // After deletion, the stale hash must no longer block a re-add.
    await transactions.deleteTransaction(saved.id);
    expect(await dedup.transactionIdFor(hash, occurredAt), isNull);
  });
}
