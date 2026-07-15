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
      'payload_id': payloadId,
      'amount': amount,
      'currency': currency,
      'type': type,
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

  test('second pull with same server_id updates metadata, does not duplicate',
      () async {
    remote.activeRows = [_serverRow()];
    await _makeSvc(db, remote).pull();

    final result2 = await _makeSvc(db, remote).pull();

    expect(result2.imported, 0);
    expect(result2.updated, 1);
    expect(await db.count('transactions'), 1);
  });

  test('local transaction matched by payload_id gets server_id attached',
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
    remote.tombstones = [_serverRow()];
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
}
