import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/data/sync/server_capabilities.dart';
import 'package:money_companion/features/capture/services/ledger_outbox_queue.dart';
import 'package:money_companion/features/capture/services/ledger_push_service.dart';

import '../../harness/fake_cas_server.dart';

// WP-5 — ledger push through the WP-2 RPCs (capability `revision_cas`):
// CAS on the edit's base revision, lost-ACK receipt, durable conflicts,
// insert-if-absent, tombstone-first. Production capability is false until G4.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

const _table = 'user_transactions';

void main() {
  late AppDatabase db;
  late FakeCasServer srv;

  setUp(() async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    srv = FakeCasServer();
  });
  tearDown(() => db.close());

  LedgerOutboxQueue queueOf(AppDatabase d) => LedgerOutboxQueue(
        db: d,
        isPushEnabled: () => true,
        getAuthUserId: () async => 'user-1',
      );

  LedgerPushService pushOf(AppDatabase d, FakeCasServer s,
          {ServerCapabilityState cap = ServerCapabilityState.verified,
          String epoch = 'e1'}) =>
      LedgerPushService(
        db: d,
        queue: queueOf(d),
        isPushEnabled: () => true,
        getAuthUserId: () async => 'user-1',
        casGate: casGate(d, capability: cap, epoch: epoch),
        casRemote: s,
        mayEgress: () async => true,
      );

  Future<void> insertTx(AppDatabase d, String id,
      {String? serverId,
      int? revision,
      String? token,
      String amount = '100.0',
      String sync = 'synced'}) async {
    final now = dateTimeToSql(DateTime.utc(2026, 8, 1));
    await d.customStatement('''
      INSERT INTO transactions(
        id, amount, currency, type, source, occurred_at, raw_message,
        parse_confidence, status, created_at, updated_at,
        server_id, server_updated_at, server_revision, sync_status
      ) VALUES (
        '$id', $amount, 'SAR', 'payment', 'bank', '$now', '', 0.9, 'confirmed',
        '$now', '$now', ${serverId == null ? 'NULL' : "'$serverId'"},
        ${token == null ? 'NULL' : "'$token'"}, ${revision ?? 'NULL'}, '$sync'
      );
    ''');
    await backfillNonPlanningMoneyV30(d);
  }

  Future<void> edit(AppDatabase d, String id, {String? note, OutboxOperation op = OutboxOperation.update}) async {
    final repo = DriftTransactionRepository(d);
    var tx = (await repo.getById(id))!;
    if (note != null) {
      await d.customStatement("UPDATE transactions SET note = '$note' WHERE id = '$id';");
      tx = tx.copyWith(note: note);
    }
    await queueOf(d).enqueue(op, tx);
  }

  Future<String?> status(AppDatabase d, String id) async => (await d
          .customSelect("SELECT sync_status FROM transactions WHERE id='$id';")
          .getSingle())
      .readNullable<String>('sync_status');
  Future<int?> localRev(AppDatabase d, String id) async => (await d
          .customSelect("SELECT server_revision FROM transactions WHERE id='$id';")
          .getSingle())
      .readNullable<int>('server_revision');
  Future<int> outboxCount(AppDatabase d) async => (await d
          .customSelect('SELECT COUNT(*) AS n FROM ledger_sync_outbox;')
          .getSingle())
      .read<int>('n');
  Future<List<Map<String, dynamic>>> openConflicts(AppDatabase d) async =>
      (await d
              .customSelect(
                  'SELECT * FROM sync_conflicts WHERE resolved_at IS NULL;')
              .get())
          .map((r) => r.data)
          .toList();

  Map<String, dynamic> serverRow(int revision) => srv.seed(
      _table, {'client_request_id': 'tx1', 'amount': 100},
      id: 'srv-tx1', revision: revision);

  group('update (CAS on the edit\'s base revision)', () {
    test('matching revision: applied, op id stamped, new revision stored',
        () async {
      await insertTx(db, 'tx1', serverId: 'srv-tx1', revision: 5, token: '2026-08-01T00:00:00.000Z');
      serverRow(5);
      await edit(db, 'tx1', note: 'mine');
      final r = await pushOf(db, srv).push();
      expect(r.pushed, 1);
      expect(srv.tables[_table]!['srv-tx1']!['revision'], 6);
      expect(srv.tables[_table]!['srv-tx1']!['last_op_id'], isNotNull);
      expect(await status(db, 'tx1'), 'synced');
      expect(await localRev(db, 'tx1'), 6);
      expect(await outboxCount(db), 0);
    });

    test('base_revision column is the base, not a value buried in the payload',
        () async {
      await insertTx(db, 'tx1', serverId: 'srv-tx1', revision: 5, token: '2026-08-01T00:00:00.000Z');
      serverRow(5);
      await edit(db, 'tx1', note: 'mine');
      final row = await db
          .customSelect('SELECT base_revision, operation_id FROM ledger_sync_outbox')
          .getSingle();
      expect(row.read<int>('base_revision'), 5);
      expect(row.read<String>('operation_id'), isNotEmpty);
      // The payload copy is legacy; the column wins.
      await db.customStatement(
          "UPDATE ledger_sync_outbox SET payload_json = REPLACE(payload_json, '\"server_revision\":5', '\"server_revision\":99');");
      expect((await pushOf(db, srv).push()).pushed, 1);
    });

    test('stale revision: durable conflict (mine/theirs), outbox consumed, '
        'cloud untouched', () async {
      await insertTx(db, 'tx1', serverId: 'srv-tx1', revision: 5, token: '2026-08-01T00:00:00.000Z');
      serverRow(5);
      srv.foreignEdit(_table, 'srv-tx1', {'amount': 250});
      await edit(db, 'tx1', note: 'mine');
      final r = await pushOf(db, srv).push();
      expect(r.conflicts, 1);
      expect(r.pushed, 0);
      expect(srv.tables[_table]!['srv-tx1']!['amount'], 250);
      expect(await status(db, 'tx1'), 'conflict');
      expect(await localRev(db, 'tx1'), 5);
      expect(await outboxCount(db), 0);
      final c = (await openConflicts(db)).single;
      expect(c['kind'], 'update');
      expect(c['theirs_revision'], 6);
      expect(c['mine_json'], contains('mine'));
      expect(c['theirs_json'], contains('250'));
    });

    test('lost ACK: the retry carries the same operation id and is ACKed, '
        'never a conflict (crash between push and ACK)', () async {
      await insertTx(db, 'tx1', serverId: 'srv-tx1', revision: 5, token: '2026-08-01T00:00:00.000Z');
      serverRow(5);
      await edit(db, 'tx1', note: 'mine');
      srv.loseNextAck = true;
      final first = await pushOf(db, srv).push();
      expect(first.failed, 1);
      expect(srv.tables[_table]!['srv-tx1']!['revision'], 6,
          reason: 'the write landed on the server');
      // "Restart": fresh service objects, same durable DB. Clear backoff.
      await db.customStatement('UPDATE ledger_sync_outbox SET next_retry_at = NULL;');
      final again = await pushOf(db, srv).push();
      expect(again.pushed, 1);
      expect(again.conflicts, 0);
      expect(srv.tables[_table]!['srv-tx1']!['revision'], 6,
          reason: 'applied exactly once');
      expect(await status(db, 'tx1'), 'synced');
      expect(await openConflicts(db), isEmpty);
      expect(await outboxCount(db), 0);
    });

    test('edit after a possibly-sent op: our own earlier write is not a '
        'conflict; the edit is re-based and applied', () async {
      await insertTx(db, 'tx1', serverId: 'srv-tx1', revision: 5, token: '2026-08-01T00:00:00.000Z');
      serverRow(5);
      await edit(db, 'tx1', note: 'first');
      srv.loseNextAck = true;
      await pushOf(db, srv).push(); // lands (rev 6), ACK lost, row stays in flight
      await edit(db, 'tx1', note: 'second'); // coalesces: new op id, same base 5
      await db.customStatement('UPDATE ledger_sync_outbox SET next_retry_at = NULL;');
      final r = await pushOf(db, srv).push();
      expect(r.pushed, 1);
      expect(r.conflicts, 0);
      expect(srv.tables[_table]!['srv-tx1']!['revision'], 7);
      expect(srv.tables[_table]!['srv-tx1']!['description'], 'second');
    });

    test('T7 edit while the push is in flight: the ACK re-bases the folded '
        'edit, which is then pushed as an update against the NEW revision',
        () async {
      await insertTx(db, 'tx1', serverId: 'srv-tx1', revision: 5, token: '2026-08-01T00:00:00.000Z');
      serverRow(5);
      await edit(db, 'tx1', note: 'first');
      srv.onWire = () async {
        srv.onWire = null;
        await edit(db, 'tx1', note: 'second'); // coalesces into the same row
      };
      final r1 = await pushOf(db, srv).push();
      expect(r1.pushed, 1);
      expect(srv.tables[_table]!['srv-tx1']!['revision'], 6);
      expect(await status(db, 'tx1'), 'pending', reason: 'the folded edit is still queued');
      expect(await localRev(db, 'tx1'), 6);
      expect(
          (await db.customSelect('SELECT base_revision AS b FROM ledger_sync_outbox').getSingle())
              .read<int>('b'),
          6);
      await db.customStatement('UPDATE ledger_sync_outbox SET next_retry_at = NULL;');
      final r2 = await pushOf(db, srv).push();
      expect(r2.pushed, 1);
      expect(r2.conflicts, 0);
      expect(srv.tables[_table]!['srv-tx1']!['revision'], 7);
      expect(srv.tables[_table]!['srv-tx1']!['description'], 'second');
      expect(await status(db, 'tx1'), 'synced');
    });

    test('row absent in the cloud (not_found): re-created by identity', () async {
      await insertTx(db, 'tx1', serverId: 'srv-gone', revision: 5, token: '2026-08-01T00:00:00.000Z');
      await edit(db, 'tx1', note: 'mine');
      final r = await pushOf(db, srv).push();
      expect(r.pushed, 1);
      expect(srv.calls, ['update:$_table', 'insert:$_table']);
      expect(await outboxCount(db), 0);
    });

    test('no explicit base revision (queued before WP-5): resolved from the '
        'legacy token only when the cloud row is unchanged; else conflict', () async {
      await insertTx(db, 'tx1', serverId: 'srv-tx1', token: '2026-09-01T00:00:00.000Z');
      serverRow(5);
      await edit(db, 'tx1', note: 'mine');
      expect((await pushOf(db, srv).push()).pushed, 1);

      final db2 = await AppDatabase.open(
          executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
      addTearDown(db2.close);
      final srv2 = FakeCasServer();
      srv2.seed(_table, {'client_request_id': 'tx1'}, id: 'srv-tx1', revision: 5);
      await insertTx(db2, 'tx1', serverId: 'srv-tx1', token: '2026-07-01T00:00:00.000Z');
      await edit(db2, 'tx1', note: 'mine');
      final r = await pushOf(db2, srv2).push();
      expect(r.conflicts, 1, reason: 'token differs: the cloud moved; never blind');
    });
  });

  group('delete (CAS tombstone)', () {
    test('applied once; a replay on the tombstoned row is an ACK', () async {
      await insertTx(db, 'tx1', serverId: 'srv-tx1', revision: 5, token: '2026-08-01T00:00:00.000Z');
      serverRow(5);
      await edit(db, 'tx1', op: OutboxOperation.delete);
      expect((await pushOf(db, srv).push()).pushed, 1);
      expect(srv.tables[_table]!['srv-tx1']!['deleted_at'], isNotNull);
    });

    test('remote tombstone vs local EDIT (B7): a conflict, never an undelete',
        () async {
      await insertTx(db, 'tx1', serverId: 'srv-tx1', revision: 5, token: '2026-08-01T00:00:00.000Z');
      serverRow(5);
      srv.foreignTombstone(_table, 'srv-tx1');
      await edit(db, 'tx1', note: 'mine');
      final r = await pushOf(db, srv).push();
      expect(r.conflicts, 1);
      expect(srv.tables[_table]!['srv-tx1']!['deleted_at'], isNotNull,
          reason: 'the tombstone is never cleared');
      expect((await openConflicts(db)).single['kind'], 'tombstone');
    });
  });

  group('create (insert-if-absent)', () {
    test('absent: inserted; a lost-ACK retry is an ACK (one row)', () async {
      await insertTx(db, 'tx2', sync: 'pending');
      await edit(db, 'tx2', op: OutboxOperation.create);
      srv.loseNextAck = true;
      await pushOf(db, srv).push();
      await db.customStatement('UPDATE ledger_sync_outbox SET next_retry_at = NULL;');
      final r = await pushOf(db, srv).push();
      expect(r.pushed, 1);
      expect(srv.tables[_table]!.length, 1);
      expect(await status(db, 'tx2'), 'synced');
      expect(await openConflicts(db), isEmpty);
    });

    test('same identity, foreign op, equal fields: adopted; different fields: '
        'conflict (never overwritten)', () async {
      Future<AppDatabase> device() async {
        final d = await AppDatabase.open(
            executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
        addTearDown(d.close);
        return d;
      }

      final a = await device();
      await insertTx(a, 'txc', sync: 'pending');
      await edit(a, 'txc', op: OutboxOperation.create);
      expect((await pushOf(a, srv).push()).pushed, 1);

      final b = await device();
      await insertTx(b, 'txc', sync: 'pending');
      await edit(b, 'txc', op: OutboxOperation.create);
      expect((await pushOf(b, srv).push()).pushed, 1,
          reason: 'equal fields → adopt the cloud row');
      expect(await status(b, 'txc'), 'synced');
      expect(srv.tables[_table]!.length, 1);

      final c = await device();
      await insertTx(c, 'txc', sync: 'pending', amount: '999.0');
      await edit(c, 'txc', op: OutboxOperation.create);
      final r = await pushOf(c, srv).push();
      expect(r.conflicts, 1);
      expect(srv.tables[_table]!.values.single['amount'], isNot(999));
      expect((await openConflicts(c)).single['kind'], 'create');
    });

    test('same identity but a tombstone: conflict, never undeleted', () async {
      srv.seed(_table, {'client_request_id': 'tx3', 'amount': 100},
          id: 'srv-3', revision: 2, deletedAt: '2026-08-02T00:00:00.000Z');
      await insertTx(db, 'tx3', sync: 'pending');
      await edit(db, 'tx3', op: OutboxOperation.create);
      final r = await pushOf(db, srv).push();
      expect(r.conflicts, 1);
      expect(srv.tables[_table]!['srv-3']!['deleted_at'], isNotNull);
      expect((await openConflicts(db)).single['kind'], 'tombstone');
    });
  });

  group('gating', () {
    test('epoch mismatch: nothing written or consumed, the op stays queued',
        () async {
      await insertTx(db, 'tx1', serverId: 'srv-tx1', revision: 5, token: '2026-08-01T00:00:00.000Z');
      serverRow(5);
      await edit(db, 'tx1', note: 'mine');
      srv.epoch = 'e2';
      final r = await pushOf(db, srv).push();
      expect(r.pushed + r.conflicts + r.failed, 0);
      expect(await outboxCount(db), 1);
      final row = await db
          .customSelect('SELECT status, in_flight_seq FROM ledger_sync_outbox')
          .getSingle();
      expect(row.read<String>('status'), 'pending');
      expect(row.readNullable<int>('in_flight_seq'), isNull);
    });

    test('capability false: the legacy path runs, the RPCs are never called',
        () async {
      await insertTx(db, 'tx1', serverId: 'srv-tx1', revision: 5, token: '2026-08-01T00:00:00.000Z');
      await edit(db, 'tx1', note: 'mine');
      // Legacy would use the Supabase client (unconfigured here → it fails),
      // but the fake CAS server must see no call at all.
      await pushOf(db, srv, cap: ServerCapabilityState.unsupported).push();
      expect(srv.calls, isEmpty);
    });

    test('capability unknown: nothing is sent and nothing is consumed', () async {
      await insertTx(db, 'tx1', serverId: 'srv-tx1', revision: 5, token: '2026-08-01T00:00:00.000Z');
      await edit(db, 'tx1', note: 'mine');
      final r = await pushOf(db, srv, cap: ServerCapabilityState.unknown).push();
      expect(r.pushed + r.failed + r.conflicts, 0);
      expect(srv.calls, isEmpty);
      expect(await outboxCount(db), 1);
    });
  });
}
