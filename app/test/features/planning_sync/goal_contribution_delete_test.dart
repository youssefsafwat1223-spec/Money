import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/data/db/planning_cutover.dart';
import 'package:money_companion/data/sync/server_capabilities.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/planning_sync/services/planning_child_sync_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../harness/fake_cas_server.dart';

// D1 (user decision 5b): a tombstoned goal contribution is pushed through
// sync_tombstone_goal_contribution (0116) - epoch-checked, idempotent, and the
// server's saved_amount is applied to the local goal. Replaces the pre-0116
// behaviour (immediate unsupported_operation dead letter) wherever the endpoint
// and an epoch are available.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

/// Emulates the 0116 function: epoch, idempotent tombstone, saved_amount - amount once.
class _DeleteRemote implements PlanningChildRemote {
  _DeleteRemote({this.epoch = 'e1'});
  String epoch;
  num saved = 60;
  final Map<String, ({num amount, bool deleted})> contributions = {
    'server-gc-1': (amount: 20, deleted: false),
  };
  final List<Map<String, dynamic>> calls = [];
  bool loseNextAck = false;
  bool notDeployed = false;

  @override
  Future<Map<String, dynamic>> callRpc(
      String name, Map<String, dynamic> params) async {
    if (name != 'sync_tombstone_goal_contribution') throw UnsupportedError(name);
    calls.add(params);
    if (notDeployed) {
      throw const PostgrestException(
          message: 'Could not find the function', code: 'PGRST202');
    }
    if (params['p_expected_epoch'] != epoch) {
      return {'outcome': 'epoch_mismatch', 'row': null, 'goal': null, 'epoch': epoch};
    }
    final id = params['p_id'] as String;
    final c = contributions[id];
    if (c == null) {
      return {'outcome': 'not_found', 'row': null, 'goal': null};
    }
    var outcome = 'ack';
    if (!c.deleted) {
      saved = (saved - c.amount) < 0 ? 0 : saved - c.amount;
      contributions[id] = (amount: c.amount, deleted: true);
      outcome = 'applied';
      if (loseNextAck) {
        loseNextAck = false;
        throw StateError('ack lost');
      }
    }
    return {
      'outcome': outcome,
      'row': {
        'id': id,
        'goal_id': 'server-goal-1',
        'updated_at': '2026-09-03T00:00:00.000Z',
        'deleted_at': '2026-09-03T00:00:00.000Z',
      },
      'goal': {
        'id': 'server-goal-1',
        'currency': 'KWD',
        'saved_amount_text': saved.toString(),
        'updated_at': '2026-09-03T00:00:00.000Z',
      },
    };
  }

  @override
  Future<List<Map<String, dynamic>>> fetchRows(String table,
          {required SyncCursor after, int limit = 200}) async =>
      const [];
  @override
  Future<Map<String, dynamic>?> findPlanLink(
          {required String userId,
          required String planId,
          required String transactionId}) async =>
      throw UnsupportedError('findPlanLink');
  @override
  Future<void> tombstonePlanLink(String serverId) async =>
      throw UnsupportedError('tombstonePlanLink');
  @override
  Future<Map<String, dynamic>> upsertPlanLink(Map<String, dynamic> row) async =>
      throw UnsupportedError('upsertPlanLink');
}

bool _only(String t) => t == PlanningOutboxQueue.goalContributionsEntityType;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late PlanningOutboxQueue queue;

  Future<void> seed({String? contributionServerId = 'server-gc-1'}) async {
    const now = '2026-07-23T09:00:00.000Z';
    await db.customStatement('''
      INSERT INTO goals(id,name,target_amount,saved_amount,currency,
        target_amount_minor,saved_amount_minor,last_notified_saved_amount_minor,
        vault_skin,status,created_at,server_id,sync_status)
      VALUES ('goal-1','g',100,60,'KWD',100000,60000,0,'classic','active',
        '$now','server-goal-1','synced');
    ''');
    await db.customStatement('''
      INSERT INTO goal_contributions(id,goal_id,amount,amount_minor,created_at,
        server_id,sync_status,deleted_at)
      VALUES ('gc-1','goal-1',20,20000,'$now',
        ${contributionServerId == null ? 'NULL' : "'$contributionServerId'"},
        'pending','$now');
    ''');
    await backfillNonPlanningMoneyV30(db);
    await queue.enqueueGoalContribution(
      PlanningSyncOperation.delete,
      GoalContributionEntity(
        id: 'gc-1',
        goalId: 'goal-1',
        amountMoney: Money.parse('20', 'KWD'),
        createdAt: DateTime.utc(2026, 7, 23, 9),
      ),
    );
  }

  setUp(() async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    queue = PlanningOutboxQueue(
      db: db,
      isSyncEnabled: _only,
      getAuthUserId: () async => 'user-1',
    );
  });
  tearDown(() => db.close());

  PlanningChildSyncService svc(_DeleteRemote remote,
          {ServerCapabilityState? cap, String gateEpoch = 'e1'}) =>
      PlanningChildSyncService(
        db: db,
        queue: queue,
        isEnabled: _only,
        getAuthUserId: () async => 'user-1',
        remote: remote,
        coordinator: const FixedPlanningCutoverCoordinator(
            PlanningCutoverState.canonical),
        mayEgress: () async => true,
        casGate: cap == null ? null : casGate(db, epoch: gateEpoch, capability: cap),
      );

  Future<Map<String, Object?>> contribution() async =>
      (await db.customSelect("SELECT * FROM goal_contributions WHERE id='gc-1'").getSingle()).data;
  Future<int> savedMinor() async => (await db
          .customSelect("SELECT saved_amount_minor FROM goals WHERE id='goal-1'")
          .getSingle())
      .read<int>('saved_amount_minor');
  Future<Map<String, Object?>?> outbox() async => (await db
          .customSelect('SELECT * FROM planning_sync_outbox')
          .getSingleOrNull())
      ?.data;

  test('revision_cas verified: applied; the server saved_amount (60 -> 40) is '
      'applied locally and the op is acknowledged', () async {
    await seed();
    final remote = _DeleteRemote();
    await svc(remote, cap: ServerCapabilityState.verified).sync();
    expect(remote.calls, [
      {'p_expected_epoch': 'e1', 'p_id': 'server-gc-1'}
    ]);
    expect(await outbox(), isNull);
    expect((await contribution())['sync_status'], 'synced');
    expect(await savedMinor(), 40000);
    expect(remote.saved, 40);
  });

  test('lost ACK: the retry is an ack and saved_amount is reduced only once',
      () async {
    await seed();
    final remote = _DeleteRemote()..loseNextAck = true;
    final s = svc(remote, cap: ServerCapabilityState.verified);
    await s.sync();
    expect(await outbox(), isNotNull, reason: 'lost ACK keeps the op queued');
    await db.customStatement('UPDATE planning_sync_outbox SET next_retry_at = NULL;');
    await s.sync();
    expect(remote.calls.length, 2);
    expect(remote.saved, 40, reason: 'server reduced exactly once');
    expect(await outbox(), isNull);
    expect(await savedMinor(), 40000);
  });

  test('legacy plan (revision_cas unsupported): the additive endpoint is '
      'still used when an epoch can be read', () async {
    await seed();
    final remote = _DeleteRemote();
    await svc(remote, cap: ServerCapabilityState.unsupported).sync();
    expect(remote.calls.length, 1);
    expect(await outbox(), isNull);
    expect(await savedMinor(), 40000);
  });

  test('no gate / no readable epoch: pre-0116 dead letter, server not called',
      () async {
    await seed();
    final remote = _DeleteRemote();
    await svc(remote).sync();
    expect(remote.calls, isEmpty);
    final row = (await outbox())!;
    expect(row['status'], 'dead_letter');
    expect(row['last_error'].toString(), contains('unsupported_operation'));
  });

  test('endpoint not deployed (PGRST202): immediate unsupported dead letter',
      () async {
    await seed();
    final remote = _DeleteRemote()..notDeployed = true;
    await svc(remote, cap: ServerCapabilityState.verified).sync();
    final row = (await outbox())!;
    expect(row['status'], 'dead_letter');
    expect(row['last_error'].toString(), contains('unsupported_operation'));
    expect(row['attempt_count'], 0);
    expect(await savedMinor(), 60000, reason: 'local goal untouched');
  });

  test('stale epoch: nothing consumed, stays queued', () async {
    await seed();
    final remote = _DeleteRemote(epoch: 'e2');
    await svc(remote, cap: ServerCapabilityState.verified).sync();
    final row = (await outbox())!;
    expect(row['status'], 'pending');
    expect(row['attempt_count'], 0);
    expect(row['in_flight_seq'], isNull);
    expect(remote.saved, 60);
  });

  test('capability unknown: nothing is sent, the op stays queued', () async {
    await seed();
    final remote = _DeleteRemote();
    await svc(remote, cap: ServerCapabilityState.unknown).sync();
    expect(remote.calls, isEmpty);
    final row = (await outbox())!;
    expect(row['status'], 'pending');
    expect(row['attempt_count'], 0);
  });

  test('not_found (absent on the server): the delete is converged', () async {
    await seed();
    final remote = _DeleteRemote()..contributions.clear();
    await svc(remote, cap: ServerCapabilityState.verified).sync();
    expect(await outbox(), isNull);
    expect((await contribution())['sync_status'], 'synced');
    expect(await savedMinor(), 60000, reason: 'no server goal returned');
  });

  test('a contribution that never reached the server needs no call', () async {
    await seed(contributionServerId: null);
    final remote = _DeleteRemote();
    await svc(remote, cap: ServerCapabilityState.verified).sync();
    expect(remote.calls, isEmpty);
    expect(await outbox(), isNull);
    expect((await contribution())['sync_status'], 'synced');
  });
}
