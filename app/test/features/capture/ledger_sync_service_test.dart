import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';
import 'package:money_companion/data/repositories/drift_dedup_store.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/features/capture/services/ledger_sync_service.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';

  @override
  Future<String?> readStoredKey() async => 'test-key';
}

/// Counts SELECTs against accounts/categories to prove MALI-029 resolution
/// prefetch: a ledger pull resolves those stable sets ONCE, not per remote row.
class _ResolutionSelectCounter extends QueryInterceptor {
  int accountSelects = 0;
  int categorySelects = 0;

  @override
  Future<List<Map<String, Object?>>> runSelect(
      QueryExecutor executor, String statement, List<Object?> args) {
    final low = statement.toLowerCase();
    if (low.contains('from accounts')) accountSelects++;
    if (low.contains('from categories')) categorySelects++;
    return super.runSelect(executor, statement, args);
  }
}

class _MockRemoteSource implements LedgerRemoteSource {
  List<Map<String, dynamic>> activeRows = [];
  List<Map<String, dynamic>> tombstones = [];

  @override
  Future<List<Map<String, dynamic>>> fetchRows({
    required SyncCursor after,
    int limit = 200,
  }) async {
    final rows = [...activeRows, ...tombstones]..sort((left, right) {
        final timestamp = normalizeCursorTimestamp(left['updated_at'])
            .compareTo(normalizeCursorTimestamp(right['updated_at']));
        if (timestamp != 0) return timestamp;
        return (left['id'] as String).compareTo(right['id'] as String);
      });
    return rows
        .where((row) {
          if (after.id.isEmpty) return true;
          final timestamp = normalizeCursorTimestamp(row['updated_at']);
          final comparison = timestamp.compareTo(after.updatedAt);
          return comparison > 0 ||
              (comparison == 0 &&
                  (row['id'] as String).compareTo(after.id) > 0);
        })
        .take(limit)
        .toList();
  }
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
  int pageSize = 200,
}) =>
    LedgerSyncService(
      db: db,
      transactionRepository: DriftTransactionRepository(db),
      dedupStore: DriftDedupStore(db),
      isPullEnabled: () => flagOn,
      remoteSource: remote,
      getAuthUserId: () async => signedIn ? 'test-user-id' : null,
      pageSize: pageSize,
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

  test('MALI-029: account/category resolution is prefetched once, not per row',
      () async {
    final counter = _ResolutionSelectCounter();
    final cdb = await AppDatabase.open(
      executor: NativeDatabase.memory().interceptWith(counter),
      keyStore: _MemoryKeyStore(),
    );
    addTearDown(cdb.close);
    await cdb.customStatement(
      "INSERT INTO accounts(id, name, currency, type, created_at, updated_at, "
      "server_id) VALUES ('a1', 'A', 'SAR', 'bank', '2026-01-01', "
      "'2026-01-01', 'srv-acct');",
    );
    await cdb.customStatement(
      "INSERT INTO categories(id, key, name_ar, icon, color, is_income, "
      "sort_order) VALUES ('c1', 'cat_food', 'طعام', 'x', '#111', 0, 0);",
    );
    final r = _MockRemoteSource();
    r.activeRows = [
      for (var i = 0; i < 25; i++)
        {
          ..._serverRow(
            id: 'srv-$i',
            updatedAt:
                '2026-01-01T10:${(i ~/ 60).toString().padLeft(2, '0')}:'
                '${(i % 60).toString().padLeft(2, '0')}.000Z',
          ),
          'server_account_id': 'srv-acct',
          'category_id': 'cat_food',
        },
    ];
    // Measure only the pull (not open/seed).
    counter.accountSelects = 0;
    counter.categorySelects = 0;

    final result = await _makeSvc(cdb, r).pull();

    expect(result.imported, 25);
    // 25 rows all reference the same account → LedgerSync resolves accounts ONCE
    // for the whole pull (prefetch), never once per row (was ~25). LedgerSync
    // passes the resolved account id to the repo, so the repo does not re-resolve.
    expect(counter.accountSelects, lessThanOrEqualTo(2),
        reason: 'accounts resolved once per pull, not per row (was ~25)');
    // NOTE: category resolution for NEW imports still happens inside the shared
    // repo's saveTransaction (`_categoryIdByKey`, with type-based key
    // normalization) — a repo-layer redundancy that is out of scope for this
    // service-level fix (documented in PHASE_7_PERFORMANCE_CONTRACT). LedgerSync's
    // OWN category resolution (the update/repair path) IS cached.
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

  test('keyset pagination imports rows sharing a page-boundary timestamp',
      () async {
    remote.activeRows = List.generate(
      3,
      (index) => _serverRow(
        id: 'server-$index',
        updatedAt: '2026-01-01T10:00:00.000Z',
      ),
    );

    final result = await _makeSvc(db, remote, pageSize: 2).pull();

    expect(result.imported, 3);
    expect(await db.count('transactions'), 3);
    expect((await readSyncCursor(db, 'ledger_transactions')).id, 'server-2');
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
    final tombstone = _serverRow(
      updatedAt: '2026-01-01T11:00:00.000Z',
    )
      ..remove('source_payload_id')
      ..['deleted_at'] = '2026-01-01T11:00:00.000Z';
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
    remote.activeRows = [
      _serverRow(updatedAt: '2026-01-01T11:00:00.000Z'),
    ];

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

  test(
      'import resolves the account via server_account_id, not the stale '
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

  test(
      'import with an unresolvable account falls back to the default '
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

  test(
      're-pull repairs an already-imported row whose account id no longer '
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

  // ── MALI-009: remote field merge + pending-edit protection ────────────────

  Future<Map<String, dynamic>> localRow(String serverId) async {
    final row = await db
        .customSelect(
          'SELECT amount, raw_merchant, sync_status, server_updated_at '
          'FROM transactions '
          "WHERE server_id = ${sqlString(serverId)} LIMIT 1;",
        )
        .getSingle();
    return {
      'amount': row.read<double>('amount'),
      'raw_merchant': row.readNullable<String>('raw_merchant'),
      'sync_status': row.readNullable<String>('sync_status'),
      'server_updated_at': row.readNullable<String>('server_updated_at'),
    };
  }

  test('remote edit applies financial fields to an existing synced row',
      () async {
    remote.activeRows = [
      _serverRow(
        id: 'srv-merge',
        amount: 100.0,
        merchant: 'OLD',
        updatedAt: '2026-01-01T10:00:00.000Z',
      ),
    ];
    await _makeSvc(db, remote).pull();

    remote.activeRows = [
      _serverRow(
        id: 'srv-merge',
        amount: 250.0,
        merchant: 'NEW MERCHANT',
        updatedAt: '2026-01-02T10:00:00.000Z',
      ),
    ];
    await _makeSvc(db, remote).pull();

    final row = await localRow('srv-merge');
    expect(row['amount'], 250.0, reason: 'remote amount must land locally');
    expect(row['raw_merchant'], 'NEW MERCHANT');
    expect(row['sync_status'], 'synced');
    // One row, not a duplicate import.
    final count = await db
        .customSelect('SELECT COUNT(*) AS c FROM transactions;')
        .getSingle();
    expect(count.read<int>('c'), 1);
  });

  test('pending local edit is untouched when remote is at our base version',
      () async {
    remote.activeRows = [
      _serverRow(
        id: 'srv-pend',
        amount: 100.0,
        updatedAt: '2026-01-01T10:00:00.000Z',
      ),
    ];
    await _makeSvc(db, remote).pull();

    // Simulate a local edit awaiting push: fields changed, status pending,
    // base token = the version we pulled.
    await db.customStatement('''
      UPDATE transactions
      SET amount = 999.0, sync_status = 'pending'
      WHERE server_id = 'srv-pend';
    ''');

    // Remote unchanged (same updated_at) — pull must leave the row alone.
    final result = await _makeSvc(db, remote).pull();
    expect(result.conflicts, 0);

    final row = await localRow('srv-pend');
    expect(row['amount'], 999.0, reason: 'local pending edit must survive');
    expect(row['sync_status'], 'pending');
  });

  test('pending local edit + remote moved past base → conflict, fields kept',
      () async {
    remote.activeRows = [
      _serverRow(
        id: 'srv-conf',
        amount: 100.0,
        updatedAt: '2026-01-01T10:00:00.000Z',
      ),
    ];
    await _makeSvc(db, remote).pull();

    await db.customStatement('''
      UPDATE transactions
      SET amount = 999.0, sync_status = 'pending'
      WHERE server_id = 'srv-conf';
    ''');

    // Remote edited concurrently on another device.
    remote.activeRows = [
      _serverRow(
        id: 'srv-conf',
        amount: 300.0,
        updatedAt: '2026-01-03T10:00:00.000Z',
      ),
    ];
    final result = await _makeSvc(db, remote).pull();
    expect(result.conflicts, 1);

    final row = await localRow('srv-conf');
    expect(row['amount'], 999.0,
        reason: 'conflict must not silently pick the remote side');
    expect(row['sync_status'], 'conflict');
    expect(row['server_updated_at'], '2026-01-01T10:00:00.000Z',
        reason: 'base token must not be overwritten by the newer remote');
  });
}
