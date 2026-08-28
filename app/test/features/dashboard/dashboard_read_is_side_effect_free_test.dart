import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/account_currency_repair_service.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/features/dashboard/dashboard_providers.dart';
import 'package:money_companion/features/planning_sync/services/outbox_queue_factory.dart';

/// C-9 — a READ path must never mutate financial state.
///
/// `dashboardDataProvider` used to call `_ensureCurrencyAccounts`, which created
/// accounts and reassigned transactions. Both repositories enqueue sync intent,
/// so merely opening Home produced durable financial rows AND cloud writes. That
/// is the same architectural fault as F-020 (browsing an account rewrote the
/// persistent default), and it also corrupts any measurement taken afterwards:
/// you cannot audit a system whose state changes because you looked at it.
///
/// The repair now runs once at startup as an explicit command
/// (`AccountCurrencyRepairService`, invoked by `BootstrapRunner`).
class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';

  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

Future<AppDatabase> _openDb() => AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );

/// Counts every row that a mutating repair would have created or touched.
Future<({int accounts, int nullAccountTxns, int outbox})> _snapshot(
  AppDatabase db,
) async {
  Future<int> count(String sql) async =>
      (await db.customSelect(sql).getSingle()).read<int>('c');
  return (
    accounts: await count('SELECT COUNT(*) AS c FROM accounts;'),
    nullAccountTxns: await count(
      'SELECT COUNT(*) AS c FROM transactions WHERE account_id IS NULL;',
    ),
    outbox: await count(
      'SELECT COUNT(*) AS c FROM ledger_sync_outbox;',
    ),
  );
}

void main() {
  late AppDatabase db;

  setUp(() async {
    db = await _openDb();
    // Wipe the seeded state so "no accounts + an orphan transaction" is the
    // exact precondition the old read-path repair reacted to.
    await db.customStatement('DELETE FROM accounts;');
    await db.customStatement('DELETE FROM transactions;');
    await db.customStatement('DELETE FROM ledger_sync_outbox;');
    // Raw insert: the legacy shape this repair exists to fix (account_id NULL).
    await db.customStatement(
      "INSERT INTO transactions(id, amount, amount_minor, currency, type, source, "
      "occurred_at, raw_message, parse_confidence, status, created_at, "
      "updated_at, account_id) "
      "VALUES('tx-orphan', 25.0, 2500, 'EGP', 'payment', 'imported', "
      "'2026-08-01T00:00:00Z', 'test', 1.0, 'confirmed', "
      "'2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z', NULL);",
    );
    await db.customStatement('DELETE FROM ledger_sync_outbox;');
  });

  tearDown(() async => db.close());

  test(
      'C-9: reading the dashboard creates no account, reassigns no transaction '
      'and queues no sync intent', () async {
    final before = await _snapshot(db);
    expect(before.accounts, 0, reason: 'precondition: no accounts exist');
    expect(before.nullAccountTxns, 1,
        reason: 'precondition: an orphan transaction is present');
    expect(before.outbox, 0);

    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);

    // Read Home exactly as the UI does.
    await container.read(dashboardDataProvider.future);

    final after = await _snapshot(db);
    expect(after.accounts, 0,
        reason: 'a READ must not create an account — it did before C-9');
    expect(after.nullAccountTxns, 1,
        reason: 'a READ must not reassign a transaction');
    expect(after.outbox, 0,
        reason: 'a READ must not produce cloud sync intent');
  });

  test('C-9: the startup repair — not the read — performs the migration',
      () async {
    // Same precondition, now driven through the explicit command. This proves
    // the behaviour was MOVED, not deleted.
    final result = await AccountCurrencyRepairService(
      accounts: DriftAccountRepository(
        db,
        outboxQueue: buildPlanningOutboxQueue(db),
      ),
      transactions: DriftTransactionRepository(
        db,
        outboxQueue: buildLedgerOutboxQueue(db),
      ),
    ).run(fallbackCurrency: 'EGP');

    expect(result.madeChanges, isTrue);
    expect(result.accountsCreated, 1);
    expect(result.transactionsReassigned, 1);

    final after = await _snapshot(db);
    expect(after.accounts, 1);
    expect(after.nullAccountTxns, 0);
  });
}
