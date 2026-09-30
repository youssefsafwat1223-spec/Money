import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_repository_support.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/card_entity.dart';
import 'package:money_companion/engine/parser/card_network.dart';
import 'package:money_companion/domain/entities/category_entity.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/planning_sync/services/planning_child_sync_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';
import 'package:money_companion/features/planning_sync/services/planning_push_service.dart';

/// A-2 (outbox correctness) — planning side. Fails on the pre-A-2 code for the
/// same reasons as the ledger twin: G3 (in-flight edit lost), G15 (a child push
/// marks the parent goal synced), G18 (owner), G5 (intent dropped).
class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

/// Records every call; only the hooks a test sets answer.
class _Sink implements PlanningRemoteSink {
  int calls = 0;
  Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)? onUpsert;
  Future<Map<String, dynamic>?> Function(
      String, String, String, Map<String, dynamic>)? onGuardedUpdate;
  final guardedUpdates = <({String serverId, String base})>[];

  @override
  Future<Map<String, dynamic>> upsert(
      String table, Map<String, dynamic> row) async {
    calls++;
    return onUpsert!(table, row);
  }

  @override
  Future<Map<String, dynamic>?> guardedUpdateByServerId(String table,
      String serverId, String expectedUpdatedAt, Map<String, dynamic> row) async {
    calls++;
    guardedUpdates.add((serverId: serverId, base: expectedUpdatedAt));
    return onGuardedUpdate!(table, serverId, expectedUpdatedAt, row);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls++;
    throw UnimplementedError('unexpected remote call: ${invocation.memberName}');
  }
}

CategoryEntity _cat(String id, {String name = 'original'}) => CategoryEntity(
      id: id,
      key: 'custom_$id',
      nameAr: name,
      icon: 'star',
      color: '#fff',
      isIncome: false,
      sort: 1,
    );

Future<void> _insertCategory(AppDatabase db, String id,
    {String name = 'original'}) async {
  await db.customStatement('''
    INSERT INTO categories(id, key, name_ar, icon, color, is_income, sort_order)
    VALUES ('$id', 'custom_$id', '$name', 'star', '#fff', 0, 1);
  ''');
}

Future<List<Map<String, Object?>>> _outbox(AppDatabase db) async => [
      for (final r in await db
          .customSelect('SELECT * FROM planning_sync_outbox ORDER BY created_at;')
          .get())
        r.data
    ];

Future<Map<String, Object?>> _catRow(AppDatabase db, String id) async =>
    (await db.customSelect("SELECT * FROM categories WHERE id = '$id';").getSingle())
        .data;

PlanningOutboxQueue _queue(
  AppDatabase db, {
  Future<String?> Function()? owner,
  String? auth = 'user-1',
}) =>
    PlanningOutboxQueue(
      db: db,
      isSyncEnabled: (_) => true,
      getAuthUserId: () async => auth,
      getOwnerUid: owner,
    );

PlanningPushService _push(AppDatabase db, PlanningOutboxQueue queue, _Sink sink,
        {String? uid = 'user-1'}) =>
    PlanningPushService(
      db: db,
      queue: queue,
      isEnabled: (_) => true,
      getAuthUserId: () async => uid,
      remoteSink: sink,
      mayEgress: () async => true,
      mayEgressProfile: () async => true,
    );

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
        'and is pushed next cycle as a guarded UPDATE by server id', () async {
      await _insertCategory(db, 'c1');
      final queue = _queue(db);
      await queue.enqueueCategory(PlanningSyncOperation.create, _cat('c1'));

      final sink = _Sink()
        ..onUpsert = (table, row) async {
          // The user renames the category WHILE the create is in flight.
          await db.customStatement(
              "UPDATE categories SET name_ar = 'edited in flight' WHERE id = 'c1';");
          await queue.enqueueCategory(
              PlanningSyncOperation.update, _cat('c1', name: 'edited in flight'));
          return {'id': 'srv-c1', 'updated_at': 't1'};
        }
        ..onGuardedUpdate = (table, serverId, base, row) async =>
            {'id': serverId, 'updated_at': 't2'};
      final service = _push(db, queue, sink);

      expect((await service.push()).pushed, 1);

      final rows = await _outbox(db);
      expect(rows, hasLength(1), reason: 'the folded edit must not be deleted');
      expect(rows.single['status'], 'pending');
      expect(rows.single['attempt_count'], 0);
      final payload = jsonDecode(rows.single['payload_json'] as String) as Map;
      expect(payload['name_ar'], 'edited in flight');
      expect(payload['server_updated_at'], 't1',
          reason: 'the ACK version is the new CAS base');
      final cat = await _catRow(db, 'c1');
      expect(cat['sync_status'], 'pending',
          reason: 'must NOT be marked synced while an edit is unpushed');
      expect(cat['server_id'], 'srv-c1');

      expect((await service.push()).pushed, 1);
      expect(sink.guardedUpdates.single, (serverId: 'srv-c1', base: 't1'));
      expect(await _outbox(db), isEmpty);
      expect((await _catRow(db, 'c1'))['sync_status'], 'synced');
    });
  });

  group('G18 owner-scoped outbox', () {
    test('a row recorded for owner A is NEVER sent under signed-in B; parked '
        'owner_mismatch, never deleted', () async {
      await _insertCategory(db, 'c1');
      final queueA =
          _queue(db, owner: () async => 'user-A', auth: 'user-A');
      await queueA.enqueueCategory(PlanningSyncOperation.create, _cat('c1'));
      expect((await _outbox(db)).single['owner_uid'], 'user-A');

      final tripwire = _Sink();
      final result = await _push(
              db,
              _queue(db, owner: () async => 'user-B', auth: 'user-B'),
              tripwire,
              uid: 'user-B')
          .push();
      expect(tripwire.calls, 0, reason: 'another account\'s data must not egress');
      expect(result.pushed + result.failed, 0);
      final row = (await _outbox(db)).single;
      expect(row['status'], 'parked');
      expect(row['failure_class'], 'owner_mismatch');

      // Owner A returns: the same durable row is delivered as A.
      final sink = _Sink()
        ..onUpsert = (t, r) async => {'id': 'srv', 'updated_at': 't'};
      final back = await _push(db, queueA, sink, uid: 'user-A').push();
      expect(back.pushed, 1);
      expect(await _outbox(db), isEmpty);
    });

    test('a NULL-owner legacy row is stamped ONLY when ownership is verified',
        () async {
      await _insertCategory(db, 'c1');
      await db.customStatement('''
        INSERT INTO planning_sync_outbox(id, entity_type, entity_id, operation,
          payload_json, attempt_count, status, created_at, updated_at)
        VALUES ('legacy', 'category', 'c1', 'create',
          '${jsonEncode({'local_id': 'c1', 'key': 'custom_c1', 'name_ar': 'n', 'icon': 'i', 'color': 'c', 'is_income': false})}',
          0, 'pending', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z');
      ''');

      final tripwire = _Sink();
      await _push(db, _queue(db, owner: () async => 'someone-else'), tripwire)
          .push();
      expect(tripwire.calls, 0);
      final parked = (await _outbox(db)).single;
      expect(parked['status'], 'parked');
      expect(parked['failure_class'], 'owner_unverified');
      expect(parked['owner_uid'], isNull, reason: 'never stamped without proof');

      final sink = _Sink()
        ..onUpsert = (t, r) async => {'id': 'srv', 'updated_at': 't'};
      final result =
          await _push(db, _queue(db, owner: () async => 'user-1'), sink).push();
      expect(result.pushed, 1);
      expect(sink.calls, 1);
      expect(await _outbox(db), isEmpty);
    });
  });

  group('G5 enqueue records intent', () {
    test('no live session but a local owner -> intent recorded', () async {
      await _insertCategory(db, 'c1');
      final queue = _queue(db, owner: () async => 'user-1', auth: null);
      expect(
          await queue.enqueueCategory(PlanningSyncOperation.create, _cat('c1')),
          isTrue);
      final row = (await _outbox(db)).single;
      expect(row['owner_uid'], 'user-1');
      expect(row['status'], 'pending');
    });

    test('a true guest keeps today\'s behaviour: no intent', () async {
      await _insertCategory(db, 'c1');
      final queue = _queue(db, owner: () async => null, auth: null);
      expect(
          await queue.enqueueCategory(PlanningSyncOperation.create, _cat('c1')),
          isFalse);
      expect(await _outbox(db), isEmpty);
    });

    test('budget with an unresolvable category: dependency_wait, then unparked '
        'with the resolved KEY once the category exists', () async {
      final queue = _queue(db);
      final budget = BudgetEntity(
        id: 'b1',
        categoryId: 'cat-late',
        currency: 'SAR',
        amountMoney: Money.parse('50.00', 'SAR'),
        lastNotifiedSpentMoney: Money(0, 'SAR'),
        period: BudgetPeriod.monthly,
        startDate: DateTime.utc(2026, 8, 1),
        isActive: true,
        lastNotifiedPeriodStart: DateTime.utc(2026, 8, 1),
      );
      expect(await queue.enqueueBudget(PlanningSyncOperation.create, budget),
          isTrue);
      var row = (await _outbox(db)).single;
      expect(row['status'], 'parked');
      expect(row['failure_class'], 'dependency_wait');

      expect(await queue.resolveDependencies(), 0,
          reason: 'still unresolvable -> stays parked');

      // The category (and the budget row) appear.
      await _insertCategory(db, 'cat-late');
      await db.customStatement('''
        INSERT INTO budgets(id, category_id, amount, period, start_date, is_active)
        VALUES ('b1', 'cat-late', 50, 'monthly', '2026-08-01T00:00:00Z', 1);
      ''');
      expect(await queue.resolveDependencies(), 1);
      row = (await _outbox(db)).single;
      expect(row['status'], 'pending');
      expect(row['failure_class'], isNull);
      final payload = jsonDecode(row['payload_json'] as String) as Map;
      expect(payload['category_id'], 'custom_cat-late',
          reason: 'the stable KEY, never the local id');
    });

    test('card without an account: dependency_wait, unparked once it has one; '
        'coalescing still applies', () async {
      final queue = _queue(db);
      final now = DateTime.utc(2026, 7, 1);
      CardEntity card({String? accountId}) => CardEntity(
            id: 'card-1',
            accountId: accountId,
            last4: '4242',
            network: CardNetwork.visa,
            source: CardSource.manual,
            createdAt: now,
            updatedAt: now,
          );
      await db.customStatement('''
        INSERT INTO cards(id, account_id, last4, network, source, created_at, updated_at)
        VALUES ('card-1', NULL, '4242', 'visa', 'manual', '2026-07-01T00:00:00Z', '2026-07-01T00:00:00Z');
      ''');
      await queue.enqueueCard(PlanningSyncOperation.create, card());
      await queue.enqueueCard(PlanningSyncOperation.update, card());
      var rows = await _outbox(db);
      expect(rows, hasLength(1), reason: 'coalesced into ONE parked row');
      expect(rows.single['status'], 'parked');
      expect(rows.single['failure_class'], 'dependency_wait');
      expect(rows.single['op_seq'], 2);

      await db.customStatement('''
        INSERT INTO accounts(id, name, currency, type, is_default, sort_order,
          created_at, updated_at, initial_balance, current_balance)
        VALUES ('acc-1', 'Main', 'SAR', 'bank', 1, 0, '2026-07-01T00:00:00Z',
          '2026-07-01T00:00:00Z', 0, 0);
      ''');
      await db.customStatement(
          "UPDATE cards SET account_id = 'acc-1' WHERE id = 'card-1';");
      expect(await queue.resolveDependencies(), 1);
      rows = await _outbox(db);
      expect(rows.single['status'], 'pending');
      expect((jsonDecode(rows.single['payload_json'] as String) as Map)['local_account_id'],
          'acc-1');
    });

    test('settings update before the row is bound: dependency_wait (local row '
        'untouched), unparked once bound with a REBUILT, consent-free payload',
        () async {
      final queue = _queue(db);
      final before = (await db
              .customSelect('SELECT * FROM user_settings LIMIT 1;')
              .getSingle());
      final settings = userSettingsFromRow(before);
      final statusBefore = before.readNullable<String>('sync_status');

      expect(
          await queue.enqueueSettings(PlanningSyncOperation.update, settings),
          isTrue);
      var row = (await _outbox(db)).single;
      expect(row['status'], 'parked');
      expect(row['failure_class'], 'dependency_wait');
      final after = await db.customSelect('SELECT * FROM user_settings LIMIT 1;').getSingle();
      expect(after.readNullable<String>('sync_status'), statusBefore,
          reason: 'a pending local flag would make the binding pull a conflict');

      expect(await queue.resolveDependencies(), 0);
      await db.customStatement("UPDATE user_settings SET server_id = 'srv-s';");
      expect(await queue.resolveDependencies(), 1);
      row = (await _outbox(db)).single;
      expect(row['status'], 'pending');
      final payload = jsonDecode(row['payload_json'] as String) as Map;
      expect(payload.containsKey('cloud_processing_enabled'), isFalse);
      expect(payload.containsKey('ai_consent_granted'), isFalse);
    });
  });

  group('G15 a child push never settles the parent goal', () {
    test('contribution push leaves a pending goal edit pending', () async {
      const now = '2026-07-23T09:00:00.000Z';
      await db.customStatement('''
        INSERT INTO goals(id,name,target_amount,saved_amount,currency,
          target_amount_minor,saved_amount_minor,last_notified_saved_amount_minor,
          vault_skin,status,created_at,server_id,sync_status)
        VALUES ('goal-1','goal',100,0,'EGP',10000,0,0,'classic','active',
          '$now','server-goal-1','pending');
      ''');
      await db.customStatement('''
        INSERT INTO goal_contributions(id,goal_id,amount,amount_minor,created_at)
        VALUES ('gc-1','goal-1',25,2500,'$now');
      ''');
      final queue = _queue(db);
      await queue.enqueueGoalContribution(
        PlanningSyncOperation.create,
        GoalContributionEntity(
          id: 'gc-1',
          goalId: 'goal-1',
          amountMoney: Money.parse('25', 'EGP'),
          createdAt: DateTime.utc(2026, 7, 23, 9),
        ),
      );
      await PlanningChildSyncService(
        db: db,
        queue: queue,
        isEnabled: (_) => true,
        isPullEnabled: (_) => false,
        getAuthUserId: () async => 'user-1',
        remote: _ChildRemote(),
        mayEgress: () async => true,
      ).sync();

      expect(await _outbox(db), isEmpty, reason: 'the child itself drained');
      final goal = await db
          .customSelect("SELECT sync_status FROM goals WHERE id = 'goal-1';")
          .getSingle();
      expect(goal.read<String>('sync_status'), 'pending',
          reason: 'the parent goal edit is still owed its own push');
    });
  });
}

class _ChildRemote implements PlanningChildRemote {
  @override
  Future<Map<String, dynamic>> callRpc(
      String name, Map<String, dynamic> params) async {
    const now = '2026-07-23T10:00:00.000Z';
    return {
      'contribution': {
        'id': 'server-gc',
        'local_id': params['p_local_id'],
        'goal_id': params['p_goal_id'],
        'amount': params['p_amount'],
        'created_at': params['p_created_at'],
        'note': null,
        'updated_at': now,
        'deleted_at': null,
      },
      'goal': {
        'id': params['p_goal_id'],
        'saved_amount': params['p_amount'],
        'updated_at': now,
      },
    };
  }

  @override
  Future<List<Map<String, dynamic>>> fetchRows(String table,
          {required SyncCursor after, int limit = 200}) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
