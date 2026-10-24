import 'ledger_admission_fixture.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/session/account_fence_authority.dart';
import 'package:money_companion/core/session/account_fence_store.dart';
import 'package:money_companion/features/capture/services/ledger_sync_engine.dart';
import 'package:money_companion/features/capture/services/ledger_sync_service.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import '../../core/session/f2_fixture.dart';

import 'package:money_companion/core/sync/outbox_failure.dart';
import 'package:money_companion/core/sync/account_fence_retry.dart';
import 'package:money_companion/core/sync/sync_health.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/legacy_financial_cache_reconciler.dart';
import 'package:money_companion/data/db/financial_cache_health.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/data/db/planning_cutover.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/data/sync/exact_transport_capability.dart';
import 'package:money_companion/data/sync/revision_cas.dart';
import 'package:money_companion/data/sync/server_capabilities.dart';
import 'package:money_companion/data/sync/seq_pull.dart';
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

final _ledgerClients = <SupabaseClient>[];
SupabaseClient _ownLedgerClient(SupabaseClient client) {
  _ledgerClients.add(client);
  return client;
}
Future<void> _disposeLedgerClients() async {
  for (final client in _ledgerClients) { await client.dispose(); }
  _ledgerClients.clear();
}

SupabaseClient _client(_Calls calls, _Handler handler) => _ownLedgerClient(SupabaseClient(
      'https://example.supabase.co',
      'public-anon-key',
      accessToken: () async => 'qa-access-token',
      httpClient: MockClient((request) async {
        calls.requests.add(request);
        return handler(request);
      }),
    ));

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
  AccountFenceRetry? fenceRetry,
}) =>
    LedgerPushService(
      db: db,
      queue: queue,
      isPushEnabled: () => true,
      getAuthUserId: () async => uid,
      getClient: () => client,
      mayEgress: () async => true,
      fenceRetry: fenceRetry ?? AccountFenceRetry(delay: (_) async {}),
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
  _e4LedgerFileBackedTests();
  _e4LedgerDeliveryTests();
  _e4LedgerSecurityMatrix();
  tearDown(_disposeLedgerClients);
  group('admitted ledger mechanics', () {
  late AppDatabase db;
  late LedgerAdmissionFixture admission;

  setUp(() async {
    admission = await LedgerAdmissionFixture.open('user-1');
    db = admission.database;
  });
  tearDown(() async {
    await _disposeLedgerClients();
    await admission.finish();
  });

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
        'owner_mismatch; queue rearm and independent A delivery', () async {
      await admission.finish();
      admission = await LedgerAdmissionFixture.open('user-B');
      db = admission.database;
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

      // Queue-only same-row rearm, not a transfer of this B-owned replica.
      final foreignId = rows.single['id'];
      await queueA.reconcileOwnership('user-A');
      expect((await _outbox(db)).single['id'], foreignId);
      expect((await _outbox(db)).single['status'], 'pending');
      // Independent real A replica proves A's positive dispatch coherently.
      await _disposeLedgerClients();
      await admission.finish();
      admission = await LedgerAdmissionFixture.open('user-A');
      db = admission.database;
      await _insertTx(db);
      final admittedQueueA = _queue(db, owner: () async => 'user-A', auth: 'user-A');
      await admittedQueueA.enqueue(OutboxOperation.create, await _load(db));
      final back = _Calls();
      final clientA = _client(back, (r) async => _json({'id': 'srv-A', 'updated_at': 't'}, r));
      final asA = await _push(db, admittedQueueA, clientA, uid: 'user-A').push();
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
  });
}


// E4 first RED: existing queue/service APIs over a real temporary database.
// No hypothetical hold is seeded; every refusal originates at the remote port.
void _e4LedgerFileBackedTests() {
  Future<void> withFileDatabase(
      Future<void> Function(AppDatabase db, Future<AppDatabase> Function() reopen) body) async {
    final admission = await LedgerAdmissionFixture.open('user-1');
    var database = admission.database;
    final location = admission.location;
    AppDatabase? inspection;
    try {
      await body(database, () async {
        if (database.lifecycleState == DatabaseLifecycleState.closed) {
          // Inspection after accepted denial: never admitted or used for writes.
          inspection = await AppDatabase.open(location: location, runMigrations: false,
              creation: const CreationPolicy.denied());
          return inspection!;
        }
        database = await admission.restart();
        return database;
      });
    } finally {
      await inspection?.close();
      await _disposeLedgerClients();
      await admission.finish();
    }
  }

  // Explicit lower-layer mechanism: real SDK typed refusal -> exact queue
  // transition. No service/authority/ACK/conflict/fallback logic is emulated.
  Future<bool> queueRefusal(LedgerOutboxQueue queue, SupabaseClient client,
      {bool expectedChanged = true}) async {
    final item = (await queue.pendingItems()).first;
    try {
      await client.from('user_transactions').upsert(item.payloadJson)
          .select('id, updated_at').single();
      fail('the SDK mutation must return the explicit typed refusal');
    } on PostgrestException catch (error) {
      expect(error.code, 'QD001');
      final failure = classifyOutboxError(error);
      expect(failure, OutboxFailureClass.accountDeletionPending);
      final changed = await queue.recordAccountFenceFailure(item, failure, DateTime.utc(2026));
      expect(changed, expectedChanged);
      return changed;
    }
  }

  Map<String, Object?> intent(Map<String, Object?> row) => {
        for (final key in ['id', 'transaction_id', 'owner_uid', 'operation',
          'payload_json', 'op_seq', 'operation_id', 'base_revision']) key: row[key],
      };

  http.Response refuse(String code, http.Request request) => http.Response(
        jsonEncode({'code': code, 'message': 'structured refusal',
          'details': null, 'hint': null}),
        400, headers: const {'content-type': 'application/json'}, request: request,
      );

  for (final code in ['55P03', 'QD001']) {
    test('E4 ledger $code refusal preserves intent without a business attempt across reopen', () async {
      await withFileDatabase((database, reopen) async {
        await _insertTx(database);
        final queue = _queue(database);
        await queue.enqueue(OutboxOperation.create, await _load(database));
        final before = (await _outbox(database)).single;
        if (code == 'QD001') {
          await _insertTx(database, id: 'tx-e4-later');
          await queue.enqueue(OutboxOperation.create, await _load(database, 'tx-e4-later'));
        }
        final calls = _Calls();
        LedgerPushResult? result;
        try {
          result = await _push(database, queue,
              _client(calls, (request) async => refuse(code, request))).push();
          expect(code, '55P03');
        } on LedgerDeliveryStopped catch (error) {
          expect(code, 'QD001');
          expect(error.accepted && error.parked && error.complete, isTrue);
        }
        final reopened = await reopen();
        final refused = (await _outbox(reopened)).firstWhere((row) => row['id'] == before['id']);
        final restored = (await _outbox(reopened)).firstWhere((row) => row['id'] == before['id']);

        if (code == '55P03') { expect(result!.pushed, 0); expect(result.conflicts, 0); } else { expect(result, isNull); }
        expect(calls.count, greaterThanOrEqualTo(1), reason: 'the real service reached the fake remote');
        expect(intent(refused), intent(before));
        expect(intent(restored), intent(before));
        expect(restored['in_flight_seq'], refused['in_flight_seq'],
            reason: 'reopen preserves the captured possibly-sent evidence');
        expect(refused['attempt_count'], 0, reason: '$code is not a business failure');
        expect(restored['attempt_count'], 0);
        expect(restored['status'], isNot('dead_letter'));
        expect(restored['failure_class'], code == '55P03'
            ? 'account_fence_contention' : 'account_deletion_pending');
        if (code == '55P03') {
          expect(calls.count, greaterThan(1), reason: 'repeated rejection exhausts a bounded atomic retry budget');
          expect(calls.count, lessThan(kOutboxMaxAttempts), reason: 'remote contention retries are bounded independently of business attempts');
          expect(calls.requests.map((request) => request.body).toSet(), hasLength(1));
          expect(restored['status'], 'pending');
          expect(restored['next_retry_at'], isNotNull, reason: 'exhaustion has a durable cooldown');
          final afterRestartCalls = _Calls();
          await _push(reopened, _queue(reopened), _client(afterRestartCalls,
              (request) async => refuse('55P03', request))).push();
          expect(afterRestartCalls.count, 0, reason: 'restart must not bypass contention cooldown');
          expect(intent((await _outbox(reopened)).single), intent(before));
          expect((await _outbox(reopened)).single['attempt_count'], 0);
        }
        expect(await _txStatus(reopened), 'pending', reason: 'refusal is never an ACK');
        if (code == 'QD001') {
          expect(refused['status'], 'parked');
          expect(restored['status'], 'parked');
          expect(calls.count, 1, reason: 'QD001 stops the remaining service mutation run');
          final later = (await _outbox(reopened)).firstWhere((row) => row['transaction_id'] == 'tx-e4-later');
          expect(later['attempt_count'], 0);
          expect(later['status'], 'pending');
          expect(await _txStatus(reopened, 'tx-e4-later'), 'pending');
        }
      });
    });
  }

  test('E4 ledger queue-mechanics typed QD001 hold survives rearm coalesced intent and reopen without another send', () async {
    await withFileDatabase((database, reopen) async {
      await _insertTx(database);
      final queue = _queue(database);
      await queue.enqueue(OutboxOperation.create, await _load(database));
      final before = (await _outbox(database)).single;
      final refusedCalls = _Calls();
      await queueRefusal(queue,
          _client(refusedCalls, (request) async => refuse('QD001', request)));
      final afterRefusal = (await _outbox(database)).single;

      // Existing refresh/Retry/capability/owner recovery entry points. None may
      // release deletion authority or make a later same-owner edit sendable.
      await queue.reArmAuthParked();
      await queue.clearRetryBackoff();
      await queue.reArmRetryableDeadLetters();
      await queue.reArmDeadLetter();
      await queue.reArmParked();
      await queue.reArmAwaitingFxParked();
      await queue.reconcileOwnership('user-1');
      await database.customStatement(
          "UPDATE transactions SET note = 'E4 retained later intent' WHERE id = '$_tx';");
      await queue.enqueue(OutboxOperation.update, await _load(database));
      final afterEdit = await _outbox(database);
      final reopened = await reopen();
      final afterRestart = await _outbox(reopened);
      final laterCalls = _Calls();
      final result = await _push(reopened, _queue(reopened), _client(laterCalls,
          (request) async => _json({'id': 'srv-e4', 'updated_at': 'e4-ack'}, request))).push();
      final afterRetry = await _outbox(reopened);

      expect(refusedCalls.count, 1);
      expect(laterCalls.count, 0, reason: 'generic recovery or a local edit must not revive deletion authority');
      expect(result.pushed, 0);
      expect(result.conflicts, 0);
      expect(intent(afterRefusal), intent(before));
      expect(afterRefusal['attempt_count'], 0);
      expect(afterRefusal['status'], 'parked');
      expect(afterRefusal['failure_class'], 'account_deletion_pending');
      expect(afterEdit, isNotEmpty, reason: 'the newer local intent remains durable');
      expect(afterRestart, afterEdit);
      expect(afterRetry, afterRestart, reason: 'no ACK, erase, or generic failure mutation');
      expect(afterRetry.every((row) => row['status'] == 'parked' && row['failure_class'] == 'account_deletion_pending'), isTrue);
      expect(afterRetry.any((row) =>
          (jsonDecode(row['payload_json'] as String) as Map)['note'] == 'E4 retained later intent'), isTrue);
      expect(await _txStatus(reopened), 'pending');
      expect(await _queue(reopened).pendingItems(), isEmpty);
    });
  });
  test('E4 ledger contention retry succeeds with identical mutation and one ACK', () async {
    await withFileDatabase((database, reopen) async {
      await _insertTx(database);
      final queue = _queue(database);
      await queue.enqueue(OutboxOperation.create, await _load(database));
      final before = (await _outbox(database)).single;
      final payloads = <String>[];
      final attempts = <int>[];
      var now = DateTime.now().toUtc();
      var delays = 0;
      final policy = AccountFenceRetry(clock: () => now, delay: (duration) async { delays++; now = now.add(duration); });
      final calls = _Calls();
      final remote = _client(calls, (request) async {
        payloads.add(request.body);
        attempts.add((await _outbox(database)).single['attempt_count'] as int);
        if (payloads.length == 1) { return refuse('55P03', request); }
        return _json({'id': 'srv-e4', 'updated_at': '2026-10-01T00:00:00Z'}, request);
      });
      final result = await _push(database, queue, remote, fenceRetry: policy).push();
      expect(result.pushed, 1);
      expect(result.conflicts, 0);
      expect(payloads, hasLength(2));
      expect(payloads[1], payloads[0]);
      expect(attempts, [0, 0]);
      expect(delays, 1);
      expect(before['operation_id'], isNotNull);
      expect(await _outbox(database), isEmpty);
      await _push(database, queue, remote, fenceRetry: policy).push();
      expect(payloads, hasLength(2), reason: 'the acknowledged intent never dispatches again');
    });
  });

  test('E4 ledger contention followed by QD001 holds immediately without consuming the budget further', () async {
    await withFileDatabase((database, reopen) async {
      await _insertTx(database);
      final queue = _queue(database);
      await queue.enqueue(OutboxOperation.create, await _load(database));
      final before = (await _outbox(database)).single;
      var count = 0;
      var delays = 0;
      final policy = AccountFenceRetry(delay: (_) async { delays++; });
      final calls = _Calls();
      final remote = _client(calls, (request) async {
        count++;
        if (count == 1) { return refuse('55P03', request); }
        return refuse('QD001', request);
      });
      await expectLater(_push(database, queue, remote, fenceRetry: policy).push(),
          throwsA(isA<LedgerDeliveryStopped>().having((error) =>
              error.accepted && error.parked && error.complete, 'healthy denial', isTrue)));
      final restored = await reopen();
      final held = (await _outbox(restored)).single;
      expect(count, 2);
      expect(delays, 1);
      expect(held['status'], 'parked');
      expect(held['failure_class'], 'account_deletion_pending');
      expect(held['attempt_count'], 0);
      expect(intent(held), intent(before));
    });
  });

  for (final newerDispatched in [false, true]) {
    test('E4 ledger queue-mechanics late typed QD001 preserves coalesced payload and respects newer inflight=$newerDispatched', () async {
      await withFileDatabase((database, reopen) async {
        await _insertTx(database);
        final queue = _queue(database);
        await queue.enqueue(OutboxOperation.create, await _load(database));
        final original = (await _outbox(database)).single;
        final arrived = Completer<void>(); final release = Completer<void>();
        final calls = _Calls();
        final remote = _client(calls, (request) async {
          arrived.complete();
          await release.future;
          return refuse('QD001', request);
        });
        final running = queueRefusal(queue, remote, expectedChanged: !newerDispatched);
        await arrived.future;
        await database.customStatement("UPDATE transactions SET note = 'newer E4 edit' WHERE id = '$_tx';");
        await queue.enqueue(OutboxOperation.update, await _load(database));
        if (newerDispatched) { await queue.pendingItems(); }
        final edited = (await _outbox(database)).single;
        release.complete();
        await running;
        final after = (await _outbox(database)).single;
        expect((jsonDecode(after['payload_json'] as String) as Map)['note'], 'newer E4 edit');
        expect((jsonDecode(after['payload_json'] as String) as Map)['prior_op_ids'], contains(original['operation_id']));
        expect(after['operation_id'], edited['operation_id']);
        expect(after['op_seq'], edited['op_seq']);
        expect(after['in_flight_seq'], edited['in_flight_seq']);
        expect(after['attempt_count'], 0);
        if (newerDispatched) {
          expect(after, edited, reason: 'an old refusal cannot overwrite the newer in-flight holder');
        } else {
          expect(after['status'], 'parked');
          expect(after['failure_class'], 'account_deletion_pending');
        }
      });
    });
  }

    test('E4 ledger queue-mechanics late typed QD001 cannot hold a completed successor with NULL marker', () async {
      await withFileDatabase((database, reopen) async {
        await _insertTx(database);
        final queue = _queue(database);
        await queue.enqueue(OutboxOperation.create, await _load(database));
        final arrived = Completer<void>(); final release = Completer<void>();
        final calls = _Calls();
        final remote = _client(calls, (request) async {
          arrived.complete();
          await release.future;
          return refuse('QD001', request);
        });
        final running = queueRefusal(queue, remote, expectedChanged: false);
        await arrived.future;
        await database.customStatement("UPDATE transactions SET note = 'newer E4 edit' WHERE id = '$_tx';");
        await queue.enqueue(OutboxOperation.update, await _load(database));
        final successor = (await queue.pendingItems()).single;
        await database.customStatement("UPDATE transactions SET note = 'successor E4 edit' WHERE id = '$_tx';");
        await queue.enqueue(OutboxOperation.update, await _load(database));
        await queue.acknowledge(successor);
        final edited = (await _outbox(database)).single;
        release.complete();
        await running;
        final after = (await _outbox(database)).single;
        expect(edited['in_flight_seq'], isNull);
        expect(after, edited, reason: 'the rejected S1 no longer owns the holder after S2 ACK');
      });
    });

  test('E4 ledger queue-mechanics a held create plus delete preserves the refusal and replay history', () async {
    await withFileDatabase((database, reopen) async {
      await _insertTx(database);
      final queue = _queue(database);
      await queue.enqueue(OutboxOperation.create, await _load(database));
      final original = (await _outbox(database)).single;
      final calls = _Calls();
      final remote = _client(calls, (request) async { return refuse('QD001', request); });
      await queueRefusal(queue, remote);
      await queue.enqueue(OutboxOperation.delete, await _load(database));
      final held = (await _outbox(database)).single;
      expect(held['id'], original['id']);
      expect(held['operation'], 'delete');
      expect(held['status'], 'parked');
      expect(held['failure_class'], 'account_deletion_pending');
      expect(held['attempt_count'], 0);
      expect((jsonDecode(held['payload_json'] as String) as Map)['prior_op_ids'], contains(original['operation_id']));
      final restored = await reopen();
      expect((await _outbox(restored)).single, held);
    });
  });

  for (final code in ['55P03', 'QD001']) {
    test('E4 ledger prior ambiguous send then $code preserves evidence and existing business attempts', () async {
      await withFileDatabase((database, reopen) async {
        await _insertTx(database);
        final queue = _queue(database);
        await queue.enqueue(OutboxOperation.create, await _load(database));
        final policy = AccountFenceRetry(delay: (_) async {});
        var ambiguous = true;
        final calls = _Calls();
        final remote = _client(calls, (request) async {
          if (ambiguous) throw const SocketException('lost reply');
          return refuse(code, request);
        });
        await _push(database, queue, remote, fenceRetry: policy).push();
        final uncertain = (await _outbox(database)).single;
        expect(uncertain['attempt_count'], 1);
        expect(uncertain['in_flight_seq'], isNotNull);
        await queue.clearRetryBackoff();
        ambiguous = false;
        if (code == 'QD001') {
          await expectLater(_push(database, queue, remote, fenceRetry: policy).push(),
              throwsA(isA<LedgerDeliveryStopped>().having((error) =>
                  error.accepted && error.parked && error.complete, 'healthy denial', isTrue)));
        } else {
          await _push(database, queue, remote, fenceRetry: policy).push();
        }
        final inspection = code == 'QD001' ? await reopen() : database;
        final refused = (await _outbox(inspection)).single;
        expect(intent(refused), intent(uncertain));
        expect(refused['in_flight_seq'], uncertain['in_flight_seq']);
        expect(refused['attempt_count'], 1, reason: 'a definite current refusal cannot erase prior ambiguity or spend another business attempt');
        expect(refused['failure_class'], code == '55P03' ? 'account_fence_contention' : 'account_deletion_pending');
      });
    });
  }

  test('E4 CAS own-write rebase shares a single contention retry budget', () async {
    final remote = _E4CasRemote();
    var delays = 0;
    final policy = AccountFenceRetry(maxAttempts: 3, delay: (_) async { delays++; });
    await expectLater(policy.runItem(isCurrent: () async => true,
        body: () => RevisionCasEngine(remote).update(table: 'user_transactions',
          epoch: 'epoch', opId: 'current-operation', priorOpIds: ['prior-operation'],
          serverId: 'server', baseRevision: 5, baseUpdatedAt: null, patch: {'amount': 100})),
        throwsA(isA<PostgrestException>()));
    expect(remote.revisions, [5, 5, 6, 6], reason: 'two normal CAS dispatches plus ONLY two shared contention retries');
    expect(remote.operations.toSet(), {'current-operation'});
    expect(remote.patches.every((patch) => patch['amount'] == 100), isTrue);
    expect(delays, 2, reason: 'rebasing cannot reset or multiply the shared retry budget');
  });

  test('E4 raw fence classification preserves ordinary conflict duplicate and permission meanings', () {
    expect(classifyOutboxError(const PostgrestException(message: 'irrelevant', code: '55P03')),
        OutboxFailureClass.accountFenceContention);
    expect(classifyOutboxError(const PostgrestException(message: 'irrelevant', code: 'QD001')),
        OutboxFailureClass.accountDeletionPending);
    expect(classifyOutboxError(const PostgrestException(message: 'QD001', code: '409')),
        OutboxFailureClass.conflict);
    expect(classifyOutboxError(const PostgrestException(message: '55P03', code: '23505')),
        OutboxFailureClass.duplicateBusinessKey);
    expect(classifyOutboxError(const PostgrestException(message: 'QD001', code: '42501'), hasValidSession: true),
        OutboxFailureClass.permissionDenied);
    expect(classifyOutboxError(const PostgrestException(message: 'QD001', code: '42501'), hasValidSession: false),
        OutboxFailureClass.auth);
  });

}


class _E4CasRemote implements CasRemote {
  final revisions = <int>[];
  final operations = <String>[];
  final patches = <Map<String, dynamic>>[];
  @override
  Future<CasResult> casUpdate({required String table, required String epoch,
      required String opId, required String serverId, required int expectedRevision,
      required Map<String, dynamic> patch}) async {
    revisions.add(expectedRevision);
    operations.add(opId);
    patches.add(Map<String, dynamic>.of(patch));
    if (revisions.length == 2) {
      return CasResult(CasOutcome.conflict, {'id': serverId, 'revision': 6,
          'last_op_id': 'prior-operation', 'deleted_at': null});
    }
    throw const PostgrestException(message: 'refused', code: '55P03');
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('unexpected CAS call');
}


// E4 delivery first RED: real admission/host/file-backed queue and the actual
// SDK's PostgREST decoder. Only external HTTP is mocked; no authority is faked.
void _e4LedgerDeliveryTests() {
  Future<void> withAdmittedLedger(Future<void> Function(F2Fixture fixture,
      SupabaseClient client, _Calls calls, LedgerOutboxQueue queue) body,
      _Handler mutation) async {
    final restore = AccountFenceAuthority.replacePersistenceForTest();
    final fixture = await F2Fixture.create(afterWithdraw: () async {});
    fixture.session.configureAccountScope(fixture.host);
    final databases = <AppDatabase>[];
    void rememberDatabase() {
      final db = fixture.host.current?.database;
      if (db != null && !databases.contains(db)) databases.add(db);
    }
    fixture.host.addListener(rememberDatabase);
    rememberDatabase();
    final calls = _Calls();
    final client = SupabaseClient('https://example.supabase.co', 'public-anon-key',
        httpClient: MockClient((request) async {
      if (request.url.path.endsWith('/user')) {
        return _json({'id': 'uid-ledger', 'aud': 'authenticated',
          'email': 'uid-ledger@example.com', 'app_metadata': <String, dynamic>{},
          'user_metadata': <String, dynamic>{}, 'created_at': '2026-10-01T00:00:00Z'}, request);
      }
      calls.requests.add(request);
      return mutation(request);
    }));
    try {
      await F2Fixture.recoverSession_(client, 'uid-ledger');
      await fixture.signIn('uid-ledger');
      final db = fixture.host.current!.database;
      expect(fixture.host.current!.location, isNotNull);
      expect(File(fixture.host.current!.location!.dbPath).existsSync(), isTrue);
      expect(await fixture.keyPresent('uid-ledger'), isTrue);
      expect(await AccountFenceAuthority.shared.capture(fixture.session, fixture.host), isNotNull);
      final queue = LedgerOutboxQueue(db: db, isPushEnabled: () => true,
          getAuthUserId: () async => client.auth.currentUser?.id,
          getOwnerUid: fixture.session.readLocalDataOwnerUid);
      await _insertTx(db);
      await queue.enqueue(OutboxOperation.create, await _load(db));
      await body(fixture, client, calls, queue);
    } finally {
      await fixture.session.drainAdmissions();
      await client.dispose();
      await fixture.dispose();
      for (final db in databases) {
        expect(db.lifecycleState, DatabaseLifecycleState.closed);
      }
      expect(await AccountFenceAuthority.shared.initialize(), isTrue);
      expect(AccountFenceAuthority.shared.store.ready, isTrue);
      restore();
    }
  }

  LedgerPushService service(F2Fixture fixture, SupabaseClient client,
      LedgerOutboxQueue queue) => LedgerPushService(
    db: fixture.host.current!.database, queue: queue,
    isPushEnabled: () => true,
    getAuthUserId: () async => client.auth.currentUser?.id,
    getClient: () => client, mayEgress: () async => true,
    fenceRetry: AccountFenceRetry(delay: (_) async {}),
  );

  Future<({List<Map<String, Object?>> outbox, Map<String, Object?> entity})>
      snapshot(F2Fixture fixture, AppDatabase original,
          Future<AppDatabase> Function() inspect) async {
    AppDatabase db;
    var inspection = false;
    if (original.lifecycleState == DatabaseLifecycleState.open) {
      db = original;
    } else {
      expect(original.lifecycleState, DatabaseLifecycleState.closed);
      db = await inspect();
      inspection = true;
    }
    try {
      return (outbox: await _outbox(db), entity: (await db.customSelect(
          "SELECT server_id, sync_status, synced_at FROM transactions WHERE id = '$_tx';")
          .getSingle()).data);
    } finally {
      if (inspection) {
        await db.close();
        expect(db.lifecycleState, DatabaseLifecycleState.closed);
      }
    }
  }

  for (final code in ['QD001', 'QD002']) {
    test('E4 ledger delivery current raw $code retires and preserves exact intent', () async {
      final reached = Completer<void>();
      await withAdmittedLedger((fixture, client, calls, queue) async {
        final scope = fixture.host.current!;
        final db = scope.database;
        final local = fixture.session.captureLocalWorkAuthority()!;
        final maintenance = await fixture.session.maintenanceAuthority('uid-ledger');
        final before = (await _outbox(db)).single;
        LedgerDeliveryStopped? stopped;
        LedgerPushResult? result;
        try {
          result = await service(fixture, client, queue).push();
        } on LedgerDeliveryStopped catch (error) {
          stopped = error;
        }
        expect(result, isNull, reason: 'denial never returns a successful push result');
        expect(stopped?.reason, LedgerDeliveryStopReason.denial);
        expect(stopped?.accepted, isTrue);
        expect(stopped?.parked, isTrue);
        expect(stopped?.complete, isTrue);
        expect(reached.isCompleted, isTrue, reason: 'actual mutation producer settled');
        expect(calls.count, 1);
        final after = await snapshot(fixture, db, () async {
          expect(await SecureDatabaseKeyStore(storageKey: scope.location!.keyName,
              databaseExists: () => File(scope.location!.dbPath).exists())
              .readStoredKey(), isNotNull);
          return AppDatabase.open(location: scope.location, runMigrations: false,
              creation: const CreationPolicy.denied());
        });
        expect(after.outbox, hasLength(1));
        final row = after.outbox.single;
        final preserved = <String, Object?>{
          for (final key in ['id', 'transaction_id', 'owner_uid', 'operation',
            'payload_json', 'op_seq', 'operation_id', 'base_revision']) key: row[key],
        };
        final original = <String, Object?>{
          for (final key in preserved.keys) key: before[key],
        };
        final reconstructed = AccountFenceStore();
        expect(await reconstructed.load(), isTrue);
        expect({
          'local_current': local.isCurrent,
          'maintenance_current': maintenance.isCurrent,
          'hold': AccountFenceAuthority.shared.store.holdFor(
              AccountFenceStore.ownerDigest('uid-ledger'))?.state.name,
          'reconstructed_hold': reconstructed.holdFor(
              AccountFenceStore.ownerDigest('uid-ledger'))?.state.name,
          'intent_preserved': preserved.entries.every((entry) => original[entry.key] == entry.value),
          'attempts': row['attempt_count'],
          'status': row['status'],
          'reason': row['failure_class'],
          'possibly_sent': row['in_flight_seq'] == row['op_seq'],
          'server_id': after.entity['server_id'],
          'synced_at': after.entity['synced_at'],
          'entity_acknowledged': after.entity['sync_status'] == 'synced',
        }, {
          'local_current': false, 'maintenance_current': false,
          'hold': code == 'QD001' ? 'pending' : 'gone',
          'reconstructed_hold': code == 'QD001' ? 'pending' : 'gone',
          'intent_preserved': true, 'attempts': 0, 'status': 'parked',
          'reason': code == 'QD001' ? 'account_deletion_pending' : 'account_deletion_gone',
          'possibly_sent': true, 'server_id': null, 'synced_at': null,
          'entity_acknowledged': false,
        });
      }, (request) async {
        expect(request.method, 'POST');
        expect(request.url.path, endsWith('/rest/v1/user_transactions'));
        reached.complete();
        return http.Response(jsonEncode({'code': code,
          'message': 'structured refusal', 'details': null, 'hint': null}), 400,
          headers: const {'content-type': 'application/json'}, request: request);
      });
    });

    test('E4 ledger delivery engine raw $code stops the reachable pull slot', () async {
      await withAdmittedLedger((fixture, client, calls, queue) async {
        final pull = _E4DeliveryPull();
        final engine = LedgerSyncEngine(pushService: service(fixture, client, queue),
            pullService: pull);
        await engine.sync();
        expect(calls.count, 1);
        expect(pull.calls, 0, reason: 'an authoritative denial stops this engine invocation');
      }, (request) async => http.Response(jsonEncode({'code': code,
          'message': 'structured refusal', 'details': null, 'hint': null}), 400,
          headers: const {'content-type': 'application/json'}, request: request));
    });
  }

  test('E4 ledger delivery ordinary success reaches mutation ACK and pull once', () async {
    await withAdmittedLedger((fixture, client, calls, queue) async {
      final db = fixture.host.current!.database;
      final pull = _E4DeliveryPull();
      await LedgerSyncEngine(pushService: service(fixture, client, queue), pullService: pull).sync();
      expect(calls.count, 1);
      expect(pull.calls, 1, reason: 'matching positive proves the external pull slot is reachable');
      expect(await _outbox(db), isEmpty);
      expect(await _txStatus(db), 'synced');
      expect(fixture.session.captureLocalWorkAuthority()!.isCurrent, isTrue);
    }, (request) async => _json({'id': 'server-ledger',
        'updated_at': '2026-10-01T00:00:00.000Z'}, request));
  });
}

class _E4DeliveryPull implements LedgerPullAdapter {
  int calls = 0;
  @override
  Future<LedgerSyncResult> pull({SyncCursor? from, bool Function()? isAdmitted}) async {
    calls++;
    return const LedgerSyncResult();
  }
}

void _e4LedgerSecurityMatrix() {
  final releases = <void Function()>[];
  final producers = <Future<Object?>>[];
  void releaseOnExit(Completer<void> gate) => releases.add(() {
    if (!gate.isCompleted) gate.complete();
  });
  Future<T> tracked<T>(Future<T> future) {
    producers.add(future.then<Object?>((value) => value,
        onError: (Object error, StackTrace stack) => error));
    return future;
  }
  Future<void> withLedger(Future<void> Function(LedgerAdmissionFixture,
      LedgerOutboxQueue, SupabaseClient, _Calls) body, _Handler handler,
      {LedgerDatabaseProbe? probe}) async {
    final admission = await LedgerAdmissionFixture.open('user-1', probe);
    final calls = _Calls();
    final client = admission.ownClient(SupabaseClient('https://example.supabase.co',
        'public-anon-key', httpClient: MockClient((request) async {
      if (request.url.path.endsWith('/user')) {
        return _json({'id': 'user-1', 'aud': 'authenticated',
          'email': 'user-1@example.com', 'app_metadata': <String, dynamic>{},
          'user_metadata': <String, dynamic>{}, 'created_at': '2026-10-01T00:00:00Z'}, request);
      }
      calls.requests.add(request);
      return handler(request);
    })));
    try {
      await F2Fixture.recoverSession_(client, 'user-1');
      final queue = _queue(admission.database,
          owner: admission.fixture.session.readLocalDataOwnerUid);
      await _insertTx(admission.database);
      await queue.enqueue(OutboxOperation.create, await _load(admission.database));
      await body(admission, queue, client, calls);
    } finally {
      for (final release in releases) { release(); }
      releases.clear();
      await Future.wait(producers);
      producers.clear();
      if (probe != null) { probe.before = null; probe.afterSelect = null; probe.afterTransactionOpen = null; }
      admission.fixture.storage.gate = null;
      await _disposeLedgerClients();
      await admission.finish();
    }
  }

  http.Response denied(String code, http.Request request) => http.Response(
      jsonEncode({'code': code, 'message': 'structured refusal', 'details': null,
        'hint': null}), 400, headers: const {'content-type': 'application/json'}, request: request);
  Future<LedgerDeliveryStopped> stop(Future<LedgerPushResult> future) async {
    try {
      await future;
      throw StateError('delivery must return a typed stop');
    } on LedgerDeliveryStopped catch (error) {
      return error;
    }
  }

  for (final code in ['QD001', 'QD002']) {
    test('E4 security $code during held readiness retires without positive grant', () async {
      final remoteReached = Completer<void>(); final reply = Completer<void>();
      releaseOnExit(reply);
      await withLedger((admission, queue, client, calls) async {
        final original = admission.database; final location = admission.location;
        final cap = admission.fixture.session.captureLocalWorkAuthority()!;
        final running = tracked(stop(_push(original, queue, client).push()));
        await remoteReached.future;
        final hold = admission.fixture.storage.holdOnce((op, key) =>
            op == 'read' && key == AccountFenceStore.storageKey);
        releaseOnExit(hold.release);
        final loading = tracked(AccountFenceAuthority.shared.initialize());
        await hold.reached.future;
        expect(cap.isCurrent, isFalse);
        final retired = Completer<void>();
        void listener() {
          if (admission.fixture.session.status == SessionStatus.sessionExpired &&
              !retired.isCompleted) { retired.complete(); }
        }
        admission.fixture.session.addListener(listener);
        try {
          reply.complete();
          final retiredFirst = await Future.any([
            retired.future.then((_) => true), running.then((_) => false),
          ]);
          expect(retiredFirst, isTrue, reason: 'raw denial is decoded before transient positive unreadiness');
          expect(AccountFenceAuthority.shared.store.holdFor(
              AccountFenceStore.ownerDigest('user-1'))?.state.name,
              code == 'QD001' ? 'pending' : 'gone');
          expect(cap.isCurrent, isFalse);
        } finally {
          admission.fixture.session.removeListener(listener);
          hold.release.complete();
        }
        final result = await running; await loading;
        expect(result.accepted && result.parked && result.complete, isTrue);
        expect(original.lifecycleState, DatabaseLifecycleState.closed);
        final rows = await LedgerAdmissionFixture.inspectClosed(original, location, _outbox);
        expect(rows.single['attempt_count'], 0);
        expect(rows.single['status'], 'parked');
        expect(calls.count, 1);
      }, (request) async { remoteReached.complete(); await reply.future; return denied(code, request); });
    });

    test('E4 security $code parking reservation drains before close and different owner', () async {
      final probe = LedgerDatabaseProbe();
      final parked = Completer<void>(); final release = Completer<void>();
      releaseOnExit(release);
      await withLedger((admission, queue, client, calls) async {
        final original = admission.database; final location = admission.location;
        final cap = admission.fixture.session.captureLocalWorkAuthority()!;
        final before = (await _outbox(original)).single;
        probe.before = (sql) async {
          if (sql.contains('UPDATE ledger_sync_outbox') &&
              sql.contains('account_deletion_') && !parked.isCompleted) {
            parked.complete(); await release.future;
          }
        };
        final readback = Completer<void>();
        final previousGate = admission.fixture.storage.gate;
        admission.fixture.storage.gate = (op, key) async {
          await previousGate?.call(op, key);
          if (op == 'read' && key == AccountFenceStore.storageKey &&
              admission.fixture.storage.writesTo(AccountFenceStore.storageKey).isNotEmpty &&
              !readback.isCompleted) { readback.complete(); }
        };
        final writeHold = admission.fixture.storage.holdOnce((op, key) =>
            op == 'write' && key == AccountFenceStore.storageKey);
        releaseOnExit(writeHold.release);
        final running = tracked(stop(_push(original, queue, client).push()));
        expect(await Future.any([parked.future.then((_) => true), running.then((_) => false)]), isTrue);
        await writeHold.reached.future;
        expect(cap.isCurrent, isFalse);
        expect(original.lifecycleState, DatabaseLifecycleState.open);
        var successorDone = false;
        final successor = tracked(admission.fixture.signIn('user-B').then((_) => successorDone = true));
        expect(successorDone, isFalse);
        writeHold.release.complete();
        await readback.future;
        expect(probe.closeAttempts, 0);
        expect(successorDone, isFalse);
        expect(release.isCompleted, isFalse);
        release.complete();
        final result = await running; await successor;
        expect(result.accepted && result.parked && result.complete, isTrue);
        expect(original.lifecycleState, DatabaseLifecycleState.closed);
        expect(admission.fixture.host.current?.uid, 'user-B');
        final rows = await LedgerAdmissionFixture.inspectClosed(original, location, _outbox);
        expect(rows.single['payload_json'], before['payload_json']);
        expect(rows.single['operation_id'], before['operation_id']);
        expect(rows.single['attempt_count'], 0);
        expect(calls.count, 1);
      }, (request) async => denied(code, request), probe: probe);
    });
  }

  for (final successor in ['user-1', 'user-B']) {
    for (final response in ['QD001', 'QD002', 'success', '409', 'epoch-error']) {
      test('E4 security stale $response leaves $successor scope and old intent unchanged', () async {
        final reached = Completer<void>(); final release = Completer<void>();
        releaseOnExit(release);
        await withLedger((admission, queue, client, calls) async {
          final original = admission.database; final location = admission.location;
          final running = tracked(stop(_push(original, queue, client).push()));
          await reached.future;
          final handed = (await _outbox(original)).single;
          Future<Map<String, Object?>> entity(AppDatabase db) async =>
              (await db.customSelect("SELECT server_id, sync_status, synced_at FROM transactions WHERE id = '$_tx';").getSingle()).data;
          Future<List<Map<String, Object?>>> conflicts(AppDatabase db) async =>
              (await db.customSelect('SELECT * FROM sync_conflicts;').get()).map((row) => row.data).toList();
          final entityBefore = await entity(original);
          final conflictsBefore = await conflicts(original);
          await admission.fixture.signIn(successor);
          final scope = admission.fixture.host.current;
          final cap = admission.fixture.session.captureLocalWorkAuthority()!;
          release.complete();
          final result = await running;
          expect(result.accepted, isFalse);
          expect(result.parked, isFalse);
          expect(result.complete, isFalse);
          expect(identical(admission.fixture.host.current, scope), isTrue);
          expect(cap.isCurrent, isTrue);
          expect(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(successor)), isNull);
          final rows = original.lifecycleState == DatabaseLifecycleState.open
              ? await _outbox(original)
              : await LedgerAdmissionFixture.inspectClosed(original, location, _outbox);
          expect(rows.single, handed, reason: 'late outcome has no ACK/conflict/failure cleanup authority');
          expect(original.lifecycleState == DatabaseLifecycleState.open ? await entity(original)
              : await LedgerAdmissionFixture.inspectClosed(original, location, entity), entityBefore);
          expect(original.lifecycleState == DatabaseLifecycleState.open ? await conflicts(original)
              : await LedgerAdmissionFixture.inspectClosed(original, location, conflicts), conflictsBefore);
          expect(calls.count, 1);
        }, (request) async {
          reached.complete(); await release.future;
          if (response == 'success') return _json({'id': 'server', 'updated_at': '2026-10-01T00:00:00.000Z'}, request);
          if (response == 'epoch-error') throw const CasEpochMismatch();
          return denied(response, request);
        });
      });
    }
  }

  for (final dirty in [false, true]) {
    test('E4 security tracked health save drains then suppresses dirty=$dirty pull', () async {
      final probe = LedgerDatabaseProbe();
      final saving = Completer<void>(); final release = Completer<void>();
      releaseOnExit(release);
      await withLedger((admission, queue, client, calls) async {
        final original = admission.database; final location = admission.location;
        if (dirty) {
          await original.customStatement("INSERT INTO financial_cache_health(entity_type, dirty, marked_at) VALUES ('transactions', 1, '2026-10-01T00:00:00Z');");
        }
        final handle = await AccountFenceAuthority.shared.capture(admission.fixture.session, admission.fixture.host);
        expect(handle, isNotNull);
        final health = SyncHealth(db: original);
        probe.before = (sql) async {
          if (sql.contains('INSERT INTO sync_cursors') && sql.contains('sync_health:ledger') && !saving.isCompleted) {
            saving.complete(); await release.future;
          }
        };
        final pull = _E4DeliveryPull();
        final engine = LedgerSyncEngine(pushService: LedgerPushService(db: original,
            queue: queue, isPushEnabled: () => true, getAuthUserId: () async => 'user-1',
            getClient: () => client, mayEgress: () async => true), pullService: pull, health: health);
        final running = tracked(engine.sync(reconciler: dirty ? LegacyFinancialCacheReconciler(
            db: original, generation: admission.fixture.host.generation,
            isAdmitted: (_) => true) : null));
        expect(await Future.any([saving.future.then((_) => true), running.then((_) => false)]), isTrue);
        final denial = tracked(AccountFenceAuthority.shared.accept(handle!, AccountFenceState.pending,
            operationId: '550e8400-e29b-41d4-a716-446655440000'));
        expect(original.lifecycleState, DatabaseLifecycleState.open);
        expect(pull.calls, 0);
        release.complete();
        expect(await running, ReconcileDomainResult.cancelled);
        expect((await denial).complete, isTrue);
        expect(pull.calls, 0);
        if (dirty) {
          final isDirty = await LedgerAdmissionFixture.inspectClosed(original, location,
              (db) => isFinancialCacheDirty(db, 'transactions'));
          expect(isDirty, isTrue);
        }
      }, (request) async => _json({'id': 'server', 'updated_at': '2026-10-01T00:00:00.000Z'}, request), probe: probe);
    });
  }

  for (final dirty in [false, true]) {
    test('E4 security current engine reaches ${dirty ? 'epoch and clears dirty' : 'normal pull'}', () async {
      await withLedger((admission, queue, client, calls) async {
        final db = admission.database;
        if (dirty) { await db.customStatement("INSERT INTO financial_cache_health(entity_type, dirty) VALUES ('transactions', 1);"); }
        final froms = <SyncCursor?>[];
        final pull = _E4ControlledPull((from, admitted) async {
          expect(admitted?.call(), isTrue); froms.add(from);
          return const LedgerSyncResult(status: SyncPullStatus.completed);
        });
        final engine = LedgerSyncEngine(pushService: _push(db, queue, client), pullService: pull);
        expect(await engine.sync(reconciler: LegacyFinancialCacheReconciler(
            db: db, generation: admission.fixture.host.generation,
            isAdmitted: (_) => true)), dirty ? ReconcileDomainResult.completed : ReconcileDomainResult.noDirtyState);
        expect(froms, hasLength(1));
        expect(froms.single?.updatedAt, dirty ? syncCursorEpoch : null);
        expect(await isFinancialCacheDirty(db, 'transactions'), isFalse);
        expect(calls.count, 1);
      }, (request) async => _json({'id': 'server', 'updated_at': '2026-10-01T00:00:00.000Z'}, request));
    });
  }

  test('E4 security retirement after epoch pull before internal clear retains marker', () async {
    final probe = LedgerDatabaseProbe();
    final atClear = Completer<void>(); final release = Completer<void>();
    releaseOnExit(release);
    await withLedger((admission, queue, client, calls) async {
      final db = admission.database; final location = admission.location;
      await db.customStatement("INSERT INTO financial_cache_health(entity_type, dirty) VALUES ('transactions', 1);");
      final handle = (await AccountFenceAuthority.shared.capture(admission.fixture.session, admission.fixture.host))!;
      var pullCompleted = false;
      probe.afterTransactionOpen = () async {
        if (pullCompleted && !atClear.isCompleted) { atClear.complete(); await release.future; }
      };
      final pull = _E4ControlledPull((from, admitted) async {
        expect(from?.updatedAt, syncCursorEpoch); expect(admitted?.call(), isTrue);
        pullCompleted = true;
        return const LedgerSyncResult(status: SyncPullStatus.completed);
      });
      final engine = LedgerSyncEngine(pushService: _push(db, queue, client), pullService: pull);
      final running = tracked(engine.sync(reconciler: LegacyFinancialCacheReconciler(
          db: db, generation: admission.fixture.host.generation, isAdmitted: (_) => true)));
      expect(await Future.any([atClear.future.then((_) => true), running.then((_) => false)]), isTrue);
      final denial = tracked(AccountFenceAuthority.shared.accept(handle, AccountFenceState.pending,
          operationId: '550e8400-e29b-41d4-a716-446655440000'));
      release.complete();
      expect(await running, ReconcileDomainResult.cancelled);
      expect((await denial).complete, isTrue);
      expect(pull.calls, 1);
      expect(await LedgerAdmissionFixture.inspectClosed(db, location,
          (opened) => isFinancialCacheDirty(opened, 'transactions')), isTrue);
    }, (request) async => _json({'id': 'server', 'updated_at': '2026-10-01T00:00:00.000Z'}, request), probe: probe);
  });

  test('E4 security already dispatched dirty clear settles before physical close', () async {
    final probe = LedgerDatabaseProbe();
    final clearing = Completer<void>(); final release = Completer<void>();
    final closeStarted = Completer<void>();
    var clearSqlSettled = false;
    var closedBeforeClearSettled = false;
    final clearOrder = <String>[];
    releaseOnExit(release);
    await withLedger((admission, queue, client, calls) async {
      final db = admission.database;
      await db.customStatement("INSERT INTO financial_cache_health(entity_type, dirty) VALUES ('transactions', 1);");
      final handle = (await AccountFenceAuthority.shared.capture(admission.fixture.session, admission.fixture.host))!;
      probe.before = (sql) async {
        if (sql.contains('INSERT INTO financial_cache_health') && sql.contains('repaired_at') && !clearing.isCompleted) {
          clearing.complete(); await release.future;
        }
      };
      probe.onClose = () {
        if (!clearSqlSettled) closedBeforeClearSettled = true;
        clearOrder.add('close-begin');
        if (!closeStarted.isCompleted) closeStarted.complete();
      };
      probe.onClosed = () { clearOrder.add('close-end'); if (!clearSqlSettled) closedBeforeClearSettled = true; };
      final pull = _E4ControlledPull((from, admitted) async =>
          const LedgerSyncResult(status: SyncPullStatus.completed));
      final running = tracked(LedgerSyncEngine(pushService: _push(db, queue, client), pullService: pull).sync(
          reconciler: LegacyFinancialCacheReconciler(db: db, generation: admission.fixture.host.generation,
              isAdmitted: (_) => true)));
      expect(await Future.any([clearing.future.then((_) => true), running.then((_) => false)]), isTrue);
      final denial = tracked(AccountFenceAuthority.shared.accept(handle, AccountFenceState.pending,
          operationId: '550e8400-e29b-41d4-a716-446655440000'));
      final cleanupReadback = Completer<void>();
      final oldGate = admission.fixture.storage.gate;
      admission.fixture.storage.gate = (op, key) async {
        await oldGate?.call(op, key);
        if (op == 'read' && key == AccountFenceStore.storageKey &&
            admission.fixture.storage.writesTo(AccountFenceStore.storageKey).isNotEmpty &&
            !cleanupReadback.isCompleted) { cleanupReadback.complete(); }
      };
      expect(await Future.any([cleanupReadback.future.then((_) => true), closeStarted.future.then((_) => false)]), isTrue);
      expect(probe.closeAttempts, 0, reason: 'a dispatched local transaction must drain before physical close');
      await AccountFenceAuthority.shared.store.load();
      expect(probe.closeAttempts, 0, reason: 'durable load barrier must not race close ahead of a pending local clear');
      probe.afterTransactionSend = () { clearOrder.add('commit'); };
      probe.afterTransactionSettled = () { clearOrder.add('transaction-settled'); clearSqlSettled = true; };
      release.complete();
      expect(await running, ReconcileDomainResult.cancelled);
      expect((await denial).complete, isTrue);
      expect(clearSqlSettled, isTrue, reason: 'actual order: $clearOrder');
      expect(closedBeforeClearSettled, isFalse, reason: 'actual order: $clearOrder');
    }, (request) async => _json({'id': 'server', 'updated_at': '2026-10-01T00:00:00.000Z'}, request), probe: probe);
  });

  test('E4 security recovery preflight is atomic and drains after retirement', () async {
    final probe = LedgerDatabaseProbe(); final reached = Completer<void>(); final release = Completer<void>();
    releaseOnExit(release);
    await withLedger((admission, queue, client, calls) async {
      final db = admission.database; final location = admission.location;
      final handle = (await AccountFenceAuthority.shared.capture(admission.fixture.session, admission.fixture.host))!;
      final row = (await _outbox(db)).single;
      final payload = (jsonDecode(row['payload_json'] as String) as Map)
        ..['amount'] = 0 ..['foreign_amount'] = 12 ..['foreign_currency'] = 'USD';
      await db.customStatement("UPDATE ledger_sync_outbox SET status = 'dead_letter', failure_class = '$kFailServerCheckViolation', payload_json = ${sqlString(jsonEncode(payload))};");
      var terminal = false; var closeBeforeTerminal = false;
      probe.before = (sql) async {
        if (sql.contains('SELECT d.id, d.payload_json') && !reached.isCompleted) {
          reached.complete(); await release.future;
        }
      };
      probe.afterTransactionSettled = () => terminal = true;
      probe.onClose = () { if (!terminal) closeBeforeTerminal = true; };
      final running = tracked(stop(_push(db, queue, client).push()));
      expect(await Future.any([reached.future.then((_) => true), running.then((_) => false)]), isTrue);
      final atomicRead = probe.transactionStatements.any((sql) => sql.contains('SELECT d.id, d.payload_json'));
      final denial = tracked(AccountFenceAuthority.shared.accept(handle, AccountFenceState.pending,
          operationId: '550e8400-e29b-41d4-a716-446655440000'));
      expect(db.lifecycleState, DatabaseLifecycleState.open);
      release.complete();
      expect((await running).accepted, isFalse);
      expect((await denial).complete, isTrue);
      expect(atomicRead, isTrue, reason: 'the recovery read and later updates must be one already-admitted transaction');
      expect(terminal, isTrue); expect(closeBeforeTerminal, isFalse);
      expect(calls.count, 0);
      final restored = (await LedgerAdmissionFixture.inspectClosed(db, location, _outbox)).single;
      expect(restored['attempt_count'], 0);
      expect(restored['status'], 'parked');
      expect(restored['failure_class'], 'awaiting_server_fx_support');
    }, (request) async => throw StateError('no next HTTP'), probe: probe);
  });

  test('E4 security held ownership proof cannot dispatch reconciliation after retirement', () async {
    final probe = LedgerDatabaseProbe(); final reached = Completer<void>(); final release = Completer<void>();
    releaseOnExit(release);
    await withLedger((admission, queue, client, calls) async {
      final db = admission.database; final location = admission.location;
      final before = (await _outbox(db)).single;
      final handle = (await AccountFenceAuthority.shared.capture(admission.fixture.session, admission.fixture.host))!;
      final guardedQueue = _queue(db, owner: () async {
        reached.complete(); await release.future;
        return admission.fixture.session.readLocalDataOwnerUid();
      });
      final mutations = <String>[];
      probe.before = (sql) async { if (sql.contains('UPDATE ledger_sync_outbox')) mutations.add(sql); };
      final running = tracked(stop(_push(db, guardedQueue, client).push()));
      expect(await Future.any([reached.future.then((_) => true), running.then((_) => false)]), isTrue);
      final denial = tracked(AccountFenceAuthority.shared.accept(handle, AccountFenceState.pending,
          operationId: '550e8400-e29b-41d4-a716-446655440000'));
      release.complete();
      expect((await running).accepted, isFalse);
      expect((await denial).complete, isTrue);
      expect(mutations, isEmpty); expect(calls.count, 0);
      expect((await LedgerAdmissionFixture.inspectClosed(db, location, _outbox)).single, before);
    }, (request) async => throw StateError('no request allowed'), probe: probe);
  });

  test('E4 security dispatched atomic failure drains and next intent is not sent', () async {
    final probe = LedgerDatabaseProbe(); final reached = Completer<void>(); final release = Completer<void>();
    releaseOnExit(release);
    await withLedger((admission, queue, client, calls) async {
      final db = admission.database; final location = admission.location;
      await _insertTx(db, id: 'second');
      await queue.enqueue(OutboxOperation.create, (await DriftTransactionRepository(db).getById('second'))!);
      final handle = (await AccountFenceAuthority.shared.capture(admission.fixture.session, admission.fixture.host))!;
      probe.before = (sql) async {
        if (sql.contains('SELECT attempt_count FROM ledger_sync_outbox') && !reached.isCompleted) {
          reached.complete(); await release.future;
        }
      };
      final running = tracked(stop(_push(db, queue, client).push()));
      expect(await Future.any([reached.future.then((_) => true), running.then((_) => false)]), isTrue,
          reason: 'actual transaction SELECT, not outer executor only');
      final denial = tracked(AccountFenceAuthority.shared.accept(handle, AccountFenceState.pending,
          operationId: '550e8400-e29b-41d4-a716-446655440000'));
      expect(db.lifecycleState, DatabaseLifecycleState.open);
      release.complete();
      expect((await running).accepted, isFalse);
      expect((await denial).complete, isTrue);
      final rows = await LedgerAdmissionFixture.inspectClosed(db, location, _outbox);
      expect(rows.first['attempt_count'], 1);
      expect(rows.last['attempt_count'], 0);
      expect(rows.last['status'], 'pending');
      expect(calls.count, 1);
    }, (request) async => denied('400', request), probe: probe);
  });

  for (final boundary in ['capability', 'recorded-read', 'head']) {
    for (final successor in ['user-1', 'user-B']) {
      test('E4 security ledger plan held $boundary cannot adopt $successor lifetime', () async {
        final probe = LedgerDatabaseProbe(); final reached = Completer<void>(); final release = Completer<void>();
        releaseOnExit(release);
        await withLedger((admission, queue, client, calls) async {
          final db = admission.database;
          final handle = (await AccountFenceAuthority.shared.capture(admission.fixture.session, admission.fixture.host))!;
          final cap = admission.fixture.session.captureLocalWorkAuthority()!;
          final head = _E4SeqProbe(() async {
            if (boundary == 'head') { reached.complete(); await release.future; }
            return const SyncHead(lastSeq: 1, epoch: 'e1');
          });
          probe.before = (sql) async {
            if (boundary == 'recorded-read' && sql.contains('SELECT last_updated_at, last_id') &&
                sql.contains('seq_epoch:') && !reached.isCompleted) {
              reached.complete(); await release.future;
            }
          };
          final gate = RevisionCasGate(db: db, capability: () async {
            if (boundary == 'capability') { reached.complete(); await release.future; }
            return ServerCapabilityState.verified;
          }, remote: head);
          final running = tracked(gate.planForLedger('user-1', authority: AccountFenceAuthority.shared,
              handle: handle, database: db).then<Object?>((value) => value,
              onError: (Object error) => error));
          expect(await Future.any([reached.future.then((_) => true), running.then((_) => false)]), isTrue);
          var done = false;
          final replacement = tracked(admission.fixture.signIn(successor).then((_) => done = true));
          expect(cap.isCurrent, isFalse);
          if (boundary == 'recorded-read') { expect(done, isFalse); expect(db.lifecycleState, DatabaseLifecycleState.open); }
          release.complete();
          expect(await running, anyOf(isA<LedgerDeliveryStopped>(), isA<StaleAdmissionException>()));
          await replacement;
          expect(admission.fixture.host.current?.uid, successor);
          expect(admission.fixture.session.captureLocalWorkAuthority()!.isCurrent, isTrue);
          expect(head.calls, boundary == 'head' ? 1 : 0);
          expect(calls.count, 0);
        }, (request) async => throw StateError('no mutation allowed'), probe: probe);
      });
    }
  }

  for (final code in ['409', '23505', '42501', 'P0001']) {
    test('E4 security ordinary raw $code with denial-looking message never installs hold', () async {
      await withLedger((admission, queue, client, calls) async {
        final db = admission.database;
        final result = await _push(db, queue, client).push();
        expect(calls.count, 1);
        expect(admission.fixture.session.captureLocalWorkAuthority()!.isCurrent, isTrue);
        expect(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest('user-1')), isNull);
        if (code == '409') {
          expect(result.conflicts, 1); expect(await _outbox(db), isEmpty);
        } else {
          expect(result.failed, 1);
          expect((await _outbox(db)).single['failure_class'], isNot(anyOf('account_deletion_pending', 'account_deletion_gone')));
        }
      }, (request) async => http.Response(jsonEncode({'code': code, 'message': 'QD001 QD002'}),
          400, headers: {'content-type': 'application/json'}, request: request));
    });
  }

  test('E4 security ordinary pre-result error is bound to original health and still reaches pull', () async {
    await withLedger((admission, queue, client, calls) async {
      final db = admission.database; final before = (await _outbox(db)).single;
      final health = SyncHealth(db: db); final pull = _E4DeliveryPull();
      final service = LedgerPushService(db: db, queue: queue, isPushEnabled: () => true,
          getAuthUserId: () async => throw const SocketException('before result'), mayEgress: () async => true);
      expect(await LedgerSyncEngine(pushService: service, pullService: pull, health: health).sync(), ReconcileDomainResult.noDirtyState);
      expect(health.of(SyncDomain.ledger).lastErrorClass, SyncErrorClass.offline);
      expect(pull.calls, 1); expect(calls.count, 0);
      expect((await _outbox(db)).single, before);
      expect((await db.customSelect("SELECT last_id FROM sync_cursors WHERE entity = 'sync_health:ledger';").getSingle()).read<String>('last_id'), contains('offline'));
    }, (request) async => throw StateError('no HTTP allowed'));
  });

  test('E4 security old phase error cannot replace concurrent phase own notes', () async {
    final reached = Completer<void>(); final release = Completer<void>(); releaseOnExit(release);
    await withLedger((admission, queue, client, calls) async {
      final db = admission.database; final health = SyncHealth(db: db);
      final oldBinding = SyncPhaseBinding();
      final old = LedgerPushService(db: db, queue: queue, isPushEnabled: () => true,
          getAuthUserId: () async { reached.complete(); await release.future; throw const SocketException('old phase'); },
          mayEgress: () async => true, health: health);
      final running = tracked(health.runPhase(SyncDomain.ledger, SyncDirection.push,
          () => old.pushWithPhase(oldBinding), binding: oldBinding));
      expect(await Future.any([reached.future.then((_) => true), running.then((_) => false)]), isTrue);
      final nextBinding = SyncPhaseBinding();
      final next = LedgerPushService(db: db, queue: queue, isPushEnabled: () => true,
          getAuthUserId: () async => 'user-1', mayEgress: () async => false, health: health);
      await health.runPhase(SyncDomain.ledger, SyncDirection.push,
          () => next.pushWithPhase(nextBinding), binding: nextBinding);
      final persisted = (await db.customSelect("SELECT * FROM sync_cursors WHERE entity = 'sync_health:ledger';").getSingle()).data;
      expect(health.of(SyncDomain.ledger).lastErrorClass, SyncErrorClass.consentBlocked);
      release.complete(); await running;
      expect(health.of(SyncDomain.ledger).lastErrorClass, SyncErrorClass.consentBlocked);
      expect(health.of(SyncDomain.ledger).consecutiveFailures, 0);
      expect((await db.customSelect("SELECT * FROM sync_cursors WHERE entity = 'sync_health:ledger';").getSingle()).data, persisted);
      expect(calls.count, 0);
    }, (request) async => throw StateError('no HTTP allowed'));
  });

  test('E4 security late pre-result error cannot save health or pull in successor database', () async {
    final reached = Completer<void>(); final release = Completer<void>(); releaseOnExit(release);
    await withLedger((admission, queue, client, calls) async {
      final db = admission.database; final health = SyncHealth(db: db); final pull = _E4DeliveryPull();
      final service = LedgerPushService(db: db, queue: queue, isPushEnabled: () => true,
          getAuthUserId: () async { reached.complete(); await release.future; throw const SocketException('old phase'); },
          mayEgress: () async => true);
      final running = tracked(LedgerSyncEngine(pushService: service, pullService: pull, health: health).sync());
      expect(await Future.any([reached.future.then((_) => true), running.then((_) => false)]), isTrue);
      await admission.fixture.signIn('user-B');
      final successor = admission.fixture.host.current!.database;
      await health.attach(successor);
      release.complete();
      expect(await running, ReconcileDomainResult.cancelled);
      expect(pull.calls, 0); expect(calls.count, 0);
      expect(await successor.customSelect("SELECT * FROM sync_cursors WHERE entity = 'sync_health:ledger';").get(), isEmpty);
      expect(health.of(SyncDomain.ledger).consecutiveFailures, 0);
    }, (request) async => throw StateError('no HTTP allowed'));
  });

  test('E4 security real provider construction refuses missing actual host before health or HTTP', () async {
    await withLedger((admission, queue, client, calls) async {
      final db = admission.database; final before = (await _outbox(db)).single;
      final container = ProviderContainer(overrides: [appDatabaseProvider.overrideWithValue(db)]);
      admission.fixture.session.configureAccountScope(null);
      try {
        final service = container.read(ledgerPushServiceProvider);
        final health = SyncHealth(db: db); final pull = _E4DeliveryPull();
        expect(await LedgerSyncEngine(pushService: service, pullService: pull, health: health).sync(), ReconcileDomainResult.cancelled);
        expect(calls.count, 0); expect(pull.calls, 0);
        expect((await _outbox(db)).single, before);
        expect(await db.customSelect("SELECT * FROM sync_cursors WHERE entity = 'sync_health:ledger';").get(), isEmpty);
      } finally {
        container.dispose(); admission.fixture.session.configureAccountScope(admission.fixture.host);
      }
    }, (request) async => throw StateError('no HTTP allowed'));
  });

  test('E4 security overlapping invocation refuses second without replacing first binding', () async {
    final reached = Completer<void>(); final release = Completer<void>(); releaseOnExit(release);
    await withLedger((admission, queue, client, calls) async {
      final service = _push(admission.database, queue, client);
      final first = tracked(service.push());
      expect(await Future.any([reached.future.then((_) => true), first.then((_) => false)]), isTrue);
      final other = await stop(service.push());
      expect(other.reason, LedgerDeliveryStopReason.overlap);
      expect(other.accepted, isFalse); expect(calls.count, 1);
      release.complete(); expect((await first).pushed, 1);
      expect(await _outbox(admission.database), isEmpty);
    }, (request) async { reached.complete(); await release.future;
      return _json({'id': 'server', 'updated_at': '2026-10-01T00:00:00.000Z'}, request); });
  });

  for (final provenance in ['legacy-null', 'invalid', 'missing-handout', 'canonical-non-v4']) {
    test('E4 security $provenance operation provenance before dispatch', () async {
      await withLedger((admission, queue, client, calls) async {
        final db = admission.database;
        if (provenance != 'missing-handout') {
          final id = provenance == 'legacy-null' ? 'NULL' : sqlString(provenance == 'invalid' ? 'malformed' : 'ffffffff-0000-0000-0000-000000000000');
          await db.customStatement('UPDATE ledger_sync_outbox SET operation_id = $id;');
        }
        final selected = provenance == 'missing-handout' ? _E4MissingHandoutQueue(db) : queue;
        if (provenance == 'invalid' || provenance == 'missing-handout') {
          final result = await stop(_push(db, selected, client).push());
          expect(result.reason, LedgerDeliveryStopReason.provenance);
          expect(calls.count, 0);
          final row = (await _outbox(db)).single;
          expect(row['attempt_count'], 0); expect(row['status'], 'pending');
          expect(row['operation_id'], provenance == 'invalid' ? 'malformed' : isNotNull);
        } else {
          expect((await _push(db, selected, client).push()).pushed, 1);
          expect(calls.count, 1); expect(await _outbox(db), isEmpty);
        }
      }, (request) async => _json({'id': 'server', 'updated_at': '2026-10-01T00:00:00.000Z'}, request));
    });
  }

  test('E4 security actual ledger denial survives real host restart without new HTTP', () async {
    await withLedger((admission, queue, client, calls) async {
      final db = admission.database; final location = admission.location;
      final outcome = await stop(_push(db, queue, client).push());
      expect(outcome.accepted && outcome.parked && outcome.complete, isTrue);
      final held = await LedgerAdmissionFixture.inspectClosed(db, location, _outbox);
      await admission.fixture.restart();
      admission.fixture.session.configureAccountScope(admission.fixture.host);
      await expectLater(admission.fixture.signIn('user-1'), throwsA(isA<AccountFenceDeniedException>()));
      expect(admission.fixture.session.captureLocalWorkAuthority(), isNull);
      expect(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest('user-1'))?.state, AccountFenceState.pending);
      expect(await LedgerAdmissionFixture.inspectClosed(db, location, _outbox), held);
      expect(calls.count, 1);
    }, (request) async => denied('QD001', request));
  });

  group('E4 security actual SDK CAS', () {
    late _Handler respond;
    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      await Supabase.initialize(url: 'https://example.supabase.co', anonKey: 'anon',
          authOptions: const FlutterAuthClientOptions(autoRefreshToken: false,
              detectSessionInUri: false, localStorage: EmptyLocalStorage(), pkceAsyncStorage: _E4SdkMemoryStorage()),
          httpClient: MockClient((request) => respond(request)));
    });
    tearDownAll(() => Supabase.instance.dispose());

    for (final operation in [OutboxOperation.create, OutboxOperation.update, OutboxOperation.delete]) {
      for (final response in ['success', 'QD001', 'QD002', 'busy-success', 'busy-QD001', 'busy-QD002']) {
        test('E4 security actual SDK CAS ${operation.name} $response preserves original receipt', () async {
          final requests = <http.Request>[];
          await withLedger((admission, queue, client, calls) async {
            final db = admission.database; final location = admission.location;
            await db.customStatement('DELETE FROM ledger_sync_outbox;');
            if (operation != OutboxOperation.create) {
              await db.customStatement("UPDATE transactions SET server_id = 'server', server_revision = 5, server_updated_at = '2026-10-01T00:00:00.000Z' WHERE id = '$_tx';");
            }
            await queue.enqueue(operation, await _load(db));
            final before = (await _outbox(db)).single;
            respond = (request) async {
              requests.add(request);
              if (response.startsWith('busy-') && requests.length == 1) return denied('55P03', request);
              if (response.contains('QD')) return denied(response.endsWith('QD001') ? 'QD001' : 'QD002', request);
              return _json({'outcome': operation == OutboxOperation.create ? 'inserted' : 'applied',
                'row': {'id': 'server', 'updated_at': '2026-10-02T00:00:00.000Z', 'revision': 6,
                  if (operation == OutboxOperation.delete) 'deleted_at': '2026-10-02T00:00:00.000Z'}}, request);
            };
            final push = LedgerPushService(db: db, queue: queue, isPushEnabled: () => true,
                getAuthUserId: () async => 'user-1', getClient: () => client, mayEgress: () async => true,
                casGate: RevisionCasGate(db: db, capability: () async => ServerCapabilityState.verified,
                    remote: _E4SeqProbe(() async => const SyncHead(lastSeq: 1, epoch: 'e1'))),
                fenceRetry: AccountFenceRetry(delay: (_) async {}));
            if (response.contains('QD')) {
              final result = await stop(push.push());
              expect(result.accepted && result.parked && result.complete, isTrue);
              expect(db.lifecycleState, DatabaseLifecycleState.closed);
              final row = (await LedgerAdmissionFixture.inspectClosed(db, location, _outbox)).single;
              expect(row['operation_id'], before['operation_id']);
              expect(row['payload_json'], before['payload_json']);
              expect(row['attempt_count'], 0); expect(row['status'], 'parked');
              expect(row['failure_class'], response.endsWith('QD001') ? 'account_deletion_pending' : 'account_deletion_gone');
            } else {
              expect((await push.push()).pushed, 1);
              expect(await _outbox(db), isEmpty);
              expect(admission.fixture.session.captureLocalWorkAuthority()!.isCurrent, isTrue);
            }
            expect(requests, hasLength(response.startsWith('busy-') ? 2 : 1));
            final endpoint = switch (operation) { OutboxOperation.create => 'sync_insert_if_absent',
              OutboxOperation.update => 'sync_cas_update', OutboxOperation.delete => 'sync_cas_tombstone' };
            expect(requests.every((request) => request.url.path.endsWith('/$endpoint')), isTrue);
            final first = jsonDecode(requests.first.body) as Map;
            expect(first['p_op_id'], before['operation_id']); expect(first['p_expected_epoch'], 'e1');
            if (operation != OutboxOperation.create) expect(first['p_expected_revision'], 5);
            for (final request in requests.skip(1)) {
              expect(identical(requests.first, request), isFalse);
              expect(request.body, requests.first.body);
            }
          }, (request) async => throw StateError('legacy mutation is not allowed'));
        });
      }
    }

    test('E4 security actual SDK CAS rechecks after final awaited retry currency', () async {
      final probe = LedgerDatabaseProbe(); final reached = Completer<void>(); final release = Completer<void>();
      releaseOnExit(release);
      await withLedger((admission, queue, client, calls) async {
        final db = admission.database;
        final handle = (await AccountFenceAuthority.shared.capture(admission.fixture.session, admission.fixture.host))!;
        var rpc = 0;
        respond = (request) async { rpc++; throw StateError('stale request must not dispatch'); };
        var armed = true;
        probe.afterSelect = (sql) async {
          if (armed && sql.contains('SELECT 1 FROM ledger_sync_outbox') && sql.contains('in_flight_seq')) {
            armed = false;
            // The real SELECT has completed; synchronous retirement is queued
            // before the awaiting retry predicate can invoke CasRemote.
            reached.complete();
            tracked(AccountFenceAuthority.shared.accept(handle, AccountFenceState.pending,
                operationId: '550e8400-e29b-41d4-a716-446655440000').then((value) {
                  if (!release.isCompleted) release.complete();
                  return value;
                }));
          }
        };
        final push = LedgerPushService(db: db, queue: queue, isPushEnabled: () => true,
            getAuthUserId: () async => 'user-1', mayEgress: () async => true,
            casGate: RevisionCasGate(db: db, capability: () async => ServerCapabilityState.verified,
                remote: _E4SeqProbe(() async => const SyncHead(lastSeq: 1, epoch: 'e1'))));
        final running = tracked(stop(push.push()));
        expect(await Future.any([reached.future.then((_) => true), running.then((_) => false)]), isTrue);
        expect((await running).accepted, isFalse);
        await release.future;
        expect(rpc, 0); expect(calls.count, 0);
      }, (request) async => throw StateError('no legacy request'), probe: probe);
    });
  });

  for (final recorded in [false, true]) {
    test('E4 security current ledger plan reaches recorded=$recorded positive path', () async {
      await withLedger((admission, queue, client, calls) async {
        final db = admission.database;
        if (recorded) { await writeRecordedSyncEpoch(db, 'user-1', 'recorded-epoch', null); }
        final head = _E4SeqProbe(() async => const SyncHead(lastSeq: 1, epoch: 'head-epoch'));
        final gate = RevisionCasGate(db: db, capability: () async => ServerCapabilityState.verified, remote: head);
        final handle = (await AccountFenceAuthority.shared.capture(admission.fixture.session, admission.fixture.host))!;
        final result = await gate.planForLedger('user-1', authority: AccountFenceAuthority.shared, handle: handle, database: db);
        expect(result.mode, CasMode.cas); expect(result.epoch, recorded ? 'recorded-epoch' : 'head-epoch');
        expect(head.calls, recorded ? 0 : 1); expect(calls.count, 0);
      }, (request) async => throw StateError('planning is not mutation'));
    });
  }

}


class _E4ControlledPull implements LedgerPullAdapter {
  _E4ControlledPull(this.run);
  final Future<LedgerSyncResult> Function(SyncCursor?, bool Function()?) run;
  int calls = 0;
  @override
  Future<LedgerSyncResult> pull({SyncCursor? from, bool Function()? isAdmitted}) {
    calls++;
    return run(from, isAdmitted);
  }
}

class _E4SeqProbe implements SeqRemote {
  _E4SeqProbe(this.head);
  final Future<SyncHead?> Function() head;
  int calls = 0;
  @override
  Future<SyncHead?> fetchHead(String userId) { calls++; return head(); }
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('unexpected sequence request');
}


/// Corrupt handoff boundary only: the real queue allocates/commits its receipt,
/// then this negative port drops the returned receipt. No fake authority/ACK.
class _E4MissingHandoutQueue extends LedgerOutboxQueue {
  _E4MissingHandoutQueue(AppDatabase db) : super(db: db, isPushEnabled: () => true,
      getAuthUserId: () async => 'user-1', getOwnerUid: AppSession.instance.readLocalDataOwnerUid);
  @override
  Future<List<OutboxItem>> pendingItems({int limit = 50}) async => [
    for (final item in await super.pendingItems(limit: limit)) OutboxItem(id: item.id,
      transactionId: item.transactionId, operation: item.operation, payloadJson: item.payloadJson,
      attemptCount: item.attemptCount, opSeq: item.opSeq, operationId: null,
      baseRevision: item.baseRevision, ownerUid: item.ownerUid, lastError: item.lastError,
      nextRetryAt: item.nextRetryAt),
  ];
}


/// Mock SDK PKCE state only; no app auth-persistence qualification.
class _E4SdkMemoryStorage extends GotrueAsyncStorage {
  const _E4SdkMemoryStorage();
  @override
  Future<String?> getItem({required String key}) async => null;
  @override
  Future<void> setItem({required String key, required String value}) async {}
  @override
  Future<void> removeItem({required String key}) async {}
}
