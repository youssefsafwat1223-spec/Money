import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/account_currency_repair_service.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/features/planning_sync/services/outbox_queue_factory.dart';

/// C-9 — the startup repair must perform the migration EXACTLY ONCE.
///
/// The bootstrap guards it with a per-process flag, but a flag resets on every
/// boot, so it cannot be the real protection. The protection has to be
/// idempotence by construction: only create a currency that has no account,
/// only touch `account_id IS NULL` rows. A repaired install then writes
/// nothing on later boots — and because writes are what enqueue, that is also
/// what stops repeated boots from queueing duplicate sync intent.
class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';

  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

void main() {
  late AppDatabase db;

  AccountCurrencyRepairService service() => AccountCurrencyRepairService(
        accounts: DriftAccountRepository(
          db,
          outboxQueue: buildPlanningOutboxQueue(db),
        ),
        transactions: DriftTransactionRepository(
          db,
          outboxQueue: buildLedgerOutboxQueue(db),
        ),
      );

  Future<int> count(String sql) async =>
      (await db.customSelect(sql).getSingle()).read<int>('c');

  Future<int> accounts() => count('SELECT COUNT(*) AS c FROM accounts;');
  Future<int> orphans() => count(
      'SELECT COUNT(*) AS c FROM transactions WHERE account_id IS NULL;');
  Future<int> outboxRows() => count(
      'SELECT COUNT(*) AS c FROM ledger_sync_outbox;');

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    await db.customStatement('DELETE FROM accounts;');
    await db.customStatement('DELETE FROM transactions;');
    await db.customStatement('DELETE FROM ledger_sync_outbox;');
    Future<void> insertOrphan(String id, String currency) async {
      await db.customStatement(
        "INSERT INTO transactions(id, amount, amount_minor, currency, type, source, "
        "occurred_at, raw_message, parse_confidence, status, created_at, "
        "updated_at, account_id) "
        "VALUES('$id', 10.0, 1000, '$currency', 'payment', 'imported', "
        "'2026-08-01T00:00:00Z', 'test', 1.0, 'confirmed', "
        "'2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z', NULL);",
      );
    }
    await insertOrphan('tx-egp', 'EGP');
    await insertOrphan('tx-sar', 'SAR');
    await db.customStatement('UPDATE transactions SET account_id = NULL;');
    await db.customStatement('DELETE FROM ledger_sync_outbox;');
  });

  tearDown(() async => db.close());

  test('a second run is a complete no-op — the migration happens once',
      () async {
    final first = await service().run(fallbackCurrency: 'EGP');
    expect(first.madeChanges, isTrue);
    expect(first.accountsCreated, 2,
        reason: 'one account per distinct transaction currency');
    expect(first.transactionsReassigned, 2);

    final accountsAfterFirst = await accounts();
    final outboxAfterFirst = await outboxRows();
    expect(await orphans(), 0);

    // Simulate the next boot: same data, fresh service, no in-process flag.
    final second = await service().run(fallbackCurrency: 'EGP');

    expect(second.madeChanges, isFalse,
        reason: 'the repair must be idempotent BY CONSTRUCTION, not by a flag');
    expect(second.accountsCreated, 0);
    expect(second.transactionsReassigned, 0);
    expect(await accounts(), accountsAfterFirst,
        reason: 'no duplicate per-currency accounts on a repeat boot');
    expect(await outboxRows(), outboxAfterFirst,
        reason: 'a repeat boot must not enqueue duplicate sync intent');
  });

  test('repeated boots never accumulate state', () async {
    await service().run(fallbackCurrency: 'EGP');
    final settled = (
      accounts: await accounts(),
      orphans: await orphans(),
      outbox: await outboxRows(),
    );

    for (var boot = 0; boot < 3; boot++) {
      final result = await service().run(fallbackCurrency: 'EGP');
      expect(result.madeChanges, isFalse, reason: 'boot ${boot + 2}');
    }

    expect(await accounts(), settled.accounts);
    expect(await orphans(), settled.orphans);
    expect(await outboxRows(), settled.outbox);
  });

  test('a transaction that already has an account is never touched', () async {
    // The repair targets `account_id IS NULL` only. Proving it leaves assigned
    // rows alone is what makes "exactly once" meaningful: a second boot must not
    // be able to re-home money that was already placed (or that the user moved
    // deliberately).
    await service().run(fallbackCurrency: 'EGP');
    final placed = await db
        .customSelect("SELECT account_id FROM transactions WHERE id = 'tx-egp';")
        .getSingle();
    final originalAccount = placed.read<String>('account_id');

    // Move it somewhere else, exactly as a user re-assigning a transaction would.
    await db.customStatement(
      "UPDATE transactions SET account_id = 'manually-chosen' WHERE id = 'tx-egp';",
    );

    final second = await service().run(fallbackCurrency: 'EGP');

    expect(second.madeChanges, isFalse);
    final after = await db
        .customSelect("SELECT account_id FROM transactions WHERE id = 'tx-egp';")
        .getSingle();
    expect(after.read<String>('account_id'), 'manually-chosen',
        reason: 'the repair must never re-home an already-assigned transaction');
    expect(originalAccount, isNot('manually-chosen'));
  });
}
