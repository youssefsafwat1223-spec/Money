import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/sync/outbox_failure.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_repository_support.dart';
import 'package:money_companion/domain/entities/card_entity.dart';
import 'package:money_companion/engine/parser/card_network.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';
import 'package:money_companion/features/planning_sync/services/planning_push_service.dart';

/// Phase D sync fixes (planning): D-1 conflict keeps the base token and is held,
/// D-2 consent-only create is never replaced by an automatic settings write,
/// D-6 a lost-ack card create is converted (not dropped) by a delete, D-7 auth
/// re-arm at cycle start, D-9 owner-scoped coalescing.
class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

class _Sink implements PlanningRemoteSink {
  int calls = 0;
  final upserts = <Map<String, dynamic>>[];
  final updates = <Map<String, dynamic>>[];
  Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)? onUpsert;
  Future<Map<String, dynamic>?> Function(
      String, String, String, Map<String, dynamic>)? onGuardedUpdate;

  @override
  Future<Map<String, dynamic>> upsert(
      String table, Map<String, dynamic> row) async {
    calls++;
    upserts.add(row);
    return onUpsert!(table, row);
  }

  @override
  Future<Map<String, dynamic>?> guardedUpdateByServerId(String table,
      String serverId, String expectedUpdatedAt, Map<String, dynamic> row) async {
    calls++;
    updates.add(row);
    return onGuardedUpdate!(table, serverId, expectedUpdatedAt, row);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls++;
    throw UnimplementedError('unexpected remote call: ${invocation.memberName}');
  }
}

Future<List<Map<String, Object?>>> _outbox(AppDatabase db) async => [
      for (final r in await db
          .customSelect('SELECT * FROM planning_sync_outbox ORDER BY created_at;')
          .get())
        r.data
    ];

Map<String, dynamic> _payload(Map<String, Object?> r) =>
    jsonDecode(r['payload_json'] as String) as Map<String, dynamic>;

PlanningOutboxQueue _queue(AppDatabase db, {String auth = 'user-1'}) =>
    PlanningOutboxQueue(
      db: db,
      isSyncEnabled: (_) => true,
      getAuthUserId: () async => auth,
    );

PlanningPushService _push(AppDatabase db, PlanningOutboxQueue queue, _Sink sink,
        {String uid = 'user-1', bool consent = true}) =>
    PlanningPushService(
      db: db,
      queue: queue,
      isEnabled: (_) => true,
      getAuthUserId: () async => uid,
      remoteSink: sink,
      mayEgress: () async => consent,
      mayEgressProfile: () async => consent,
    );

Future<void> _insertGoal(AppDatabase db,
    {String? serverId, String? serverUpdatedAt, String name = 'goal'}) async {
  await db.customStatement('''
    INSERT INTO goals(id,name,target_amount,saved_amount,currency,
      target_amount_minor,saved_amount_minor,last_notified_saved_amount_minor,
      vault_skin,status,created_at,server_id,server_updated_at,sync_status)
    VALUES ('goal-1','$name',100,0,'EGP',10000,0,0,'classic','active',
      '2026-07-23T09:00:00.000Z',
      ${serverId == null ? 'NULL' : "'$serverId'"},
      ${serverUpdatedAt == null ? 'NULL' : "'$serverUpdatedAt'"},'synced');
  ''');
}

Future<void> _enqueueGoal(AppDatabase db, PlanningOutboxQueue q,
    PlanningSyncOperation op) async {
  final row = await db.customSelect("SELECT * FROM goals WHERE id = 'goal-1';").getSingle();
  await q.enqueueGoal(op, goalFromRow(row));
}

Future<String> _goalStatus(AppDatabase db) async => (await db
        .customSelect("SELECT sync_status AS s FROM goals WHERE id = 'goal-1';")
        .getSingle())
    .read<String>('s');

CardEntity _card({String? accountId}) => CardEntity(
      id: 'card-1',
      accountId: accountId,
      last4: '4242',
      network: CardNetwork.visa,
      source: CardSource.manual,
      createdAt: DateTime.utc(2026, 7, 1),
      updatedAt: DateTime.utc(2026, 7, 1),
    );

Future<void> _insertCard(AppDatabase db) => db.customStatement('''
  INSERT INTO cards(id, account_id, last4, network, source, created_at, updated_at)
  VALUES ('card-1', NULL, '4242', 'visa', 'manual', '2026-07-01T00:00:00Z', '2026-07-01T00:00:00Z');
''');

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
    test('keeps the base token, is held while in conflict, never synced',
        () async {
      await _insertGoal(db, serverId: 'srv-g', serverUpdatedAt: '2026-07-01T00:00:00Z');
      final queue = _queue(db);
      await _enqueueGoal(db, queue, PlanningSyncOperation.update);
      final token = _payload((await _outbox(db)).single)['server_updated_at'];
      expect(token, isNotNull);

      final sink = _Sink()
        ..onGuardedUpdate = (t, id, base, row) async {
          // The user edits while the push is in flight; the server rejects the
          // base (another device moved the row).
          await db.customStatement(
              "UPDATE goals SET name = 'edited in flight' WHERE id = 'goal-1';");
          await _enqueueGoal(db, queue, PlanningSyncOperation.update);
          return null;
        };
      final service = _push(db, queue, sink);
      final first = await service.push();
      expect(first.conflicts, 1);
      expect(await _goalStatus(db), 'conflict');
      final rows = await _outbox(db);
      expect(rows, hasLength(1));
      expect(_payload(rows.single)['server_updated_at'], token,
          reason: 'D-1: the base token must NOT be stripped');

      final before = sink.calls;
      await service.push();
      expect(sink.calls, before, reason: 'held for the user, never re-pushed');
      expect(await _goalStatus(db), 'conflict');
      expect(await _outbox(db), hasLength(1));
    });

    test('a successful ACK never flips a conflict entity to synced', () async {
      await _insertGoal(db, serverId: 'srv-g', serverUpdatedAt: '2026-07-01T00:00:00Z');
      final queue = _queue(db);
      await _enqueueGoal(db, queue, PlanningSyncOperation.update);
      final sink = _Sink()
        ..onGuardedUpdate = (t, id, base, row) async {
          await db.customStatement(
              "UPDATE goals SET sync_status = 'conflict' WHERE id = 'goal-1';");
          return {'id': 'srv-g', 'updated_at': 't2'};
        };
      await _push(db, queue, sink).push();
      expect(await _goalStatus(db), 'conflict');
    });
  });

  group('D-2 consent revocation survives an automatic settings write', () {
    test('consent-only create stays deliverable; the other write lands after bind',
        () async {
      final queue = _queue(db);
      final srow =
          await db.customSelect('SELECT * FROM user_settings LIMIT 1;').getSingle();
      final base = userSettingsFromRow(srow);
      // Consent revoked pre-bind (explicit consent change) …
      expect(
          await queue.enqueueSettings(PlanningSyncOperation.update, base,
              consentChanged: true),
          isTrue);
      // … then an automatic writer fires before the singleton is bound.
      expect(await queue.enqueueSettings(PlanningSyncOperation.update, base),
          isTrue);

      final rows = await _outbox(db);
      expect(rows, hasLength(2), reason: 'two rows: never folded together');
      final consent = rows.firstWhere((r) => _payload(r)['consent_only'] == true);
      expect(consent['status'], 'pending');
      expect(consent['operation'], 'create');
      final other = rows.firstWhere((r) => _payload(r)['consent_only'] != true);
      expect(other['status'], 'parked');
      expect(other['failure_class'], 'dependency_wait');

      // Consent is OFF: the revocation is the deliberate egress exception.
      final sink = _Sink()
        ..onUpsert = (t, row) async {
          return {'id': 'srv-s', 'updated_at': 't1'};
        }
        ..onGuardedUpdate = (t, id, b, row) async {
          return {'id': id, 'updated_at': 't2'};
        };
      await _push(db, queue, sink, consent: false).push();
      expect(sink.upserts, hasLength(1),
          reason: 'the consent-only payload reached the server');
      expect(sink.upserts.single.containsKey('display_name'), isFalse);
      expect(sink.upserts.single['cloud_processing_enabled'], isFalse);

      // Bound later (by a genuine pull): the parked write lands without consent.
      await db.customStatement(
          "UPDATE user_settings SET server_id = 'srv-s', server_updated_at = 't1';");
      await _push(db, queue, sink).push();
      expect(sink.updates, hasLength(1));
      expect(sink.updates.single.containsKey('display_name'), isTrue);
      expect(sink.updates.single.containsKey('cloud_processing_enabled'), isFalse,
          reason: 'the later write must not overwrite the consent state');
      expect(await _outbox(db), isEmpty);
    });
  });

  group('D-6 delete converts a possibly-in-flight parked create', () {
    test('lost ack -> account removed (dependency_wait) -> delete', () async {
      await _insertCard(db);
      final queue = _queue(db);
      await queue.enqueueCard(PlanningSyncOperation.create, _card(accountId: 'acc-1'));
      // The create was handed to a push whose ack was lost (marker stays set).
      expect(await queue.pendingItems(), hasLength(1));
      // The account is then removed: the card update is parked dependency_wait.
      await queue.enqueueCard(PlanningSyncOperation.update, _card());
      final row = (await _outbox(db)).single;
      expect(row['status'], 'parked');
      expect(row['in_flight_seq'], isNotNull);

      await queue.enqueueCard(PlanningSyncOperation.delete, _card());
      final rows = await _outbox(db);
      expect(rows, hasLength(1), reason: 'the possibly-sent create is not dropped');
      expect(rows.single['operation'], 'delete');
      expect(rows.single['status'], 'pending');
    });

    test('a never-sent parked accountless card is still dropped on delete',
        () async {
      await _insertCard(db);
      final queue = _queue(db);
      await queue.enqueueCard(PlanningSyncOperation.create, _card());
      expect((await _outbox(db)).single['status'], 'parked');
      await queue.enqueueCard(PlanningSyncOperation.delete, _card());
      expect(await _outbox(db), isEmpty);
    });
  });

  group('D-7 cold-start auth re-arm', () {
    test('a cycle with a valid session re-arms auth_required rows', () async {
      await _insertGoal(db);
      final queue = _queue(db);
      await _enqueueGoal(db, queue, PlanningSyncOperation.create);
      await db.customStatement("UPDATE planning_sync_outbox SET status = 'parked', "
          "failure_class = '$kParkAuthRequired';");
      outboxHasValidSession = () => true;
      final sink = _Sink()
        ..onUpsert = (t, r) async => {'id': 'srv-g', 'updated_at': 't1'};
      final res = await _push(db, queue, sink).push();
      expect(res.pushed, 1);
      expect(await _outbox(db), isEmpty);
    });

    test('no valid session: stays parked', () async {
      await _insertGoal(db);
      final queue = _queue(db);
      await _enqueueGoal(db, queue, PlanningSyncOperation.create);
      await db.customStatement("UPDATE planning_sync_outbox SET status = 'parked', "
          "failure_class = '$kParkAuthRequired';");
      final sink = _Sink()
        ..onUpsert = (t, r) async => {'id': 'srv-g', 'updated_at': 't1'};
      final res = await _push(db, queue, sink).push();
      expect(res.pushed, 0);
      expect(sink.calls, 0);
    });
  });

  group('D-9 owner-scoped coalescing', () {
    test('user B edits the settings singleton: separate row, A untouched',
        () async {
      final qa = _queue(db, auth: 'user-A');
      final srow =
          await db.customSelect('SELECT * FROM user_settings LIMIT 1;').getSingle();
      await db.customStatement(
          "UPDATE user_settings SET server_id = 'srv-s', server_updated_at = 'u0';");
      final settings = userSettingsFromRow(await db
          .customSelect('SELECT * FROM user_settings LIMIT 1;')
          .getSingle());
      expect(srow, isNotNull);
      await qa.enqueueSettings(PlanningSyncOperation.update, settings);

      final qb = _queue(db, auth: 'user-B');
      await qb.reconcileOwnership('user-B'); // parks A's row owner_mismatch
      final aPayload = (await _outbox(db)).single['payload_json'];
      expect((await _outbox(db)).single['failure_class'], 'owner_mismatch');

      await db.customStatement("UPDATE user_settings SET theme = 'dark';");
      final bSettings = userSettingsFromRow(await db
          .customSelect('SELECT * FROM user_settings LIMIT 1;')
          .getSingle());
      await qb.enqueueSettings(PlanningSyncOperation.update, bSettings);

      final rows = await _outbox(db);
      expect(rows, hasLength(2));
      final a = rows.firstWhere((r) => r['owner_uid'] == 'user-A');
      final b = rows.firstWhere((r) => r['owner_uid'] == 'user-B');
      expect(a['payload_json'], aPayload);
      expect(a['status'], 'parked');
      expect(b['status'], 'pending');
      expect(_payload(b)['theme'], 'dark');

      final sink = _Sink()
        ..onGuardedUpdate = (t, id, base, row) async =>
            {'id': id, 'updated_at': 't9'};
      final res = await _push(db, qb, sink, uid: 'user-B').push();
      expect(res.pushed, 1);
      expect(sink.updates.single['user_id'], 'user-B');
      expect(sink.updates.single['theme'], 'dark');
      final left = await _outbox(db);
      expect(left.single['owner_uid'], 'user-A');
      expect(left.single['status'], 'parked');
    });
  });
}
