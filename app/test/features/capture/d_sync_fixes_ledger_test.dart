import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/sync/outbox_failure.dart';
import 'package:money_companion/core/sync/conflict_resolver.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/planning_cutover.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/data/sync/exact_transport_capability.dart';
import 'package:money_companion/data/sync/server_capabilities.dart';
import 'package:money_companion/features/capture/services/ledger_outbox_queue.dart';
import 'package:money_companion/features/capture/services/ledger_push_service.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Phase D sync fixes (ledger): D-1 conflict never loses the base token / never
/// flips to synced, D-3 awaiting-FX park honours op_seq, D-6 parked-in-flight
/// create is converted (not dropped) by a delete, D-7 cold-start auth re-arm,
/// D-9 owner-scoped coalescing.
class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

const _tx = 'tx-001';
const _base = '2026-06-01T10:00:00.000Z';

Future<void> _insertTx(AppDatabase db,
    {String id = _tx,
    String? serverId,
    String? serverUpdatedAt,
    double amount = 100.0,
    bool foreign = false}) async {
  final now = dateTimeToSql(DateTime.now().toUtc());
  final occurred = dateTimeToSql(DateTime.utc(2026, 6, 1, 10));
  await db.customStatement('''
    INSERT INTO transactions(
      id, amount, currency, type, source, occurred_at, raw_message,
      parse_confidence, status, created_at, updated_at, note
      ${serverId == null ? '' : ', server_id'}
      ${serverUpdatedAt == null ? '' : ', server_updated_at'}
      ${foreign ? ', foreign_amount, foreign_currency' : ''}
    ) VALUES (
      '$id', $amount, 'SAR', 'payment', 'bank', '$occurred', '', 0.9, 'confirmed',
      '$now', '$now', 'original'
      ${serverId == null ? '' : ", '$serverId'"}
      ${serverUpdatedAt == null ? '' : ", '$serverUpdatedAt'"}
      ${foreign ? ", 100.0, 'USD'" : ''}
    );
  ''');
  await backfillNonPlanningMoneyV30(db);
}

Future<String> _status(AppDatabase db, [String id = _tx]) async => (await db
        .customSelect("SELECT sync_status AS s FROM transactions WHERE id = '$id';")
        .getSingle())
    .read<String>('s');

Future<List<Map<String, Object?>>> _outbox(AppDatabase db) async => [
      for (final r in await db
          .customSelect('SELECT * FROM ledger_sync_outbox ORDER BY created_at;')
          .get())
        r.data
    ];

Map<String, dynamic> _payload(Map<String, Object?> row) =>
    jsonDecode(row['payload_json'] as String) as Map<String, dynamic>;

typedef _Handler = Future<http.Response> Function(http.Request request);

SupabaseClient _client(List<http.Request> calls, _Handler handler) =>
    SupabaseClient(
      'https://example.supabase.co',
      'public-anon-key',
      accessToken: () async => 'qa-access-token',
      httpClient: MockClient((request) async {
        calls.add(request);
        return handler(request);
      }),
    );

http.Response _json(Object body, http.Request request) => http.Response(
      jsonEncode(body),
      200,
      headers: const {'content-type': 'application/json'},
      request: request,
    );

LedgerPushService _push(AppDatabase db, LedgerOutboxQueue queue,
        SupabaseClient client,
        {String? uid = 'user-1', ServerCapabilitiesService? capabilities}) =>
    LedgerPushService(
      db: db,
      queue: queue,
      isPushEnabled: () => true,
      getAuthUserId: () async => uid,
      getClient: () => client,
      mayEgress: () async => true,
      capabilities: capabilities,
    );

LedgerOutboxQueue _queue(AppDatabase db, {String auth = 'user-1'}) =>
    LedgerOutboxQueue(
      db: db,
      isPushEnabled: () => true,
      getAuthUserId: () async => auth,
    );

/// Folds an edit into the row right before the push parks it (the race window
/// between hand-out and park).
class _EditBeforeParkQueue extends LedgerOutboxQueue {
  _EditBeforeParkQueue({required AppDatabase db})
      : _db = db,
        super(
            db: db,
            isPushEnabled: () => true,
            getAuthUserId: () async => 'user-1');
  final AppDatabase _db;
  @override
  Future<bool> park(String id, String reason, {int? ifOpSeq}) async {
    await _db.customStatement(
        'UPDATE ledger_sync_outbox SET op_seq = op_seq + 1 WHERE id = \'$id\';');
    return super.park(id, reason, ifOpSeq: ifOpSeq);
  }
}

Future<TransactionEntity> _load(AppDatabase db, [String id = _tx]) async =>
    (await DriftTransactionRepository(db).getById(id))!;

void main() {
  late AppDatabase db;

  setUp(() async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
  });
  tearDown(() async {
    outboxHasValidSession = () => false;
    await db.close();
  });

  group('D-1 conflict with an in-flight edit', () {
    test(
        'keeps the base token, is not pushed while in conflict, and the entity '
        'is never flipped to synced', () async {
      await _insertTx(db, serverId: 'srv-1', serverUpdatedAt: _base);
      final queue = _queue(db);
      await queue.enqueue(OutboxOperation.update, await _load(db));
      final tokenBefore =
          _payload((await _outbox(db)).single)['server_updated_at'];
      expect(tokenBefore, isNotNull);

      final calls = <http.Request>[];
      final client = _client(calls, (request) async {
        // The user edits again while the guarded PATCH is on the wire; the
        // server answers 0 rows (another device moved the row).
        await db.customStatement(
            "UPDATE transactions SET note = 'in flight' WHERE id = '$_tx';");
        await queue.enqueue(OutboxOperation.update, await _load(db));
        return _json(<Object>[], request);
      });
      final service = _push(db, queue, client);

      final first = await service.push();
      expect(first.conflicts, 1);
      expect(await _status(db), 'conflict');
      final rows = await _outbox(db);
      expect(rows, hasLength(1), reason: 'the folded edit survives the conflict');
      expect(_payload(rows.single)['server_updated_at'], tokenBefore,
          reason: 'D-1: the base token must NOT be stripped');

      final before = calls.length;
      final second = await service.push();
      expect(calls.length, before,
          reason: 'a conflicted entity is held for the user, never re-pushed');
      expect(second.pushed, 0);
      expect(await _status(db), 'conflict');
      expect(await _outbox(db), hasLength(1));
    });

    test('a successful ACK never flips a conflict entity to synced', () async {
      await _insertTx(db, serverId: 'srv-1', serverUpdatedAt: _base);
      final queue = _queue(db);
      await queue.enqueue(OutboxOperation.update, await _load(db));
      final client = _client(<http.Request>[], (request) async {
        // Another path flags the entity as conflicted while the push is in flight.
        await db.customStatement(
            "UPDATE transactions SET sync_status = 'conflict' WHERE id = '$_tx';");
        return _json([
          {'updated_at': 't2'}
        ], request);
      });
      await _push(db, queue, client).push();
      expect(await _status(db), 'conflict');
    });
  });

  group('D-3 awaiting-FX park honours op_seq', () {
    test('a priced edit folded in during the capability RPC stays pending',
        () async {
      await _insertTx(db, amount: 0, foreign: true);
      final queue = _queue(db);
      await queue.enqueue(OutboxOperation.create, await _load(db));

      late final SupabaseClient client;
      var edited = false;
      client = _client(<http.Request>[], (request) async {
        if (request.url.path.endsWith('/rpc/qirsh_server_capabilities') &&
            !edited) {
          edited = true;
          // The user prices the transaction while the probe is in flight.
          await db.customStatement(
              "UPDATE transactions SET amount = 375.0 WHERE id = '$_tx';");
          await backfillNonPlanningMoneyV30(db);
          await queue.enqueue(OutboxOperation.update, await _load(db));
          return http.Response(
              jsonEncode({'code': 'PGRST202', 'message': 'missing'}), 404,
              headers: const {'content-type': 'application/json'},
              request: request);
        }
        return _json({'id': 'srv-1', 'updated_at': 't1'}, request);
      });
      final caps = ServerCapabilitiesService(
        getAuthUserId: () async => 'user-1',
        getClient: () => client,
        mayEgress: () async => true,
        getServerUrl: () => 'https://example.supabase.co',
      );
      final result = await _push(db, queue, client, capabilities: caps).push();
      expect(result.parked, 0);
      final row = (await _outbox(db)).single;
      expect(row['status'], 'pending',
          reason: 'a row edited in flight must not be parked awaiting FX');
    });
  });

  group('D-6 delete converts a possibly-in-flight parked create', () {
    test('create handed to a push, parked owner_mismatch, then deleted',
        () async {
      await _insertTx(db);
      final queue = _queue(db);
      await queue.enqueue(OutboxOperation.create, await _load(db));
      // Handed to a push (durable in_flight_seq) whose ack was lost…
      expect(await queue.pendingItems(), hasLength(1));
      // …then the row got parked (identity switch) with the marker intact.
      await queue.reconcileOwnership('someone-else');
      final row = (await _outbox(db)).single;
      expect(row['status'], 'parked');
      expect(row['in_flight_seq'], isNotNull);

      await queue.enqueue(OutboxOperation.delete, await _load(db));
      final rows = await _outbox(db);
      expect(rows, hasLength(1), reason: 'the possibly-sent create must not be dropped');
      expect(rows.single['operation'], 'delete');
      expect(rows.single['status'], 'pending');
    });

    test('a parked create that was never handed to a push still cancels',
        () async {
      await _insertTx(db);
      final queue = _queue(db);
      await queue.enqueue(OutboxOperation.create, await _load(db));
      await queue.reconcileOwnership('someone-else');
      await queue.enqueue(OutboxOperation.delete, await _load(db));
      expect(await _outbox(db), isEmpty);
    });
  });

  group('D-7 cold-start auth re-arm', () {
    test('a push cycle with a valid session re-arms auth_required rows',
        () async {
      await _insertTx(db);
      final queue = _queue(db);
      await queue.enqueue(OutboxOperation.create, await _load(db));
      await db.customStatement(
          "UPDATE ledger_sync_outbox SET status = 'parked', "
          "failure_class = '$kParkAuthRequired';");
      outboxHasValidSession = () => true;
      final calls = <http.Request>[];
      final client = _client(calls,
          (request) async => _json({'id': 'srv-1', 'updated_at': 't1'}, request));
      final result = await _push(db, queue, client).push();
      expect(result.pushed, 1, reason: 'the parked row was re-armed and sent');
      expect(await _outbox(db), isEmpty);
    });

    test('without a valid session auth_required rows stay parked', () async {
      await _insertTx(db);
      final queue = _queue(db);
      await queue.enqueue(OutboxOperation.create, await _load(db));
      await db.customStatement(
          "UPDATE ledger_sync_outbox SET status = 'parked', "
          "failure_class = '$kParkAuthRequired';");
      outboxHasValidSession = () => false;
      final client = _client(<http.Request>[],
          (request) async => _json({'id': 'srv-1', 'updated_at': 't1'}, request));
      final result = await _push(db, queue, client).push();
      expect(result.pushed, 0);
      expect((await _outbox(db)).single['status'], 'parked');
    });
  });

  group('D-9 owner-scoped coalescing', () {
    test('user B never folds into user A\'s parked row; B pushes under B',
        () async {
      await _insertTx(db, serverId: 'srv-1', serverUpdatedAt: _base);
      final qa = _queue(db, auth: 'user-A');
      await qa.enqueue(OutboxOperation.update, await _load(db));
      await db.customStatement(
          "UPDATE transactions SET note = 'A edit' WHERE id = '$_tx';");
      // B signs in: A's row is parked owner_mismatch by the cycle start.
      final qb = _queue(db, auth: 'user-B');
      await qb.reconcileOwnership('user-B');
      expect((await _outbox(db)).single['failure_class'], 'owner_mismatch');
      final aPayload = (await _outbox(db)).single['payload_json'];

      await db.customStatement(
          "UPDATE transactions SET note = 'B edit' WHERE id = '$_tx';");
      await qb.enqueue(OutboxOperation.update, await _load(db));

      final rows = await _outbox(db);
      expect(rows, hasLength(2), reason: 'a separate B row, never folded');
      final a = rows.firstWhere((r) => r['owner_uid'] == 'user-A');
      final b = rows.firstWhere((r) => r['owner_uid'] == 'user-B');
      expect(a['payload_json'], aPayload, reason: 'A payload untouched');
      expect(a['status'], 'parked');
      expect(b['status'], 'pending');
      expect(_payload(b)['note'], 'B edit');

      final calls = <http.Request>[];
      final client = _client(calls, (request) async {
        return _json([
          {'updated_at': 't2'}
        ], request);
      });
      final res = await _push(db, qb, client, uid: 'user-B').push();
      expect(res.pushed, 1);
      expect(calls.where((c) => c.body.contains('B edit')), isNotEmpty);
      expect(calls.where((c) => c.body.contains('A edit')), isEmpty);
      final left = await _outbox(db);
      expect(left.single['owner_uid'], 'user-A');
      expect(left.single['status'], 'parked');
    });
  });

  group('D follow-up: exact-money park honours op_seq', () {
    test('an edit folded in before the park leaves the row pending', () async {
      await _insertTx(db);
      final queue = _EditBeforeParkQueue(db: db);
      await queue.enqueue(OutboxOperation.create, await _load(db));
      final service = LedgerPushService(
        db: db,
        queue: queue,
        isPushEnabled: () => true,
        getAuthUserId: () async => 'user-1',
        getClient: () => _client(<http.Request>[], (r) async => _json({}, r)),
        mayEgress: () async => true,
        coordinator:
            const FixedPlanningCutoverCoordinator(PlanningCutoverState.canonical),
        pushCapability: () => ExactTransportCapability.unknown,
      );
      final res = await service.push();
      expect(res.parked, 0);
      expect((await _outbox(db)).single['status'], 'pending');
    });
  });

  group('D follow-up: pull-raised conflict vs in-flight marker', () {
    test('keep-remote refuses during a genuinely in-progress push', () async {
      await _insertTx(db, serverId: 'srv-1', serverUpdatedAt: _base);
      final queue = _queue(db);
      await queue.enqueue(OutboxOperation.update, await _load(db));
      expect(await queue.pendingItems(), hasLength(1)); // push in progress
      await db.customStatement(
          "UPDATE transactions SET sync_status = 'conflict' WHERE id = '$_tx';");
      final resolver = UniversalConflictResolver(db: db, reEnqueue: const {});
      expect(await resolver.resolveKeepRemote('transaction', _tx), isFalse);
      expect(await _outbox(db), hasLength(1));
    });
  });
}
