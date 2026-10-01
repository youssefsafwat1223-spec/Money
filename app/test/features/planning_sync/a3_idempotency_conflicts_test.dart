import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/sync/outbox_failure.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/domain/entities/category_entity.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';
import 'package:money_companion/features/planning_sync/services/planning_push_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

/// A-3 — idempotent create (G7), typed conflict classification (G16), no blind
/// updates (G17) and the durable in-flight marker.
class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

/// A fake that models a server table with a PARTIAL unique index on
/// (user_id, local_id): INSERT of an existing local_id throws 23505.
class _Sink implements PlanningRemoteSink {
  final server = <String, Map<String, dynamic>>{}; // local_id -> row
  Object? upsertError;
  int inserts = 0;
  int lookups = 0;
  int fetches = 0;
  final guarded = <String>[];
  int blindUpdates = 0;
  bool serverMovesBeforeGuard = false;
  int _n = 0;

  @override
  Future<Map<String, dynamic>> upsert(
      String table, Map<String, dynamic> row) async {
    inserts++;
    if (upsertError != null) throw upsertError!;
    final lid = row['local_id'] as String;
    if (server.containsKey(lid)) {
      throw const PostgrestException(
          message:
              'duplicate key value violates unique constraint "user_goals_user_local_id_key"',
          code: '23505',
          details: 'Key (user_id, local_id)=(u, g1) already exists.');
    }
    server[lid] = {...row, 'id': 'srv-${++_n}', 'updated_at': 't1'};
    return {'id': server[lid]!['id'], 'updated_at': 't1'};
  }

  @override
  Future<Map<String, dynamic>?> findByLocalId(
      String table, String userId, String localId) async {
    lookups++;
    final r = server[localId];
    return r == null ? null : {'id': r['id'], 'updated_at': r['updated_at']};
  }

  @override
  Future<String?> fetchServerUpdatedAt(String table, String serverId) async {
    fetches++;
    for (final r in server.values) {
      if (r['id'] == serverId) return r['updated_at'] as String?;
    }
    return null;
  }

  @override
  Future<Map<String, dynamic>?> guardedUpdateByServerId(String table,
      String serverId, String expectedUpdatedAt, Map<String, dynamic> row) async {
    guarded.add('$serverId@$expectedUpdatedAt');
    for (final e in server.entries) {
      if (e.value['id'] == serverId) {
        if (serverMovesBeforeGuard) e.value['updated_at'] = 'moved';
        if (e.value['updated_at'] != expectedUpdatedAt) return null;
        e.value
          ..addAll(row)
          ..['updated_at'] = 't2';
        return {'id': serverId, 'updated_at': 't2'};
      }
    }
    return null;
  }

  @override
  Future<Map<String, dynamic>?> updateByServerId(
      String table, String serverId, Map<String, dynamic> row) async {
    blindUpdates++;
    return {'id': serverId, 'updated_at': 'blind'};
  }

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('unexpected ${i.memberName}');
}

Future<void> _goal(AppDatabase db, {String? serverId, String sync = 'pending'}) =>
    db.customStatement('''
      INSERT INTO goals(id,name,target_amount,saved_amount,currency,
        target_amount_minor,saved_amount_minor,last_notified_saved_amount_minor,
        vault_skin,status,created_at,server_id,sync_status)
      VALUES ('g1','goal',100,0,'EGP',10000,0,0,'classic','active',
        '2026-07-01T00:00:00Z',${serverId == null ? 'NULL' : "'$serverId'"},'$sync');
    ''');

Future<void> _goalOutbox(AppDatabase db, String op,
    {Map<String, dynamic> extra = const {}}) {
  final payload = jsonEncode({
    'local_id': 'g1',
    'name': 'goal',
    'target_amount': 100,
    'saved_amount': 0,
    'currency': 'EGP',
    ...extra,
  });
  return db.customStatement('''
    INSERT INTO planning_sync_outbox(id, entity_type, entity_id, operation,
      payload_json, attempt_count, status, created_at, updated_at, op_seq, owner_uid)
    VALUES ('o1','goal','g1','$op','$payload',0,'pending',
      '2026-07-01T00:00:00Z','2026-07-01T00:00:00Z',1,'user-1');
  ''');
}

Future<List<Map<String, Object?>>> _outbox(AppDatabase db) async => [
      for (final r in await db
          .customSelect('SELECT * FROM planning_sync_outbox;')
          .get())
        r.data
    ];

PlanningOutboxQueue _queue(AppDatabase db) => PlanningOutboxQueue(
      db: db,
      isSyncEnabled: (_) => true,
      getAuthUserId: () async => 'user-1',
    );

PlanningPushService _push(AppDatabase db, _Sink sink) => PlanningPushService(
      db: db,
      queue: _queue(db),
      isEnabled: (_) => true,
      getAuthUserId: () async => 'user-1',
      remoteSink: sink,
      mayEgress: () async => true,
      mayEgressProfile: () async => true,
    );

void main() {
  late AppDatabase db;
  setUp(() async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
  });
  tearDown(() async => db.close());

  group('G7 idempotent create on partial-index tables', () {
    test('replay of a landed create: 23505 on (user_id, local_id) -> fetch + '
        'guarded update, ACK, no duplicate, entity synced', () async {
      await _goal(db);
      await _goalOutbox(db, 'create');
      final sink = _Sink();
      // The first attempt landed but its ack was lost.
      sink.server['g1'] = {'id': 'srv-old', 'local_id': 'g1', 'updated_at': 'tOld'};

      final r = await _push(db, sink).push();
      expect(r.pushed, 1);
      expect(r.failed, 0);
      expect(r.conflicts, 0);
      expect(sink.server, hasLength(1), reason: 'no duplicate remote row');
      expect(sink.lookups, 1);
      expect(sink.guarded, ['srv-old@tOld']);
      expect(await _outbox(db), isEmpty);
      final g = (await db.customSelect("SELECT * FROM goals WHERE id='g1'").getSingle()).data;
      expect(g['sync_status'], 'synced');
      expect(g['server_id'], 'srv-old');
    });

    test('replaying the same create twice yields ONE remote row', () async {
      await _goal(db);
      await _goalOutbox(db, 'create');
      final sink = _Sink();
      await _push(db, sink).push();
      // Simulate a lost ack: the local state is rolled back to "never synced".
      await db.customStatement("UPDATE goals SET server_id = NULL, sync_status='pending' WHERE id='g1';");
      await _goalOutbox(db, 'create');
      final r = await _push(db, sink).push();
      expect(r.pushed, 1);
      expect(sink.server, hasLength(1));
    });

    test('server changed between the replay fetch and the guarded update -> '
        'conflict, local row kept', () async {
      await _goal(db);
      await _goalOutbox(db, 'create');
      final sink = _Sink()
        ..serverMovesBeforeGuard = true
        ..server['g1'] = {'id': 'srv-old', 'local_id': 'g1', 'updated_at': 'tOld'};
      final r = await _push(db, sink).push();
      expect(r.conflicts, 1);
      final g = (await db.customSelect("SELECT * FROM goals WHERE id='g1'").getSingle()).data;
      expect(g['sync_status'], 'conflict');
    });

    test('23505 with NO row for this local_id (other unique constraint) -> '
        'duplicate_business_key, row dead-lettered and observable', () async {
      await _goal(db);
      await _goalOutbox(db, 'create');
      final sink = _Sink()
        ..upsertError = const PostgrestException(
            message: 'duplicate key value violates unique constraint "other"',
            code: '23505');
      final r = await _push(db, sink).push();
      expect(r.failed, 1);
      final row = (await _outbox(db)).single;
      expect(row['status'], 'dead_letter');
      expect(row['failure_class'], kFailDuplicateBusinessKey);
      final g = (await db.customSelect("SELECT * FROM goals WHERE id='g1'").getSingle()).data;
      expect(g['sync_status'], isNot('conflict'));
      expect(g['name'], 'goal', reason: 'local data untouched');
    });

    test('42P10 -> server_schema_mismatch, NOT a conflict', () async {
      await _goal(db);
      await _goalOutbox(db, 'create');
      final sink = _Sink()
        ..upsertError = const PostgrestException(
            message: 'there is no unique or exclusion constraint matching the ON CONFLICT specification',
            code: '42P10');
      final r = await _push(db, sink).push();
      expect(r.conflicts, 0);
      expect(r.failed, 1);
      final row = (await _outbox(db)).single;
      expect(row['failure_class'], kFailServerSchemaMismatch);
      final g = (await db.customSelect("SELECT * FROM goals WHERE id='g1'").getSingle()).data;
      expect(g['sync_status'], isNot('conflict'));
    });

    test('23514 -> server_check_violation (observable)', () async {
      await _goal(db);
      await _goalOutbox(db, 'create');
      final sink = _Sink()
        ..upsertError = const PostgrestException(message: 'check', code: '23514');
      await _push(db, sink).push();
      expect((await _outbox(db)).single['failure_class'],
          kFailServerCheckViolation);
    });

    test('42501 is the auth class: parked auth_required, never dead-lettered',
        () async {
      await _goal(db);
      await _goalOutbox(db, 'create');
      final sink = _Sink()
        ..upsertError = const PostgrestException(message: 'rls', code: '42501');
      await _push(db, sink).push();
      final row = (await _outbox(db)).single;
      // A-5: an auth rejection parks the row (no attempt consumed) until the
      // next authenticated session / Retry — it is neither retried nor lost.
      expect(row['status'], 'parked');
      expect(row['failure_class'], 'auth_required');
      expect(row['attempt_count'], 0);
    });
  });

  group('G16 secondary unique key on a full-index table (category)', () {
    test('23505 never replaces local data and never consumes the row',
        () async {
      await db.customStatement('''
        INSERT INTO categories(id, key, name_ar, icon, color, is_income, sort_order)
        VALUES ('c1','custom_c1','mine','star','#fff',0,1);
      ''');
      await _queue(db).enqueueCategory(
          PlanningSyncOperation.create,
          const CategoryEntity(
              id: 'c1',
              key: 'custom_c1',
              nameAr: 'mine',
              icon: 'star',
              color: '#fff',
              isIncome: false,
              sort: 1));
      final sink = _Sink()
        ..upsertError = const PostgrestException(
            message: 'duplicate key value violates unique constraint "user_categories_user_key_uidx"',
            code: '23505',
            details: 'Key (user_id, key)=(u, custom_c1) already exists.');
      final r = await _push(db, sink).push();
      expect(r.conflicts, 0);
      final row = (await _outbox(db)).single;
      expect(row['status'], 'dead_letter');
      expect(row['failure_class'], kFailDuplicateBusinessKey);
      final c = (await db.customSelect("SELECT * FROM categories WHERE id='c1'").getSingle()).data;
      expect(c['name_ar'], 'mine');
      expect(c['sync_status'], isNot('conflict'));
    });
  });

  group('G17 no blind updates', () {
    test('update without a base token: fetch the server updated_at, then a '
        'GUARDED update', () async {
      await _goal(db, serverId: 'srv-1');
      await _goalOutbox(db, 'update');
      final sink = _Sink()
        ..server['g1'] = {'id': 'srv-1', 'local_id': 'g1', 'updated_at': 'tS'};
      final r = await _push(db, sink).push();
      expect(r.pushed, 1);
      expect(sink.fetches, 1);
      expect(sink.guarded, ['srv-1@tS']);
      expect(sink.blindUpdates, 0);
    });

    test('server changes after the fetch -> conflict, local edit kept',
        () async {
      await _goal(db, serverId: 'srv-1');
      await _goalOutbox(db, 'update');
      final sink = _Sink()
        ..serverMovesBeforeGuard = true
        ..server['g1'] = {'id': 'srv-1', 'local_id': 'g1', 'updated_at': 'tS'};
      final r = await _push(db, sink).push();
      expect(r.conflicts, 1);
      expect(sink.blindUpdates, 0);
      expect(sink.server['g1']!['updated_at'], 'moved',
          reason: 'the server row was not overwritten');
    });

    test('server row gone -> conflict, never a blind write', () async {
      await _goal(db, serverId: 'srv-1');
      await _goalOutbox(db, 'update');
      final sink = _Sink();
      final r = await _push(db, sink).push();
      expect(r.conflicts, 1);
      expect(sink.blindUpdates, 0);
    });
  });

  group('durable in-flight marker', () {
    Future<int?> marker() async => (await db
            .customSelect('SELECT in_flight_seq AS m FROM planning_sync_outbox')
            .getSingle())
        .readNullable<int>('m');

    test('offline create + delete that never started a push is dropped',
        () async {
      await db.customStatement('''
        INSERT INTO categories(id, key, name_ar, icon, color, is_income, sort_order)
        VALUES ('c1','custom_c1','n','star','#fff',0,1);
      ''');
      const cat = CategoryEntity(
          id: 'c1', key: 'custom_c1', nameAr: 'n', icon: 'star', color: '#fff', isIncome: false, sort: 1);
      final q = _queue(db);
      await q.enqueueCategory(PlanningSyncOperation.create, cat);
      await q.enqueueCategory(PlanningSyncOperation.delete, cat);
      expect(await _outbox(db), isEmpty);
    });

    test('kill simulation: create handed to a push, process restarts (new '
        'queue instance), local delete -> converted to a delete, not dropped',
        () async {
      await db.customStatement('''
        INSERT INTO categories(id, key, name_ar, icon, color, is_income, sort_order)
        VALUES ('c1','custom_c1','n','star','#fff',0,1);
      ''');
      const cat = CategoryEntity(
          id: 'c1', key: 'custom_c1', nameAr: 'n', icon: 'star', color: '#fff', isIncome: false, sort: 1);
      await _queue(db).enqueueCategory(PlanningSyncOperation.create, cat);
      final handed = await _queue(db).pendingItems();
      expect(handed, hasLength(1));
      expect(await marker(), handed.single.opSeq);

      // "Restart": a brand new queue instance has no in-memory state.
      final fresh = _queue(db);
      await fresh.enqueueCategory(PlanningSyncOperation.delete, cat);
      final row = (await _outbox(db)).single;
      expect(row['operation'], 'delete');
      expect(row['status'], 'pending');

      // The delete path's confirmed-empty lookup ACKs when the create never landed.
      final sink = _Sink();
      final r = await _push(db, sink).push();
      expect(r.pushed, 1);
      expect(sink.lookups, 1);
      expect(await _outbox(db), isEmpty);
    });

    test('the marker is cleared on ACK, park and definite failure', () async {
      await _goal(db);
      await _goalOutbox(db, 'create');
      await _queue(db).pendingItems();
      expect(await marker(), 1);
      await _push(db, _Sink()
        ..upsertError = const PostgrestException(message: 'c', code: '23514'))
          .push();
      expect(await marker(), isNull);
    });
  });
}
