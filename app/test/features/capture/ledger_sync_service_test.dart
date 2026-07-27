import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';
import 'package:money_companion/data/repositories/drift_dedup_store.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/features/capture/services/ledger_sync_service.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';

  @override
  Future<String?> readStoredKey() async => 'test-key';
}

class _MockRemoteSource implements LedgerRemoteSource {
  List<Map<String, dynamic>> activeRows = [];
  List<Map<String, dynamic>> tombstones = [];

  @override
  Future<List<Map<String, dynamic>>> fetchActiveRows({int limit = 200}) async =>
      activeRows;

  @override
  Future<List<Map<String, dynamic>>> fetchTombstones({
    int limit = 200,
  }) async =>
      tombstones;
}

Map<String, dynamic> _serverRow({
  String id = 'test-server-uuid',
  String? payloadId,
  double amount = 100.0,
  String currency = 'SAR',
  String type = 'debit',
  String source = 'ios_shortcut',
  String? merchant,
  String? updatedAt,
}) =>
    {
      'id': id,
      'source_payload_id': payloadId,
      'amount': amount,
      'currency': currency,
      'direction': type == 'credit' ? 'credit' : 'debit',
      'transaction_type': switch (type) {
        'credit' => 'income',
        'transfer' => 'transfer',
        _ => 'expense',
      },
      'source': source,
      'merchant': merchant,
      'occurred_at': '2026-01-01T10:00:00.000Z',
      'updated_at': updatedAt ?? '2026-01-01T10:00:00.000Z',
      'confidence': 0.9,
    };

LedgerSyncService _makeSvc(
  AppDatabase db,
  _MockRemoteSource remote, {
  bool flagOn = true,
  bool signedIn = true,
}) =>
    LedgerSyncService(
      db: db,
      transactionRepository: DriftTransactionRepository(db),
      dedupStore: DriftDedupStore(db),
      isPullEnabled: () => flagOn,
      remoteSource: remote,
      getAuthUserId: () async => signedIn ? 'test-user-id' : null,
    );

void main() {
  late AppDatabase db;
  late _MockRemoteSource remote;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    remote = _MockRemoteSource();
  });

  tearDown(() async {
    await db.close();
  });

  test('does nothing when ledger_pull_sync flag is OFF', () async {
    remote.activeRows = [_serverRow()];
    final result = await _makeSvc(db, remote, flagOn: false).pull();

    expect(result.imported, 0);
    expect(result.updated, 0);
    expect(await db.count('transactions'), 0);
  });

  test('does nothing when user is a guest (no session)', () async {
    remote.activeRows = [_serverRow()];
    final result = await _makeSvc(db, remote, signedIn: false).pull();

    expect(result.imported, 0);
    expect(await db.count('transactions'), 0);
  });

  test('imports one server transaction into empty Drift DB', () async {
    remote.activeRows = [_serverRow()];
    final result = await _makeSvc(db, remote).pull();

    expect(result.imported, 1);
    expect(result.updated, 0);
    expect(await db.count('transactions'), 1);

    final rows = await db
        .customSelect('SELECT server_id, sync_status FROM transactions;')
        .get();
    expect(rows.first.readNullable<String>('server_id'), 'test-server-uuid');
    expect(rows.first.readNullable<String>('sync_status'), 'synced');
  });

  test('second pull of an unchanged row is a no-op and does not duplicate',
      () async {
    remote.activeRows = [_serverRow()];
    await _makeSvc(db, remote).pull();

    final result2 = await _makeSvc(db, remote).pull();

    expect(result2.imported, 0);
    // Unchanged server row → no re-write (prevents the dbRevision churn that
    // flickered the UI every sync cycle).
    expect(result2.updated, 0);
    expect(await db.count('transactions'), 1);
  });

  test('local transaction matched by source_payload_id gets server_id attached',
      () async {
    const payloadId = 'payload-abc-123';
    final svc = _makeSvc(db, remote);

    // Simulate a row that was already imported by CaptureSyncService (relay path):
    // insert a local transaction and mark it in dedup_hashes.
    const localId = 'local-tx-001';
    final now = dateTimeToSql(DateTime.now().toUtc());
    await db.customStatement('''
      INSERT INTO transactions(
        id, amount, currency, type, source,
        occurred_at, raw_message, parse_confidence, status,
        created_at, updated_at
      ) VALUES (
        '$localId', 50.0, 'SAR', 'payment', 'bank',
        '$now', '', 0.9, 'confirmed',
        '$now', '$now'
      );
    ''');
    await DriftDedupStore(db).mark(
      'capture_payload:$payloadId',
      transactionId: localId,
      occurredAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );

    remote.activeRows = [_serverRow(payloadId: payloadId)];
    final result = await svc.pull();

    expect(result.imported, 0);
    expect(result.updated, 1);
    expect(await db.count('transactions'), 1);

    final rows = await db
        .customSelect(
          "SELECT server_id FROM transactions WHERE id = ${sqlString(localId)};",
        )
        .get();
    expect(rows.first.readNullable<String>('server_id'), 'test-server-uuid');
  });

  test('row missing amount is skipped', () async {
    remote.activeRows = [
      {
        'id': 'partial-row',
        'amount': null,
        'currency': 'SAR',
        'occurred_at': '2026-01-01T10:00:00.000Z',
        'type': 'debit',
        'source': 'ios_shortcut',
      }
    ];
    final result = await _makeSvc(db, remote).pull();

    expect(result.imported, 0);
    expect(await db.count('transactions'), 0);
  });

  test('tombstone marks synced local row as ignored', () async {
    // First import the row normally.
    remote.activeRows = [_serverRow()];
    await _makeSvc(db, remote).pull();
    expect(await db.count('transactions'), 1);

    // Move to tombstone.
    remote.activeRows = [];
    final tombstone = _serverRow()..remove('source_payload_id');
    remote.tombstones = [tombstone];
    final result = await _makeSvc(db, remote).pull();

    expect(result.tombstoned, 1);
    final rows =
        await db.customSelect('SELECT status FROM transactions;').get();
    expect(rows.first.read<String>('status'), 'ignored');
  });

  test('row with conflict sync_status is counted as conflict, not overwritten',
      () async {
    // Import and then mark as conflict.
    remote.activeRows = [_serverRow()];
    await _makeSvc(db, remote).pull();

    await db.customStatement(
      "UPDATE transactions SET sync_status = 'conflict', amount = 999.0;",
    );

    final result = await _makeSvc(db, remote).pull();

    expect(result.conflicts, 1);
    expect(result.updated, 0);

    final rows =
        await db.customSelect('SELECT amount FROM transactions;').get();
    expect(rows.first.read<double>('amount'), 999.0);
  });

  test('re-pulling an unchanged row is a no-op (no flicker churn)', () async {
    remote.activeRows = [
      _serverRow(id: 'srv-1', updatedAt: '2026-01-01T10:00:00.000Z'),
    ];
    final first = await _makeSvc(db, remote).pull();
    expect(first.imported, 1);

    final syncedAtBefore = (await db
            .customSelect('SELECT synced_at FROM transactions LIMIT 1;')
            .getSingle())
        .readNullable<String>('synced_at');

    // Second pull, identical server state → must NOT re-write the row.
    final second = await _makeSvc(db, remote).pull();
    expect(second.imported, 0);
    expect(second.updated, 0, reason: 'unchanged row must not be re-written');

    final syncedAtAfter = (await db
            .customSelect('SELECT synced_at FROM transactions LIMIT 1;')
            .getSingle())
        .readNullable<String>('synced_at');
    expect(syncedAtAfter, syncedAtBefore,
        reason: 'synced_at must not move when nothing changed');
  });

  test('import resolves the account via server_account_id, not the stale '
      'local_account_id from another install', () async {
    // The seeded sentinel default account, as the accounts pull leaves it:
    // attached server_id.
    await db.customStatement(
      "UPDATE accounts SET server_id = 'SRV-ACC-1' "
      "WHERE id = 'default_account';",
    );
    final row = _serverRow(id: 'srv-1');
    row['server_account_id'] = 'SRV-ACC-1';
    row['local_account_id'] = 'hBNX-stale-old-install'; // dead local id
    remote.activeRows = [row];

    final result = await _makeSvc(db, remote).pull();
    expect(result.imported, 1);

    final imported = await db
        .customSelect("SELECT account_id FROM transactions LIMIT 1;")
        .getSingle();
    expect(imported.readNullable<String>('account_id'), 'default_account',
        reason: 'must link via server_account_id → accounts.server_id');
  });

  test('import with an unresolvable account falls back to the default '
      'account, never a dead dangling id', () async {
    final row = _serverRow(id: 'srv-1');
    row['local_account_id'] = 'dead-local-id'; // from a wiped install
    remote.activeRows = [row];

    await _makeSvc(db, remote).pull();

    final imported = await db
        .customSelect("SELECT account_id FROM transactions LIMIT 1;")
        .getSingle();
    // The resolver returns null for a dead id; saveTransaction then applies
    // its default-account policy — the row stays VISIBLE. What must never
    // happen is importing the dead id verbatim (hidden from every screen).
    expect(imported.readNullable<String>('account_id'), isNot('dead-local-id'));
    expect(imported.readNullable<String>('account_id'), 'default_account');
  });

  test('re-pull repairs an already-imported row whose account id no longer '
      'exists (post sign-out wipe)', () async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    await db.customStatement(
      "UPDATE accounts SET server_id = 'SRV-ACC-1' "
      "WHERE id = 'default_account';",
    );
    // Orphaned import from before the fix: synced, matching server metadata
    // (so the no-op guard would normally skip it), but pointing at a dead id.
    await db.customStatement(
      "INSERT INTO transactions(id, amount, currency, type, source, "
      "occurred_at, raw_message, parse_confidence, status, created_at, "
      "updated_at, server_id, sync_status, server_updated_at, account_id) "
      "VALUES ('local-1', 100.0, 'SAR', 'payment', 'bank', "
      "'2026-01-01T10:00:00.000Z', '', 0.9, 'confirmed', '$now', '$now', "
      "'srv-1', 'synced', '2026-01-01T10:00:00.000Z', 'hBNX-dead-id');",
    );
    final row = _serverRow(id: 'srv-1', updatedAt: '2026-01-01T10:00:00.000Z');
    row['server_account_id'] = 'SRV-ACC-1';
    remote.activeRows = [row];

    final result = await _makeSvc(db, remote).pull();
    expect(result.updated, 1,
        reason: 'account repair must override the unchanged-row skip');

    final repaired = await db
        .customSelect(
            "SELECT account_id FROM transactions WHERE id = 'local-1';")
        .getSingle();
    expect(repaired.readNullable<String>('account_id'), 'default_account');
  });

  test('re-pulling a row with a newer updated_at does update', () async {
    remote.activeRows = [
      _serverRow(id: 'srv-1', updatedAt: '2026-01-01T10:00:00.000Z'),
    ];
    await _makeSvc(db, remote).pull();

    remote.activeRows = [
      _serverRow(
        id: 'srv-1',
        updatedAt: '2026-01-02T10:00:00.000Z',
        merchant: 'CHANGED',
      ),
    ];
    final result = await _makeSvc(db, remote).pull();
    expect(result.updated, 1);
  });
}
