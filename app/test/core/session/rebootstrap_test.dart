import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/rebootstrap_service.dart';
import 'package:money_companion/core/session/replica_recovery.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/replica_store.dart';
import 'package:money_companion/data/sync/seq_pull.dart';
import 'package:money_companion/data/sync/server_capabilities.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:path/path.dart' as p;

import 'fake_account_scope.dart';

// WP-7 / manifest §4.10: rebootstrap phases, recovery merge, purge, retention,
// capability gate. Real encrypted replica files in a temp directory.

class _Crash extends Error {}

const _uid = 'uid-aaaa';

class _Lookup implements LedgerServerLookup {
  Map<String, Map<String, dynamic>> rows = {};
  @override
  Future<Map<String, Map<String, dynamic>>> byClientRequestId(
          Set<String> ids) async =>
      {for (final e in rows.entries) if (ids.contains(e.key)) e.key: e.value};
}

class _Capture implements RebootstrapCaptureControl {
  Set<String> deferred = {};
  int holds = 0;
  Set<String>? resumed;
  @override
  Future<void> hold() async => holds++;
  @override
  Set<String> get deferredCaptureIds => deferred;
  @override
  Future<void> resume(Set<String> committed) async => resumed = committed;
}

Future<void> _tx(AppDatabase db, String id,
    {String? serverId,
    String sync = 'pending',
    String status = 'confirmed',
    double amount = 10,
    int? revision}) async {
  await db.customStatement(
    'INSERT INTO transactions(id, amount, amount_minor, currency, type, source, '
    'occurred_at, raw_message, parse_confidence, status, created_at, updated_at, '
    'server_id, sync_status, server_revision, direction) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
    [
      id, amount, (amount * 100).round(), 'SAR', 'payment', 'manual',
      '2026-10-01T00:00:00.000Z', '', 1.0, status, '2026-10-01T00:00:00.000Z',
      '2026-10-01T00:00:00.000Z', serverId, sync, revision, 'debit',
    ],
  );
}

Future<void> _op(AppDatabase db, String txId, String op, {int? base}) =>
    db.customStatement(
      'INSERT INTO ledger_sync_outbox(id, transaction_id, operation, payload_json, '
      'created_at, updated_at, operation_id, base_revision) VALUES (?, ?, ?, ?, ?, ?, ?, ?);',
      ['op-$txId', txId, op, '{"local_id":"$txId"}', '2026-10-01T00:00:00.000Z',
        '2026-10-01T00:00:00.000Z', 'opid-$txId', base],
    );

Future<void> _receipt(AppDatabase db, String id) => db.customStatement(
      'INSERT INTO dedup_hashes(hash, transaction_id, occurred_at, saved_at) '
      "VALUES (?, ?, '1970-01-01T00:00:00.000Z', '2026-10-01T00:00:00.000Z');",
      ['capture_payload:$id', id],
    );

Future<List<Map<String, Object?>>> _q(AppDatabase db, String sql) async =>
    [for (final r in await db.customSelect(sql).get()) r.data];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory support;
  late ReplicaStore store;
  late _Lookup lookup;
  late _Capture capture;
  late FakeAccountScope scope;
  late List<String> removed;
  var clock = DateTime.utc(2026, 10, 1);

  ReplicaStore mkStore() => ReplicaStore(
        appSupportDirectory: support.path,
        now: () => clock,
        readOwnerMarker: () async => _uid,
      );

  /// What the "server pull" puts in the fresh replica.
  Future<void> pull(AppDatabase fresh, String uid) async {
    await _tx(fresh, 's3', serverId: 'srv3', sync: 'synced', amount: 99, revision: 5);
    await _tx(fresh, 'c4', serverId: 'srv4', sync: 'synced', amount: 40, revision: 1);
    await fresh.customStatement(
        "INSERT INTO sync_cursors(entity, last_updated_at, last_id) VALUES ('fresh-marker','x','1');");
    await writeRecordedSyncEpoch(fresh, uid, 'epoch-2', 'reset');
  }

  RebootstrapService mkService({
    Future<void> Function(String phase)? crash,
    Future<void> Function(AppDatabase, String)? bootstrap,
  }) =>
      RebootstrapService(
        store: store,
        capture: capture,
        scope: scope,
        lookup: lookup,
        bootstrapFresh: bootstrap ?? pull,
        removeData: (uid) async {
          removed.add(uid);
          await store.remove(uid);
        },
        freeze: ReplicaFreeze.instance,
        debugAfterPhase: crash,
      );

  Future<AppDatabase> seedOld() async {
    final old = await store.openReplica(_uid);
    await _tx(old, 'c1'); // pending create, cloud never saw it
    await _op(old, 'c1', 'create');
    await _receipt(old, 'c1');
    await _tx(old, 'c2'); // pending create, cloud has a tombstone
    await _op(old, 'c2', 'create');
    await _receipt(old, 'c2');
    await _tx(old, 's3', serverId: 'srv3', amount: 55, revision: 2); // edit
    await _op(old, 's3', 'update', base: 2);
    await _tx(old, 'c4', amount: 40); // create whose twin the server has
    await _op(old, 'c4', 'create');
    await _tx(old, 'clean', serverId: 'srvc', sync: 'synced');
    lookup.rows = {
      'c2': {'id': 'srv2', 'client_request_id': 'c2', 'deleted_at': '2026-10-02T00:00:00Z', 'revision': 3},
    };
    return old;
  }

  setUp(() {
    support = Directory.systemTemp.createTempSync('rebootstrap_test_');
    FlutterSecureStorage.setMockInitialValues({});
    clock = DateTime.utc(2026, 10, 1);
    store = mkStore();
    lookup = _Lookup();
    capture = _Capture();
    scope = FakeAccountScope();
    removed = [];
    ReplicaFreeze.instance.thaw();
  });

  tearDown(() async {
    await store.closeAll();
    ReplicaFreeze.instance.thaw();
    if (support.existsSync()) support.deleteSync(recursive: true);
  });

  Future<void> expectRecovered() async {
    final db = await store.openReplica(_uid);
    // The swapped-in replica is the pulled one.
    expect(await _q(db, "SELECT 1 FROM sync_cursors WHERE entity='fresh-marker'"),
        isNotEmpty);
    final tx = {
      for (final r in await _q(db, 'SELECT id, status, sync_status, amount, server_revision FROM transactions'))
        r['id']: r,
    };
    // c1: recreated, pending, still has its receipt and exactly one new op.
    expect(tx['c1']!['sync_status'], 'pending');
    expect(tx['c1']!['status'], 'confirmed');
    // c2: tombstone wins: ignored conflict, never active, no op.
    expect(tx['c2']!['status'], 'ignored');
    expect(tx['c2']!['sync_status'], 'conflict');
    expect(await _q(db, "SELECT 1 FROM ledger_sync_outbox WHERE transaction_id='c2'"), isEmpty);
    final conflict = await _q(db, "SELECT kind, mine_json FROM sync_conflicts WHERE local_id='c2' AND resolved_at IS NULL");
    expect(conflict, hasLength(1));
    expect(conflict.single['kind'], 'tombstone');
    expect(conflict.single['mine_json'], contains('"status":"confirmed"'));
    // s3: the local edit replaced the pulled copy and keeps its OLD base.
    expect(tx['s3']!['amount'], 55);
    expect(tx['s3']!['server_revision'], 2);
    // c4: equal fields -> adopted: pulled row kept, no op.
    expect(tx['c4']!['sync_status'], 'synced');
    expect(await _q(db, "SELECT 1 FROM ledger_sync_outbox WHERE transaction_id='c4'"), isEmpty);
    // Ops: replayed as NEW operations, one per pending tx, old op id remembered.
    final ops = await _q(db, 'SELECT transaction_id, operation, id, operation_id, base_revision, payload_json FROM ledger_sync_outbox ORDER BY transaction_id');
    expect(ops.map((o) => o['transaction_id']), ['c1', 's3']);
    expect(ops.every((o) => o['id'] != 'op-${o['transaction_id']}'), isTrue);
    expect(ops.last['base_revision'], 2);
    expect(ops.last['payload_json'], contains('opid-s3'));
    // Receipts recovered.
    expect(
        (await _q(db, "SELECT hash FROM dedup_hashes WHERE hash LIKE 'capture_payload:%'")).length,
        2);
  }

  test('full rebootstrap recovers receipts, merges by client_request_id and swaps',
      () async {
    await seedOld();
    capture.deferred = {'c1', 'never-committed'};
    final out = await mkService().run(_uid, reason: 'reset');
    expect(out, RebootstrapOutcome.completed);
    await expectRecovered();
    expect(scope.calls, containsAllInOrder(['suspendForSwap', 'activate:$_uid']));
    // A14: only the deferred id whose committed receipt is in the new replica
    // crosses the barrier.
    expect(capture.resumed, {'c1'});
    expect(ReplicaFreeze.instance.frozen, isFalse);
    expect(await store.rebootstrapMarker(_uid), isNull);
  });

  group('crash at every phase resumes from the registry marker', () {
    final phases = [
      for (final ph in RebootstrapPhase.values)
        if (ph != RebootstrapPhase.captureResumed) ph.wire,
      'capture_resumed',
    ];
    for (final crashAt in phases) {
      test('crash after $crashAt', () async {
        await seedOld();
        var crashed = false;
        final crashing = mkService(crash: (ph) async {
          if (ph == crashAt && !crashed) {
            crashed = true;
            throw _Crash();
          }
        });
        try {
          await crashing.run(_uid, reason: 'reset');
        } on _Crash {
          // the 'frozen' tick is outside the guarded section
        }
        // New process: a new store and a new service read the marker.
        await store.closeAll();
        store = mkStore();
        final out = await mkService().run(_uid);
        expect(out, anyOf(RebootstrapOutcome.completed, RebootstrapOutcome.notNeeded));
        await expectRecovered();
        expect(await store.rebootstrapMarker(_uid), isNull);
      });
    }
  });

  test('capture stays frozen and the replica unreachable until swapped committed',
      () async {
    await seedOld();
    final seen = <String, (bool, bool)>{};
    await mkService(crash: (ph) async {
      seen[ph] = (
        ReplicaFreeze.instance.frozen,
        (await store.activeLocation()) == null,
      );
    }).run(_uid, reason: 'reset');
    for (final ph in [
      'frozen', 'extracted', 'fresh_bootstrapped', 'receipts_recovered',
      'pulled_merged', 'outbox_recovered', 'conflicts_merged',
    ]) {
      expect(seen[ph], (true, true), reason: ph);
    }
    expect(seen['swapped']!.$1, isTrue, reason: 'still frozen until capture_resumed');
    expect(seen['swapped']!.$2, isFalse);
    expect(seen['capture_resumed']!.$1, isFalse);
  });

  test('a failed server pull keeps the old replica and resumes later', () async {
    await seedOld();
    var fail = true;
    final svc = mkService(bootstrap: (f, u) async {
      if (fail) throw StateError('offline');
      await pull(f, u);
    });
    expect(await svc.run(_uid, reason: 'reset'), RebootstrapOutcome.retryLater);
    expect(
        (await store.rebootstrapMarker(_uid))!.phase, RebootstrapPhase.extracted);
    expect(ReplicaFreeze.instance.frozen, isTrue);
    fail = false;
    expect(await svc.run(_uid), RebootstrapOutcome.completed);
    await expectRecovered();
  });

  test('epoch_reason purge: no replay, no staging, uid data removed', () async {
    await seedOld();
    capture.deferred = {'c1'};
    final out = await mkService().run(_uid, reason: 'purge');
    expect(out, RebootstrapOutcome.purged);
    expect(removed, [_uid]);
    expect(capture.resumed, isEmpty);
    final h = await store.uidHash(_uid);
    expect(Directory(p.join(support.path, 'replicas', h)).existsSync(), isFalse);
    expect(Directory(p.join(support.path, 'replicas', '$h.rb')).existsSync(), isFalse);
    expect(await store.list(), isEmpty);
    expect(ReplicaFreeze.instance.frozen, isFalse);
  });

  test('the old replica is kept 14 days after the swap, then purged', () async {
    await seedOld();
    await mkService().run(_uid, reason: 'reset');
    final h = await store.uidHash(_uid);
    final old = Directory(p.join(support.path, 'replicas', '$h.old'));
    const storage = FlutterSecureStorage();
    expect(old.existsSync(), isTrue);
    expect(await storage.read(key: 'qirsh.db_key.$h.old'), isNotNull);
    clock = DateTime.utc(2026, 10, 14, 23);
    await store.purgeExpiredRetired();
    expect(old.existsSync(), isTrue, reason: 'still inside 14 days');
    clock = DateTime.utc(2026, 10, 15, 1);
    await store.purgeExpiredRetired();
    expect(old.existsSync(), isFalse);
    expect(await storage.read(key: 'qirsh.db_key.$h.old'), isNull);
  });

  test('Remove data deletes the retained old replica and its key too', () async {
    await seedOld();
    await mkService().run(_uid, reason: 'reset');
    final h = await store.uidHash(_uid);
    await store.remove(_uid);
    expect(Directory(p.join(support.path, 'replicas', '$h.old')).existsSync(), isFalse);
    expect(await const FlutterSecureStorage().read(key: 'qirsh.db_key.$h.old'), isNull);
    expect(await store.list(), isEmpty);
  });

  test('capability false (or unknown) keeps the typed stop: nothing starts', () async {
    await seedOld();
    var ran = 0;
    final svc = mkService(bootstrap: (f, u) async {
      ran++;
    });
    for (final cap in [ServerCapabilityState.unsupported, ServerCapabilityState.unknown]) {
      final t = EpochRebootstrapTrigger(
        store: store,
        service: svc,
        capability: () async => cap,
        remote: _Remote('epoch-2'),
        recordedEpoch: (_) async => const RecordedSyncEpoch('epoch-1', 'initial'),
      );
      expect(await t.check(_uid), RebootstrapOutcome.notNeeded);
    }
    expect(ran, 0);
    expect(await store.rebootstrapMarker(_uid), isNull);
  });

  test('capability verified + epoch mismatch starts with the server reason', () async {
    await seedOld();
    final t = EpochRebootstrapTrigger(
      store: store,
      service: mkService(),
      capability: () async => ServerCapabilityState.verified,
      remote: _Remote('epoch-2', reason: 'restore'),
      recordedEpoch: (_) async => const RecordedSyncEpoch('epoch-1', 'initial'),
    );
    expect(await t.check(_uid), RebootstrapOutcome.completed);
  });

  test('unplaceable item blocks the swap and leaves the old replica', () async {
    final old = await seedOld();
    // A budget whose required category cannot be found anywhere.
    await old.customStatement('PRAGMA foreign_keys = OFF;');
    await old.customStatement(
        "INSERT INTO budgets(id, category_id, amount, period, start_date, is_active, sync_status) "
        "VALUES ('b1','missing-cat',5,'monthly','2026-10-01',1,'pending');");
    expect(await mkService().run(_uid, reason: 'reset'), RebootstrapOutcome.blocked);
    final h = await store.uidHash(_uid);
    expect((await store.rebootstrapMarker(_uid))!.phase.index,
        lessThan(RebootstrapPhase.swapped.index));
    expect(Directory(p.join(support.path, 'replicas', '$h.old')).existsSync(), isFalse);
    expect(await _q(await store.openReplica(_uid), "SELECT 1 FROM transactions WHERE id='c1'"), isNotEmpty);
  });

  group('swap crash safety', () {
    for (final step in kSwapSteps) {
      test('crash after $step', () async {
        await seedOld();
        store = ReplicaStore(
          appSupportDirectory: support.path,
          now: () => clock,
          readOwnerMarker: () async => _uid,
          debugAfterAdoptionStep: (s) async {
            if (s == step) throw _Crash();
          },
        );
        try {
          await mkService().run(_uid, reason: 'reset');
        } catch (_) {}
        // D2: a swap that did not commit puts the account back on a scope.
        expect(scope.calls, containsAllInOrder(['suspendForSwap', 'activate:$_uid']));
        await store.closeAll();
        store = mkStore();
        expect(await mkService().run(_uid), RebootstrapOutcome.completed);
        await expectRecovered();
        final h = await store.uidHash(_uid);
        expect(Directory(p.join(support.path, 'replicas', '$h.old')).existsSync(), isTrue);
        expect(Directory(p.join(support.path, 'replicas', '$h.rb')).existsSync(), isFalse);
      });
    }
  });
}

class _Remote implements SeqRemote {
  _Remote(this.epoch, {this.reason});
  final String epoch;
  final String? reason;
  @override
  Future<SyncHead?> fetchHead(String userId) async =>
      SyncHead(lastSeq: 1, epoch: epoch, epochReason: reason);
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}
