import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/sync/outbox_failure.dart';
import 'package:money_companion/core/sync/sync_health.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/data/db/planning_cutover.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/data/sync/exact_transport_capability.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/features/capture/services/ledger_outbox_queue.dart';
import 'package:money_companion/features/capture/services/ledger_push_service.dart';
import 'package:money_companion/features/planning_sync/services/outbox_queue_factory.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A-2 (outbox correctness) — ledger side. Every test here fails on the pre-A-2
/// code: G3 (an edit folded into an in-flight row is lost on ACK), G4 (a lookup
/// error ACKs a remote delete), G15 (a tombstone ACK never settles the entity),
/// G18 (rows are pushed under whoever is signed in), G5 (no intent without a
/// live session), G14 (background queue serialises money differently).
class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

const _tx = 'tx-001';

Future<void> _insertTx(AppDatabase db, {String id = _tx, String? serverId}) async {
  final now = dateTimeToSql(DateTime.now().toUtc());
  final occurred = dateTimeToSql(DateTime.utc(2026, 6, 1, 10));
  await db.customStatement('''
    INSERT INTO transactions(
      id, amount, currency, type, source, occurred_at, raw_message,
      parse_confidence, status, created_at, updated_at, note
      ${serverId == null ? '' : ', server_id'}
    ) VALUES (
      '$id', 100.0, 'SAR', 'payment', 'bank', '$occurred', '', 0.9, 'confirmed',
      '$now', '$now', 'original'
      ${serverId == null ? '' : ", '$serverId'"}
    );
  ''');
  await backfillNonPlanningMoneyV30(db);
}

Future<String> _txStatus(AppDatabase db, [String id = _tx]) async => (await db
        .customSelect("SELECT sync_status AS s FROM transactions WHERE id = '$id';")
        .getSingle())
    .read<String>('s');

Future<List<Map<String, Object?>>> _outbox(AppDatabase db) async => [
      for (final r in await db
          .customSelect('SELECT * FROM ledger_sync_outbox ORDER BY created_at;')
          .get())
        r.data
    ];

typedef _Handler = Future<http.Response> Function(http.Request request);

class _Calls {
  final requests = <http.Request>[];
  int get count => requests.length;
}

SupabaseClient _client(_Calls calls, _Handler handler) => SupabaseClient(
      'https://example.supabase.co',
      'public-anon-key',
      accessToken: () async => 'qa-access-token',
      httpClient: MockClient((request) async {
        calls.requests.add(request);
        return handler(request);
      }),
    );

http.Response _json(Object body, http.Request request) => http.Response(
      jsonEncode(body),
      200,
      headers: const {'content-type': 'application/json'},
      request: request,
    );

LedgerPushService _push(
  AppDatabase db,
  LedgerOutboxQueue queue,
  SupabaseClient client, {
  String? uid = 'user-1',
  PlanningCutoverCoordinator? coordinator,
  ExactTransportCapability Function()? capability,
}) =>
    LedgerPushService(
      db: db,
      queue: queue,
      isPushEnabled: () => true,
      getAuthUserId: () async => uid,
      getClient: () => client,
      mayEgress: () async => true,
      coordinator: coordinator ?? const SchemaV29PlanningCutoverCoordinator(),
      pushCapability: capability ?? () => ExactTransportCapability.unknown,
    );

LedgerOutboxQueue _queue(
  AppDatabase db, {
  Future<String?> Function()? owner,
  String? auth = 'user-1',
  PlanningCutoverCoordinator? coordinator,
}) =>
    LedgerOutboxQueue(
      db: db,
      isPushEnabled: () => true,
      getAuthUserId: () async => auth,
      getOwnerUid: owner,
      coordinator: coordinator ?? const SchemaV29PlanningCutoverCoordinator(),
    );

Future<TransactionEntity> _load(AppDatabase db, [String id = _tx]) async =>
    (await DriftTransactionRepository(db).getById(id))!;

void main() {
  late AppDatabase db;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
  });
  tearDown(() async => db.close());

  group('G3 in-flight edit', () {
    test(
        'an edit folded in while the create is on the wire survives the ACK '
        'and is pushed next cycle as an UPDATE by server id', () async {
      await _insertTx(db);
      final queue = _queue(db);
      await queue.enqueue(OutboxOperation.create, await _load(db));

      var edited = false;
      final calls = _Calls();
      final client = _client(calls, (request) async {
        if (request.method == 'POST' && !edited) {
          // The user edits the note WHILE the create is in flight.
          edited = true;
          await db.customStatement(
              "UPDATE transactions SET note = 'edited in flight' WHERE id = '$_tx';");
          await queue.enqueue(OutboxOperation.update, await _load(db));
          return _json({'id': 'srv-1', 'updated_at': 't1'}, request);
        }
        // Second cycle: guarded UPDATE by server id (PATCH).
        return _json([
          {'updated_at': 't2'}
        ], request);
      });
      final service = _push(db, queue, client);

      final first = await service.push();
      expect(first.pushed, 1);

      // The newer edit is STILL PENDING, carrying the server identity.
      final rows = await _outbox(db);
      expect(rows, hasLength(1), reason: 'the folded edit must not be deleted');
      expect(rows.single['status'], 'pending');
      expect(rows.single['operation'], 'update');
      expect(rows.single['attempt_count'], 0);
      final payload = jsonDecode(rows.single['payload_json'] as String) as Map;
      expect(payload['note'], 'edited in flight');
      expect(payload['server_id'], 'srv-1');
      expect(payload['server_updated_at'], 't1');
      expect(await _txStatus(db), 'pending',
          reason: 'must NOT be marked synced while an edit is unpushed');
      final server = await db
          .customSelect("SELECT server_id FROM transactions WHERE id = '$_tx';")
          .getSingle();
      expect(server.read<String>('server_id'), 'srv-1',
          reason: 'the ACK identity is persisted regardless');

      final second = await service.push();
      expect(second.pushed, 1);
      final patch = calls.requests.last;
      expect(patch.method, 'PATCH');
      expect(patch.url.queryParameters['id'], 'eq.srv-1');
      expect(jsonDecode(patch.body)['description'], 'edited in flight');
      expect(await _outbox(db), isEmpty);
      expect(await _txStatus(db), 'synced');
    });

    test('op_seq increments on every coalesce; an unchanged ACK still settles',
        () async {
      await _insertTx(db);
      final queue = _queue(db);
      await queue.enqueue(OutboxOperation.create, await _load(db));
      await queue.enqueue(OutboxOperation.update, await _load(db));
      await queue.enqueue(OutboxOperation.update, await _load(db));
      expect((await _outbox(db)).single['op_seq'], 3);
    });

    test(
        'a create cancelled by a delete WHILE IN FLIGHT becomes a delete (the '
        'server row that landed is tombstoned, not orphaned)', () async {
      await _insertTx(db);
      final queue = _queue(db);
      await queue.enqueue(OutboxOperation.create, await _load(db));

      var deleted = false;
      final calls = _Calls();
      final client = _client(calls, (request) async {
        if (request.method == 'POST' && !deleted) {
          deleted = true;
          await queue.enqueue(OutboxOperation.delete, await _load(db));
          return _json({'id': 'srv-1', 'updated_at': 't1'}, request);
        }
        return _json([
          {'id': 'srv-1', 'updated_at': 't2'}
        ], request);
      });
      final service = _push(db, queue, client);
      await service.push();

      final rows = await _outbox(db);
      expect(rows.single['operation'], 'delete',
          reason: 'must not be silently dropped');
      await service.push();
      expect(calls.requests.last.method, 'PATCH');
      expect(jsonDecode(calls.requests.last.body)['deleted_at'], isNotNull);
      expect(await _outbox(db), isEmpty);
    });

    test('an offline create+delete that never reached a push is still dropped',
        () async {
      await _insertTx(db);
      final queue = _queue(db);
      await queue.enqueue(OutboxOperation.create, await _load(db));
      await queue.enqueue(OutboxOperation.delete, await _load(db));
      expect(await _outbox(db), isEmpty);
    });
  });

  group('G4 lookup errors never ACK a delete', () {
    test('a network error during the server-id lookup keeps the delete pending',
        () async {
      await _insertTx(db);
      final queue = _queue(db);
      await queue.enqueue(OutboxOperation.delete, await _load(db));

      final calls = _Calls();
      final client = _client(
          calls, (request) async => throw const SocketException('offline'));
      final result = await _push(db, queue, client).push();

      expect(result.failed, 1);
      expect(result.pushed, 0);
      final rows = await _outbox(db);
      expect(rows, hasLength(1), reason: 'NOT ACKed: the remote delete is owed');
      expect(rows.single['status'], 'pending');
      expect(rows.single['attempt_count'], 1, reason: 'the attempt is consumed');
      expect(rows.single['next_retry_at'], isNotNull);
      expect(rows.single['failure_class'], OutboxFailureClass.transientNetwork.name);
    });

    test('a CONFIRMED empty lookup is the only "never reached the server"',
        () async {
      await _insertTx(db);
      final queue = _queue(db);
      await queue.enqueue(OutboxOperation.delete, await _load(db));
      final client = _client(_Calls(), (request) async => _json([], request));
      final result = await _push(db, queue, client).push();
      expect(result.pushed, 1);
      expect(await _outbox(db), isEmpty);
      expect(await _txStatus(db), 'synced');
    });
  });

  group('G15 tombstone ACK settles the entity', () {
    test('after a successful remote tombstone the transaction is synced',
        () async {
      await _insertTx(db, serverId: 'srv-9');
      final queue = _queue(db);
      await queue.enqueue(OutboxOperation.delete, await _load(db));
      expect(await _txStatus(db), 'pending');
      final client = _client(
          _Calls(),
          (request) async => _json([
                {'id': 'srv-9', 'updated_at': 't5'}
              ], request));
      final result = await _push(db, queue, client).push();
      expect(result.pushed, 1);
      expect(await _outbox(db), isEmpty);
      expect(await _txStatus(db), 'synced');
    });

    test('...but not while a newer edit is still queued for it', () async {
      await _insertTx(db, serverId: 'srv-9');
      final queue = _queue(db);
      await queue.enqueue(OutboxOperation.delete, await _load(db));
      final calls = _Calls();
      final client = _client(calls, (request) async {
        if (calls.count == 1) {
          // a follow-up edit lands while the tombstone is in flight
          await queue.enqueue(OutboxOperation.update, await _load(db));
        }
        return _json([
          {'id': 'srv-9', 'updated_at': 't5'}
        ], request);
      });
      await _push(db, queue, client).push();
      expect(await _outbox(db), hasLength(1));
      expect(await _txStatus(db), 'pending');
    });
  });

  group('G18 owner-scoped outbox', () {
    test('a row recorded for owner A is NEVER sent under signed-in B; parked '
        'owner_mismatch, not deleted', () async {
      await _insertTx(db);
      final queueA = _queue(db, owner: () async => 'user-A', auth: 'user-A');
      await queueA.enqueue(OutboxOperation.create, await _load(db));
      expect((await _outbox(db)).single['owner_uid'], 'user-A');

      final tripwire = _Calls();
      final client = _client(tripwire, (r) async => _json({'id': 'x'}, r));
      final asB = _push(db, _queue(db, owner: () async => 'user-B', auth: 'user-B'),
          client, uid: 'user-B');
      final result = await asB.push();

      expect(tripwire.count, 0, reason: 'another account\'s data must not egress');
      expect(result.pushed + result.failed, 0);
      final rows = await _outbox(db);
      expect(rows, hasLength(1));
      expect(rows.single['status'], 'parked');
      expect(rows.single['failure_class'], 'owner_mismatch');

      // Owner A signs back in: the SAME row is re-armed and delivered as A.
      final back = _Calls();
      final clientA = _client(back, (r) async => _json({'id': 'srv-A', 'updated_at': 't'}, r));
      final asA = await _push(db, queueA, clientA, uid: 'user-A').push();
      expect(asA.pushed, 1);
      expect(back.count, 1);
      expect(await _outbox(db), isEmpty);
    });

    test('a NULL-owner legacy row is stamped ONLY when ownership is verified',
        () async {
      await _insertTx(db);
      await db.customStatement('''
        INSERT INTO ledger_sync_outbox(id, transaction_id, operation,
          payload_json, attempt_count, status, created_at, updated_at)
        VALUES ('legacy', '$_tx', 'create',
          '${jsonEncode({'local_id': _tx, 'amount': 100, 'currency': 'SAR', 'type': 'debit', 'occurred_at': '2026-01-01T00:00:00Z'})}',
          0, 'pending', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z');
      ''');

      // Ownership NOT verified for user-1 (the marker says someone else).
      final tripwire = _Calls();
      final unverified = _push(
          db,
          _queue(db, owner: () async => 'someone-else'),
          _client(tripwire, (r) async => _json({'id': 'x'}, r)));
      await unverified.push();
      expect(tripwire.count, 0);
      final row = (await _outbox(db)).single;
      expect(row['status'], 'parked');
      expect(row['failure_class'], 'owner_unverified');
      expect(row['owner_uid'], isNull, reason: 'never stamped without proof');

      // Ownership verified -> stamped, unparked, delivered.
      final calls = _Calls();
      final verified = _push(
          db,
          _queue(db, owner: () async => 'user-1'),
          _client(calls, (r) async => _json({'id': 'srv-1', 'updated_at': 't'}, r)));
      final result = await verified.push();
      expect(result.pushed, 1);
      expect(calls.count, 1);
      expect(await _outbox(db), isEmpty);
    });
  });

  group('G5 enqueue records intent', () {
    test('no live session but a local owner -> intent recorded; pushed once '
        'the session returns', () async {
      await _insertTx(db);
      final queue =
          _queue(db, owner: () async => 'user-1', auth: null);
      await queue.enqueue(OutboxOperation.create, await _load(db));
      final rows = await _outbox(db);
      expect(rows, hasLength(1), reason: 'no silent drop');
      expect(rows.single['owner_uid'], 'user-1');
      expect(await _txStatus(db), 'pending');

      // The push itself still requires a live session.
      final calls = _Calls();
      final client = _client(calls, (r) async => _json({'id': 's', 'updated_at': 't'}, r));
      await _push(db, queue, client, uid: null).push();
      expect(calls.count, 0);
      await _push(db, queue, client, uid: 'user-1').push();
      expect(calls.count, 1);
    });

    test('a true guest (no owner, no session) keeps today\'s behaviour: no intent',
        () async {
      await _insertTx(db);
      final queue = _queue(db, owner: () async => null, auth: null);
      await queue.enqueue(OutboxOperation.create, await _load(db));
      expect(await _outbox(db), isEmpty);
    });

    test('reArmParked leaves A-2 park reasons alone', () async {
      await _insertTx(db);
      final queue = _queue(db);
      await queue.enqueue(OutboxOperation.create, await _load(db));
      await db.customStatement(
          "UPDATE ledger_sync_outbox SET status='parked', failure_class='owner_mismatch';");
      expect(await queue.reArmParked(), 0);
    });
  });

  group('G14 background queue == foreground queue', () {
    test('the background factory resolves the real cutover state and produces '
        'the same money payload as the foreground queue', () async {
      await _insertTx(db, id: 'tx-fg');
      await _insertTx(db, id: 'tx-bg');
      final foreground = LedgerOutboxQueue(
        db: db,
        isPushEnabled: () => true,
        getAuthUserId: () async => 'user-1',
        // The provider-wired coordinator of a fresh v30 install.
        coordinator:
            const FixedPlanningCutoverCoordinator(PlanningCutoverState.canonical),
      );
      final resolved = await resolveCutoverCoordinator(db);
      expect(resolved.state(), PlanningCutoverState.canonical,
          reason: 'a fresh v30 DB is canonical — same as the foreground seed');
      final background = LedgerOutboxQueue(
        db: db,
        isPushEnabled: () => true,
        getAuthUserId: () async => 'user-1',
        coordinator: resolved,
      );
      await foreground.enqueue(OutboxOperation.create, await _load(db, 'tx-fg'));
      await background.enqueue(OutboxOperation.create, await _load(db, 'tx-bg'));

      final raw = <String, String>{
        for (final r in await _outbox(db))
          r['transaction_id'] as String: r['payload_json'] as String,
      };
      Map<String, dynamic> payloadOf(String id) =>
          Map<String, dynamic>.from(jsonDecode(raw[id]!) as Map)
            ..remove('local_id');

      expect(payloadOf('tx-bg'), payloadOf('tx-fg'));
      expect(payloadOf('tx-bg')['amount'], isA<String>(),
          reason: 'canonical = exact decimal STRING, not a JSON number');

      // ...and they push identically.
      final bodies = <String, Map<String, dynamic>>{};
      final client = _client(_Calls(), (request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        bodies[body['client_request_id'] as String] = body;
        return _json({'id': 'srv-${bodies.length}', 'updated_at': 't'}, request);
      });
      await _push(db, foreground, client,
              coordinator: resolved,
              capability: () => ExactTransportCapability.verifiedExact)
          .push();
      Map<String, dynamic> bodyOf(String id) =>
          Map.of(bodies[id]!)..remove('client_request_id');
      expect(bodyOf('tx-bg'), bodyOf('tx-fg'));
    });
  });

  group('SyncHealth counts', () {
    test('parked includes the new reasons with a per-reason breakdown',
        () async {
      await _insertTx(db);
      await _insertTx(db, id: 'tx-2');
      await _insertTx(db, id: 'tx-3');
      final queue = _queue(db);
      for (final id in [_tx, 'tx-2', 'tx-3']) {
        await queue.enqueue(OutboxOperation.create, await _load(db, id));
      }
      await db.customStatement(
          "UPDATE ledger_sync_outbox SET status='parked', failure_class='owner_mismatch' WHERE transaction_id='$_tx';");
      await db.customStatement(
          "UPDATE ledger_sync_outbox SET status='parked', failure_class='owner_unverified' WHERE transaction_id='tx-2';");
      await db.customStatement('''
        INSERT INTO planning_sync_outbox(id, entity_type, entity_id, operation,
          payload_json, attempt_count, status, failure_class, created_at, updated_at)
        VALUES ('p1','budget','b1','create','{}',0,'parked','dependency_wait','t','t');
      ''');
      final counts = await SyncHealth.queueCounts(db);
      expect(counts.parked, 3);
      expect(counts.pending, 1);
      expect(counts.parkedByReason, {
        'owner_mismatch': 1,
        'owner_unverified': 1,
        'dependency_wait': 1,
      });
    });
  });
}
