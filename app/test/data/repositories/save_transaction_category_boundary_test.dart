// Phase-7 Batch-2-A (MALI-029) — the saveTransaction category-resolution
// boundary + query-count evidence.
//
// Proves: (1) a bulk caller's pre-resolved category id is used directly (no
// per-row _categoryIdByKey SELECT); (2) it still fails closed — a bogus id
// throws via the enforced FK, storing nothing; (3) the unknown-key path is
// unchanged (fails closed to null); (4) type-forcing (income/transfer/
// withdrawal) still wins over a caller's resolved id; (5) N saves sharing K
// categories perform ZERO per-row category SELECTs on the fast path.
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';

import '../../performance/perf_harness.dart';

TransactionEntity _txn(
  String id, {
  required TransactionTypeEntity type,
  String? rawMerchant,
}) {
  final now = DateTime.utc(2026, 6, 1);
  return TransactionEntity(
    id: id,
    amountMoney: Money.fromLegacyReal(42, 'SAR'),
    currency: 'SAR',
    type: type,
    source: TransactionSourceEntity.imported,
    occurredAt: now,
    rawMessage: '',
    parseConfidence: 1,
    status: TransactionStatus.confirmed,
    createdAt: now,
    updatedAt: now,
    rawMerchant: rawMerchant,
    direction: TransactionDirectionEntity.debit,
    comparisonTimestamp: now,
  );
}

Future<String> _categoryId(AppDatabase db, String key) async {
  final row = await db
      .customSelect('SELECT id FROM categories WHERE key = ? LIMIT 1;',
          variables: [Variable.withString(key)])
      .getSingleOrNull();
  return row!.read<String>('id');
}

Future<String?> _txnCategory(AppDatabase db, String id) async {
  final row = await db
      .customSelect('SELECT category_id FROM transactions WHERE id = ? LIMIT 1;',
          variables: [Variable.withString(id)])
      .getSingleOrNull();
  return row?.readNullable<String>('category_id');
}

void main() {
  test('resolved id is used directly and stored', () async {
    final counting = await openCountingDb();
    try {
      final repo = DriftTransactionRepository(counting.db);
      final foodId = await _categoryId(counting.db, 'restaurants');
      await repo.saveTransaction(
        transaction: _txn('t1', type: TransactionTypeEntity.payment),
        categoryKey: 'restaurants',
        resolvedCategoryId: foodId,
      );
      expect(await _txnCategory(counting.db, 't1'), foodId);
    } finally {
      await counting.close();
    }
  });

  test('a bogus resolved id fails closed (FK throws, nothing stored)',
      () async {
    final counting = await openCountingDb();
    try {
      final repo = DriftTransactionRepository(counting.db);
      await expectLater(
        repo.saveTransaction(
          transaction: _txn('t2', type: TransactionTypeEntity.payment),
          categoryKey: 'restaurants',
          resolvedCategoryId: 'does-not-exist',
        ),
        throwsA(anything),
      );
      // Fail-closed: the transaction row was rolled back, not stored dangling.
      expect(await _txnCategory(counting.db, 't2'), isNull);
      final exists = await counting.db
          .customSelect("SELECT 1 AS x FROM transactions WHERE id = 't2';")
          .getSingleOrNull();
      expect(exists, isNull);
    } finally {
      await counting.close();
    }
  });

  test('unknown key path still fails closed to null category', () async {
    final counting = await openCountingDb();
    try {
      final repo = DriftTransactionRepository(counting.db);
      await repo.saveTransaction(
        transaction: _txn('t3', type: TransactionTypeEntity.payment),
        categoryKey: '__no_such_key__',
      );
      expect(await _txnCategory(counting.db, 't3'), isNull);
    } finally {
      await counting.close();
    }
  });

  test('type-forcing wins over a caller resolved id (income → income cat)',
      () async {
    final counting = await openCountingDb();
    try {
      final repo = DriftTransactionRepository(counting.db);
      final foodId = await _categoryId(counting.db, 'restaurants');
      final incomeId = await _categoryId(counting.db, 'income');
      // Income type forces the 'income' category; the caller's food id must NOT
      // win — else a pulled/imported income row would be mis-categorised.
      await repo.saveTransaction(
        transaction: _txn('t4', type: TransactionTypeEntity.income),
        categoryKey: 'restaurants',
        resolvedCategoryId: foodId,
      );
      expect(await _txnCategory(counting.db, 't4'), incomeId);
      expect(incomeId, isNot(foodId));
    } finally {
      await counting.close();
    }
  });

  test('fast path performs ZERO per-row category SELECTs', () async {
    Future<int> saveSelects({required bool fast, required int n}) async {
      final counting = await openCountingDb();
      try {
        final repo = DriftTransactionRepository(counting.db);
        final ids = [
          await _categoryId(counting.db, 'restaurants'),
          await _categoryId(counting.db, 'shopping'),
          await _categoryId(counting.db, 'transport'),
        ];
        final keys = ['restaurants', 'shopping', 'transport'];
        counting.counter.reset();
        for (var i = 0; i < n; i++) {
          await repo.saveTransaction(
            transaction: _txn('row-$i', type: TransactionTypeEntity.payment),
            categoryKey: keys[i % 3],
            resolvedCategoryId: fast ? ids[i % 3] : null,
          );
        }
        return counting.counter.selects;
      } finally {
        await counting.close();
      }
    }

    // Each slow-path save does one extra `_categoryIdByKey` SELECT the fast path
    // skips; everything else (getById after insert) is identical. So the delta
    // is exactly N, and it holds at both sizes → category resolution scales with
    // distinct categories/batches (here: resolved once by the caller), not rows.
    for (final n in [100, 1000]) {
      final fast = await saveSelects(fast: true, n: n);
      final slow = await saveSelects(fast: false, n: n);
      expect(slow - fast, n,
          reason: 'fast path eliminates one category SELECT per row (N=$n)');
    }
  });
}
