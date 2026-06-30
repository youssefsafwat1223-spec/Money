import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_dedup_store.dart';
import 'package:money_companion/engine/dedup/transaction_dedup.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ─── Hash-key correctness ────────────────────────────────────────────────

  group('TransactionDedup.computeHash — key discrimination', () {
    test('identical inputs produce identical hashes', () async {
      final a = await TransactionDedup.computeHash(
        amount: 24.0,
        currency: 'SAR',
        cardLast4: '1234',
        merchantNormalized: 'STARBUCKS',
        type: 'payment',
      );
      final b = await TransactionDedup.computeHash(
        amount: 24.0,
        currency: 'SAR',
        cardLast4: '1234',
        merchantNormalized: 'STARBUCKS',
        type: 'payment',
      );
      expect(a, equals(b));
    });

    // ── CONCERN 1 test: same amount + card, DIFFERENT merchant → different hash ──
    test(
      'same amount, same card, different merchant → distinct hashes (never a false duplicate)',
      () async {
        final coffee = await TransactionDedup.computeHash(
          amount: 24.0,
          currency: 'SAR',
          cardLast4: '1234',
          merchantNormalized: 'STARBUCKS',
          type: 'payment',
        );
        final grocery = await TransactionDedup.computeHash(
          amount: 24.0,
          currency: 'SAR',
          cardLast4: '1234',
          merchantNormalized: 'PANDA',
          type: 'payment',
        );
        expect(coffee, isNot(equals(grocery)),
            reason:
                '24 SAR at Starbucks vs 24 SAR at Panda are different transactions');
      },
    );

    test('no-merchant null and empty-string merchant produce the same hash',
        () async {
      final withNull = await TransactionDedup.computeHash(
        amount: 500.0,
        currency: 'SAR',
        cardLast4: null,
        merchantNormalized: null,
        type: 'withdrawal',
      );
      final withEmpty = await TransactionDedup.computeHash(
        amount: 500.0,
        currency: 'SAR',
        cardLast4: null,
        merchantNormalized: '',
        type: 'withdrawal',
      );
      // normalizeMerchant('') trims to '' which equals null path → same hash
      expect(withNull, equals(withEmpty));
    });

    test('different transaction types produce different hashes', () async {
      final payment = await TransactionDedup.computeHash(
        amount: 100.0,
        currency: 'SAR',
        cardLast4: null,
        merchantNormalized: null,
        type: 'payment',
      );
      final transfer = await TransactionDedup.computeHash(
        amount: 100.0,
        currency: 'SAR',
        cardLast4: null,
        merchantNormalized: null,
        type: 'transfer',
      );
      expect(payment, isNot(equals(transfer)));
    });
  });

  // ─── Exact timestamp store ───────────────────────────────────────────────

  group('DriftDedupStore — exact comparison timestamp', () {
    late AppDatabase db;
    late DriftDedupStore store;

    setUp(() async {
      db = await AppDatabase.open(
        executor: NativeDatabase.memory(),
        keyStore: _MemoryKeyStore(),
      );
      store = DriftDedupStore(db);
    });

    tearDown(() => db.close());

    Future<String> hashFor(String merchant) => TransactionDedup.computeHash(
          amount: 99.0,
          currency: 'SAR',
          cardLast4: '5678',
          merchantNormalized: merchant,
          type: 'payment',
        );

    test('exact same time → duplicate detected', () async {
      final t = DateTime.utc(2026, 6, 16, 10, 0, 0);
      final hash = await hashFor('MCDONALDS');
      await store.mark(hash, transactionId: 'txn-1', occurredAt: t);

      final found = await store.transactionIdFor(hash, t);
      expect(found, equals('txn-1'));
    });

    test('2 minutes later → not a duplicate', () async {
      final stored = DateTime.utc(2026, 6, 16, 10, 3, 0);
      final query = DateTime.utc(2026, 6, 16, 10, 5, 0); // 2 min later
      final hash = await hashFor('MCDONALDS');
      await store.mark(hash, transactionId: 'txn-2', occurredAt: stored);

      final found = await store.transactionIdFor(hash, query);
      expect(found, isNull);
    });

    test(
      'same hash but different exact timestamp stays separate',
      () async {
        final bankTime = DateTime.utc(2026, 6, 16, 10, 4, 30);
        final walletTime = DateTime.utc(2026, 6, 16, 10, 5, 30);
        final hash = await hashFor('PANDA');
        await store.mark(hash, transactionId: 'txn-3', occurredAt: bankTime);

        final found = await store.transactionIdFor(hash, walletTime);
        expect(found, isNull,
            reason: 'Different comparison timestamps are real transactions');
      },
    );

    test('7 minutes apart → not a duplicate', () async {
      final t1 = DateTime.utc(2026, 6, 16, 10, 0, 0);
      final t2 = DateTime.utc(2026, 6, 16, 10, 7, 0); // 7 min later
      final hash = await hashFor('HERFY');
      await store.mark(hash, transactionId: 'txn-4', occurredAt: t1);

      final found = await store.transactionIdFor(hash, t2);
      expect(found, isNull,
          reason: '7 min apart: genuine second transaction, not a duplicate');
    });

    // ── CONCERN 1 test via store: same amount+card, different merchant → no collision ──
    test(
      'same amount, same card, different merchant in store → second transaction NOT blocked',
      () async {
        final t = DateTime.utc(2026, 6, 16, 12, 0, 0);
        final coffeeHash = await hashFor('STARBUCKS');
        final groceryHash =
            await hashFor('PANDA'); // same amount, different merchant

        await store.mark(coffeeHash,
            transactionId: 'txn-coffee', occurredAt: t);

        final found = await store.transactionIdFor(
          groceryHash,
          t,
        );
        expect(found, isNull,
            reason:
                'Starbucks 24 SAR must not block a Panda 24 SAR at the same time');
      },
    );
  });
}
