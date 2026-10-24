import 'package:money_companion/core/session/account_fence_authority.dart';
import 'package:money_companion/data/db/creation_policy.dart';
import 'package:money_companion/core/sync/outbox_failure.dart' show AccountsDeliveryStopped, AccountsDeliveryStopReason;
import '../capture/ledger_admission_fixture.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/core/sync/outbox_failure.dart';
import 'package:money_companion/core/sync/account_fence_retry.dart';
import 'package:money_companion/data/repositories/drift_repository_support.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/data/sync/exact_transport_capability.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/features/planning_sync/services/accounts_push_service.dart';
import 'package:money_companion/domain/entities/card_entity.dart';
import 'package:money_companion/engine/parser/card_network.dart';
import 'package:money_companion/domain/entities/category_entity.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/planning_sync/services/planning_child_sync_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';
import 'package:money_companion/features/planning_sync/services/planning_push_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A-2 (outbox correctness) — planning side. Fails on the pre-A-2 code for the
/// same reasons as the ledger twin: G3 (in-flight edit lost), G15 (a child push
/// marks the parent goal synced), G18 (owner), G5 (intent dropped).

/// Records every call; only the hooks a test sets answer.
class _Sink implements PlanningRemoteSink {
  int calls = 0;
  Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)? onUpsert;
  Future<Map<String, dynamic>?> Function(
      String, String, String, Map<String, dynamic>)? onGuardedUpdate;
  final guardedUpdates = <({String serverId, String base})>[];
  Future<Map<String, dynamic>?> Function(String, String, Map<String, dynamic>)? onUpdate;
  @override
  Future<Map<String, dynamic>?> updateByServerId(String table, String id,
      Map<String, dynamic> row) async {
    calls++;
    return onUpdate!(table, id, row);
  }

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

PlanningPushService _push(AppDatabase db, PlanningOutboxQueue queue, PlanningRemoteSink sink,
        {String? uid = 'user-1', AccountFenceRetry? fenceRetry}) =>
    PlanningPushService(
      db: db,
      queue: queue,
      isEnabled: (_) => true,
      getAuthUserId: () async => uid,
      remoteSink: sink,
      fenceRetry: fenceRetry ?? AccountFenceRetry(delay: (_) async {}),
      mayEgress: () async => true,
      mayEgressProfile: () async => true,
    );

void main() {
  _e4ConcreteMutationTests();
  _e4PlanningFileBackedTests();
  group('planning parent and queue controls', () {
  late AppDatabase db;
  late LedgerAdmissionFixture admission;

  setUp(() async {
    admission=await LedgerAdmissionFixture.open('user-1');
    db=admission.database;
  });
  tearDown(() => admission.finish());

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
        'owner_mismatch; same-row queue rearm and independent A positive', () async {
      await admission.finish();admission=await LedgerAdmissionFixture.open('user-B');db=admission.database;
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

      // Queue-only same-row rearm under synthetic A input; no B replica is admitted as A.
      await queueA.reconcileOwnership('user-A');
      expect((await _outbox(db)).single['status'],'pending');
      await admission.finish();admission=await LedgerAdmissionFixture.open('user-A');db=admission.database;
      await _insertCategory(db,'c1');
      final independentA=_queue(db,owner:()async=>'user-A',auth:'user-A');
      await independentA.enqueueCategory(PlanningSyncOperation.create,_cat('c1'));
      final sink = _Sink()
        ..onUpsert = (t, r) async => {'id': 'srv', 'updated_at': 't'};
      final back = await _push(db, independentA, sink, uid: 'user-A').push();
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


// E4 first RED: actual structured remote refusals, no future hold/API seeded.
void _e4PlanningFileBackedTests() {
  Future<void> withFileDatabase(
      Future<void> Function(AppDatabase db, Future<AppDatabase> Function() reopen) body) async {
    final admission=await LedgerAdmissionFixture.open('user-1');
    var database=admission.database;final location=admission.location;
    final inspections=<AppDatabase>[];
    try{
      await body(database,()async{
        if(database.lifecycleState==DatabaseLifecycleState.closed&&!AccountFenceAuthority.shared.permits('user-1')){
          final inspection=await AppDatabase.open(location:location,runMigrations:false,creation:const CreationPolicy.denied());
          inspections.add(inspection);return inspection; // privileged SELECT-only after actual denial closure
        }
        database=await admission.restart();return database;
      });
    }finally{
      for(final inspection in inspections){await inspection.close();expect(inspection.lifecycleState,DatabaseLifecycleState.closed);}
      await admission.finish();
    }
  }

  // Explicit queue mechanism: actual SDK typed refusal + existing conditional
  // transition only. No delivery/authority/ACK/conflict loop is emulated.
  Future<bool> queueRefusal(AppDatabase db,PlanningOutboxQueue queue,_Sink sink,
      {bool expectedChanged=true,bool off=false})async{
    final item=(await queue.pendingItems(entityType:off?'settings':'category')).first;
    final client=SupabaseClient('https://example.supabase.co','anon',httpClient:MockClient((request)async{
      try{
        if(off){await sink.updateByServerId('user_settings','settings-server',(jsonDecode(request.body)as Map).cast<String,dynamic>());}
        else{await sink.upsert('user_categories',(jsonDecode(request.body)as Map).cast<String,dynamic>());}
        throw StateError('expected raw typed refusal');
      }on PostgrestException catch(error){return http.Response(jsonEncode({'code':error.code,'message':error.message}),400,headers:{'content-type':'application/json'},request:request);}
    }));
    try{
      try{
        if(off){await client.from('user_settings').update({'ai_consent_granted':false,'cloud_processing_enabled':false}).eq('id','settings-server').select();}
        else{await client.from('user_categories').insert(item.payloadJson).select().single();}
        fail('SDK must deliver exact QD001');
      }on PostgrestException catch(error){
        expect(error.code,'QD001');final failure=classifyOutboxError(error);expect(failure,OutboxFailureClass.accountDeletionPending);
        final changed=await queue.recordAccountFenceFailure(item,failure,DateTime.utc(2026));expect(changed,expectedChanged);return changed;
      }
    }finally{await client.dispose();}
  }

  Map<String, Object?> intent(Map<String, Object?> row) => {
        for (final key in ['id', 'entity_type', 'entity_id', 'owner_uid', 'operation',
          'payload_json', 'op_seq', 'operation_id', 'base_revision']) key: row[key],
      };

  for (final code in ['55P03', 'QD001']) {
    test('E4 planning $code service-contention or queue-only-refusal preserves intent without a business attempt across reopen', () async {
      await withFileDatabase((database, reopen) async {
        await _insertCategory(database, 'c-e4');
        final queue = _queue(database);
        await queue.enqueueCategory(PlanningSyncOperation.create, _cat('c-e4'));
        final before = (await _outbox(database)).single;
        if (code == 'QD001') {
          await _insertCategory(database, 'c-e4-later');
          await queue.enqueueCategory(PlanningSyncOperation.create, _cat('c-e4-later'));
        }
        final remotePayloads = <Map<String, dynamic>>[];
        final sink = _Sink()..onUpsert = (_, row) async {
          remotePayloads.add(Map<String, dynamic>.of(row));
          throw PostgrestException(message: 'structured refusal', code: code);
        };
        final PlanningPushResult? result;
        if(code=='QD001'){expect(await queueRefusal(database,queue,sink),isTrue);result=null;}else{result=await _push(database,queue,sink).push();}
        final refused = (await _outbox(database)).firstWhere((row) => row['id'] == before['id']);
        final reopened = await reopen();
        final restored = (await _outbox(reopened)).firstWhere((row) => row['id'] == before['id']);

        expect(result?.pushed ?? 0, 0);
        expect(result?.conflicts ?? 0, 0);
        expect(sink.calls, greaterThanOrEqualTo(1), reason: code=='QD001'?'the SDK queue-mechanism refusal reached the remote hook':'the real service reached the remote hook');
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
          expect(sink.calls, greaterThan(1), reason: 'repeated rejection exhausts a bounded atomic retry budget');
          expect(sink.calls, lessThan(kOutboxMaxAttempts), reason: 'remote contention retries are bounded independently of business attempts');
          for (final payload in remotePayloads) { expect(payload, remotePayloads.first); }
          expect(restored['status'], 'pending');
          expect(restored['next_retry_at'], isNotNull, reason: 'exhaustion has a durable cooldown');
          final afterRestartSink = _Sink()..onUpsert = (_, __) async =>
              throw const PostgrestException(message: 'structured refusal', code: '55P03');
          await _push(reopened, _queue(reopened), afterRestartSink).push();
          expect(afterRestartSink.calls, 0, reason: 'restart must not bypass contention cooldown');
          expect(intent((await _outbox(reopened)).single), intent(before));
          expect((await _outbox(reopened)).single['attempt_count'], 0);
        }
        expect((await _catRow(reopened, 'c-e4'))['sync_status'], 'pending', reason: 'refusal is never an ACK');
        if (code == 'QD001') {
          expect(refused['status'], 'parked');
          expect(restored['status'], 'parked');
          expect(sink.calls, 1, reason: 'queue-only transition touches exactly the rejected item; integrated service stop is tested separately');
          final later = (await _outbox(reopened)).firstWhere((row) => row['entity_id'] == 'c-e4-later');
          expect(later['attempt_count'], 0);
          expect(later['status'], 'pending');
          expect((await _catRow(reopened, 'c-e4-later'))['sync_status'], 'pending');
        }
      });
    });
  }

  test('E4 planning queue-mechanism QD001 hold survives rearm coalesced intent and reopen without another send', () async {
    await withFileDatabase((database, reopen) async {
      await _insertCategory(database, 'c-e4');
      final queue = _queue(database);
      await queue.enqueueCategory(PlanningSyncOperation.create, _cat('c-e4'));
      final before = (await _outbox(database)).single;
      final refusedSink = _Sink()..onUpsert = (_, __) async =>
          throw const PostgrestException(message: 'structured refusal', code: 'QD001');
      await queueRefusal(database,queue,refusedSink);
      final afterRefusal = (await _outbox(database)).single;

      await queue.reArmAuthParked();
      await queue.clearRetryBackoff();
      await queue.reArmRetryableDeadLetters();
      await queue.reArmDeadLetter();
      await queue.reArmParked();
      await queue.resolveDependencies();
      await queue.reconcileOwnership('user-1');
      await database.customStatement(
          "UPDATE categories SET name_ar = 'E4 retained later intent' WHERE id = 'c-e4';");
      await queue.enqueueCategory(PlanningSyncOperation.update,
          _cat('c-e4', name: 'E4 retained later intent'));
      final afterEdit = await _outbox(database);
      final reopened = await reopen();
      final afterRestart = await _outbox(reopened);
      final laterSink = _Sink()..onUpsert = (_, __) async =>
          {'id': 'srv-e4', 'updated_at': 'e4-ack'};
      final result = await _push(reopened, _queue(reopened), laterSink).push();
      final afterRetry = await _outbox(reopened);

      expect(refusedSink.calls, 1);
      expect(laterSink.calls, 0, reason: 'generic recovery or a local edit must not revive deletion authority');
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
          (jsonDecode(row['payload_json'] as String) as Map)['name_ar'] == 'E4 retained later intent'), isTrue);
      expect((await _catRow(reopened, 'c-e4'))['sync_status'], 'pending');
      expect(await _queue(reopened).pendingItems(entityType: PlanningOutboxQueue.categoriesEntityType), isEmpty);
    });
  });
  test('E4 planning contention retry succeeds with identical mutation and one ACK', () async {
    await withFileDatabase((database, reopen) async {
      await _insertCategory(database, 'c-e4');
      final queue = _queue(database);
      await queue.enqueueCategory(PlanningSyncOperation.create, _cat('c-e4'));
      final before = (await _outbox(database)).single;
      final payloads = <String>[];
      final attempts = <int>[];
      var now = DateTime.now().toUtc();
      var delays = 0;
      final policy = AccountFenceRetry(clock: () => now, delay: (duration) async { delays++; now = now.add(duration); });

      final remote = _Sink()..onUpsert = (_, row) async {
        payloads.add(jsonEncode(row));
        attempts.add((await _outbox(database)).single['attempt_count'] as int);
        if (payloads.length == 1) { throw const PostgrestException(message: 'refused', code: '55P03'); }
        return {'id': 'srv-e4', 'updated_at': '2026-10-01T00:00:00Z'};
      };
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

  test('E4 planning contention followed by QD001 holds immediately without consuming the budget further', () async {
    const expectedBody = <String, Object?>{
      'user_id': 'user-1',
      'local_id': 'c-e4',
      'key': 'custom_c-e4',
      'name_ar': 'original',
      'icon': 'star',
      'color': '#fff',
      'is_income': false,
    };
    final requests = <http.Request>[];
    final unexpected = <http.Request>[];
    var count = 0;
    final transport = MockClient((request) async {
      requests.add(request);
      final Object? body;
      try {
        body = jsonDecode(request.body);
      } on FormatException {
        unexpected.add(request);
        throw StateError('unexpected non-JSON fixture request');
      }
      if (request.method != 'POST' ||
          request.url.scheme != 'https' ||
          request.url.host != 'example.supabase.co' ||
          request.url.path != '/rest/v1/user_categories' ||
          request.url.queryParameters.length != 2 ||
          request.url.queryParameters['on_conflict'] != 'user_id,local_id' ||
          request.url.queryParameters['select'] != 'id,updated_at' ||
          body is! Map || body.length != expectedBody.length ||
          !expectedBody.entries.every((entry) => (body as Map)[entry.key] == entry.value)) {
        unexpected.add(request);
        throw StateError('unexpected fixture mutation');
      }
      count++;
      return http.Response(jsonEncode({
        'message': 'refused', 'code': count == 1 ? '55P03' : 'QD001',
        'details': null, 'hint': null,
      }), count == 1 ? 409 : 400,
          headers: {'content-type': 'application/json'}, request: request);
    });
    Supabase? sdk;
    try {
      await Supabase.initialize(url: 'https://example.supabase.co', anonKey: 'anon',
          authOptions: const FlutterAuthClientOptions(autoRefreshToken: false,
              detectSessionInUri: false, localStorage: EmptyLocalStorage(),
              pkceAsyncStorage: _ParentSdkStorage()), httpClient: transport);
      sdk = Supabase.instance;
      await withFileDatabase((database, reopen) async {
        await _insertCategory(database, 'c-e4');
        final queue = _queue(database);
        await queue.enqueueCategory(PlanningSyncOperation.create, _cat('c-e4'));
        final before = (await _outbox(database)).single;
        var delays = 0;
        final policy = AccountFenceRetry(delay: (_) async { delays++; });

        // A raw exception from a semantic delegate cannot prove a parent
        // mutation refusal. Let the real SDK await this strict mock response.
        const remote = SupabasePlanningRemoteSink();
        PlanningDeliveryStopped? stopped;
        try{await _push(database,queue,remote,fenceRetry:policy).push();}on PlanningDeliveryStopped catch(e){stopped=e;}
        expect(stopped?.accepted,isTrue);expect(stopped?.parked,isTrue);expect(stopped?.complete,isTrue);
        database=await reopen();
        final held = (await _outbox(database)).single;
        expect(count, 2);
        expect(delays, 1);
        expect(stopped!.reason,PlanningDeliveryStopReason.denial);
        expect(held['status'], 'parked');
        expect(held['failure_class'], 'account_deletion_pending');
        expect(held['attempt_count'], 0);
        expect(intent(held), intent(before));
        expect(requests, hasLength(2));
        expect(requests.last.url, requests.first.url);
        expect(requests.last.method, requests.first.method);
        expect(requests.last.body, requests.first.body);
        expect(jsonDecode(requests.first.body), expectedBody);
        expect(unexpected, isEmpty);
      });
    } finally {
      // withFileDatabase closes the admitted/inspection handles first.
      try {
        await sdk?.dispose();
      } finally {
        transport.close();
        expect(unexpected, isEmpty);
      }
    }
  });

  for (final newerDispatched in [false, true]) {
    test('E4 planning late QD001 preserves coalesced payload and respects newer inflight=$newerDispatched', () async {
      await withFileDatabase((database, reopen) async {
        await _insertCategory(database, 'c-e4');
        final queue = _queue(database);
        await queue.enqueueCategory(PlanningSyncOperation.create, _cat('c-e4'));
        final original = (await _outbox(database)).single;
        final arrived = Completer<void>(); final release = Completer<void>();

        final remote = _Sink()..onUpsert = (_, row) async {
          arrived.complete();
          await release.future;
          throw const PostgrestException(message: 'refused', code: 'QD001');
        };
        final running = queueRefusal(database,queue,remote,expectedChanged: !newerDispatched);
        late Map<String,Object?> edited;
        try {
        await arrived.future;
        await database.customStatement("UPDATE categories SET name_ar = 'newer E4 edit' WHERE id = 'c-e4';");
        await queue.enqueueCategory(PlanningSyncOperation.update, _cat('c-e4', name: 'newer E4 edit'));
        if (newerDispatched) { await queue.pendingItems(entityType: PlanningOutboxQueue.categoriesEntityType); }
        edited = (await _outbox(database)).single;
        release.complete();
        await running;
        } finally { if(!release.isCompleted)release.complete(); await running; }
        final after = (await _outbox(database)).single;
        expect((jsonDecode(after['payload_json'] as String) as Map)['name_ar'], 'newer E4 edit');
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

    test('E4 planning late QD001 cannot hold a completed successor with NULL marker', () async {
      await withFileDatabase((database, reopen) async {
        await _insertCategory(database, 'c-e4');
        final queue = _queue(database);
        await queue.enqueueCategory(PlanningSyncOperation.create, _cat('c-e4'));
        final arrived = Completer<void>(); final release = Completer<void>();

        final remote = _Sink()..onUpsert = (_, row) async {
          arrived.complete();
          await release.future;
          throw const PostgrestException(message: 'refused', code: 'QD001');
        };
        final running = queueRefusal(database,queue,remote,expectedChanged:false);
        late Map<String,Object?> edited;
        try {
        await arrived.future;
        await database.customStatement("UPDATE categories SET name_ar = 'newer E4 edit' WHERE id = 'c-e4';");
        await queue.enqueueCategory(PlanningSyncOperation.update, _cat('c-e4', name: 'newer E4 edit'));
        final successor = (await queue.pendingItems(entityType: PlanningOutboxQueue.categoriesEntityType)).single;
        await database.customStatement("UPDATE categories SET name_ar = 'successor E4 edit' WHERE id = 'c-e4';");
        await queue.enqueueCategory(PlanningSyncOperation.update, _cat('c-e4', name: 'successor E4 edit'));
        await queue.acknowledge(successor);
        edited = (await _outbox(database)).single;
        release.complete();
        await running;
        } finally { if(!release.isCompleted)release.complete(); await running; }
        final after = (await _outbox(database)).single;
        expect(edited['in_flight_seq'], isNull);
        expect(after, edited, reason: 'the rejected S1 no longer owns the holder after S2 ACK');
      });
    });

  test('E4 planning a held create plus delete preserves the refusal and replay history', () async {
    await withFileDatabase((database, reopen) async {
      await _insertCategory(database, 'c-e4');
      final queue = _queue(database);
      await queue.enqueueCategory(PlanningSyncOperation.create, _cat('c-e4'));
      final original = (await _outbox(database)).single;

      final remote = _Sink()..onUpsert = (_, row) async { throw const PostgrestException(message: 'refused', code: 'QD001'); };
      await queueRefusal(database,queue,remote);
      await queue.enqueueCategory(PlanningSyncOperation.delete, _cat('c-e4'));
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
    test('E4 planning prior ambiguous send then $code preserves evidence and existing business attempts', () async {
      await withFileDatabase((database, reopen) async {
        await _insertCategory(database, 'c-e4');
        final queue = _queue(database);
        await queue.enqueueCategory(PlanningSyncOperation.create, _cat('c-e4'));
        final policy = AccountFenceRetry(delay: (_) async {});
        var ambiguous = true;

        final remote = _Sink()..onUpsert = (_, row) async {
          if (ambiguous) throw const SocketException('lost reply');
          throw PostgrestException(message: 'refused', code: code);
        };
        await _push(database, queue, remote, fenceRetry: policy).push();
        final uncertain = (await _outbox(database)).single;
        expect(uncertain['attempt_count'], 1);
        expect(uncertain['in_flight_seq'], isNotNull);
        await queue.clearRetryBackoff();
        ambiguous = false;
        if(code=='QD001'){await queueRefusal(database,queue,remote);}else{await _push(database,queue,remote,fenceRetry:policy).push();}
        final refused = (await _outbox(database)).single;
        expect(intent(refused), intent(uncertain));
        expect(refused['in_flight_seq'], uncertain['in_flight_seq']);
        expect(refused['attempt_count'], 1, reason: 'a definite current refusal cannot erase prior ambiguity or spend another business attempt');
        expect(refused['failure_class'], code == '55P03' ? 'account_fence_contention' : 'account_deletion_pending');
      });
    });
  }

  for (final outcome in ['success', '55P03', 'QD001']) {
    test('E4 planning consent-OFF narrow revocation with exact NULL owner handles $outcome', () async {
      await withFileDatabase((database, reopen) async {
        await database.customStatement("UPDATE user_settings SET server_id = 'settings-server';");
        final queue = _queue(database, owner: () async => null);
        final settings = userSettingsFromRow(await database.customSelect('SELECT * FROM user_settings LIMIT 1').getSingle());
        await queue.enqueueSettings(PlanningSyncOperation.update, settings, consentChanged: true);
        final before = (await _outbox(database)).single;
        expect(before['owner_uid'], isNull);
        final outgoing = <Map<String, dynamic>>[];
        final sink = _Sink()..onUpdate = (table, id, row) async {
          outgoing.add(Map<String, dynamic>.of(row));
          if (outcome == 'QD001') throw const PostgrestException(message: 'refused', code: 'QD001');
          if (outcome == '55P03' && outgoing.length == 1) {
            throw const PostgrestException(message: 'refused', code: '55P03');
          }
          return {'id': id, 'updated_at': 'ack'};
        };
        if(outcome=='QD001'){await queueRefusal(database,queue,sink,off:true);}else{
        await PlanningPushService(db: database, queue: queue, isEnabled: (_) => true,
            getAuthUserId: () async => 'user-1', remoteSink: sink,
            mayEgress: () async => false, mayEgressProfile: () async => false,
            fenceRetry: AccountFenceRetry(delay: (_) async {})).push();
        }
        expect(outgoing.length, outcome == '55P03' ? 2 : 1);
        expect(outgoing.every((row) => row.length == 2 &&
            row['ai_consent_granted'] == false && row['cloud_processing_enabled'] == false), isTrue);
        final after = (await _outbox(database)).single;
        expect(intent(after), intent(before), reason: 'narrow delivery never ACKs or consumes the full settings row');
        expect(after['owner_uid'], isNull, reason: 'NULL snapshot is exact, never a new ownership attribution');
        expect(after['attempt_count'], 0);
        expect(after['status'], outcome == 'QD001' ? 'parked' : 'pending');
        if (outcome == 'QD001') expect(after['failure_class'], 'account_deletion_pending');
      });
    });
  }

  test('E4 account field QD001 stops later default commands in the same invocation', () async {
    final admission = await LedgerAdmissionFixture.open();
    final database = admission.database;
    final location = admission.location;
    try {
      const now = '2026-07-01T00:00:00Z';
      await database.customStatement("INSERT INTO accounts(id,name,currency,type,is_default,sort_order,"
          "created_at,updated_at,initial_balance,current_balance) VALUES "
          "('account-e4','E4','SAR','bank',0,0,'$now','$now',0,0);");
      final queue = _queue(database);
      final account = AccountEntity(id: 'account-e4', name: 'E4', currency: 'SAR',
          type: AccountType.bank, isDefault: false, sortOrder: 0,
          createdAt: DateTime.utc(2026, 7, 1), updatedAt: DateTime.utc(2026, 7, 1),
          initialBalanceMoney: Money(0, 'SAR'), currentBalanceMoney: Money(0, 'SAR'));
      await queue.enqueueAccount(PlanningSyncOperation.create, account);
      await queue.enqueueAccountDefault('account-e4', 'default-op');
      final sink = _E4AccountSink();
      AccountsDeliveryStopped? result;
      try {
        await AccountsPushService(db: database, queue: queue, isEnabled: () => true,
          getAuthUserId: () async => 'user-1', mayEgress: () async => true, remoteSink: sink,
          fenceRetry: AccountFenceRetry(delay: (_) async {})).push();
      } on AccountsDeliveryStopped catch (error) { result = error; }
      expect(result?.reason, AccountsDeliveryStopReason.denial);
      expect(result!.accepted && result.parked && result.complete, isTrue);
      expect(database.lifecycleState, DatabaseLifecycleState.closed);
      expect(sink.fields, 1);
      expect(sink.defaults, 0);
      final rows = await LedgerAdmissionFixture.inspectClosed(database, location, _outbox);
      final field = rows.firstWhere((row) => row['entity_type'] == 'account');
      final command = rows.firstWhere((row) => row['entity_type'] == 'account_default_command');
      expect(field['status'], 'parked');
      expect(field['failure_class'], 'account_deletion_pending');
      expect(field['attempt_count'], 0);
      expect(command['status'], 'pending');
      expect(command['attempt_count'], 0, reason: 'the stopped service never even attempts its default command');
    } finally { await admission.finish(); }
  });

  test('E4 child QD001 stops later child types and the following pull', () async {
    final admission=await LedgerAdmissionFixture.open('user-1');
    final database=admission.database;final location=admission.location;
    final requests=<http.Request>[];
    await Supabase.initialize(url:'https://example.supabase.co',anonKey:'anon',authOptions:const FlutterAuthClientOptions(autoRefreshToken:false,detectSessionInUri:false,localStorage:EmptyLocalStorage(),pkceAsyncStorage:_ParentSdkStorage()),httpClient:MockClient((request)async{requests.add(request);return http.Response(jsonEncode({'code':'QD001','message':'refused','details':null,'hint':null}),400,headers:{'content-type':'application/json'},request:request);}));
    try{
      const now = '2026-07-01T00:00:00Z';
      await database.customStatement("INSERT INTO goals(id,name,target_amount,saved_amount,currency,"
          "target_amount_minor,saved_amount_minor,last_notified_saved_amount_minor,vault_skin,status,created_at,server_id,sync_status) "
          "VALUES ('goal-e4','E4',100,0,'EGP',10000,0,0,'classic','active','$now','server-goal','synced');");
      await database.customStatement("INSERT INTO goal_contributions(id,goal_id,amount,amount_minor,created_at) "
          "VALUES ('contribution-e4','goal-e4',25,2500,'$now');");
      final queue = _queue(database);
      await queue.enqueueGoalContribution(PlanningSyncOperation.create, GoalContributionEntity(
          id: 'contribution-e4', goalId: 'goal-e4', amountMoney: Money.parse('25', 'EGP'),
          createdAt: DateTime.utc(2026, 7, 1)));
      // A later child intent is queued through its actual public API. The first
      // refusal must stop before parent lookup, its RPC or a subsequent pull.
      await queue.enqueueBillPayment(PlanningSyncOperation.create, BillPaymentEntity(
          id: 'payment-e4', billId: 'bill-not-created', amountMoney: Money.parse('10', 'EGP'), currency: 'EGP',
          periodStart: DateTime.utc(2026, 7, 1), periodEnd: DateTime.utc(2026, 7, 31), paidAt: DateTime.utc(2026, 7, 1)));
      Object? stopped;
      try{await PlanningChildSyncService(db: database, queue: queue, isEnabled: (_) => true,
          isPullEnabled: (_) => true, getAuthUserId: () async => 'user-1',
          mayEgress: () async => true,
          pullCapability: () => ExactTransportCapability.verifiedExact,
          fenceRetry: AccountFenceRetry(delay: (_) async {})).sync();}on ChildDeliveryStopped catch(error){stopped=error;}
      expect(stopped,isA<ChildDeliveryStopped>().having((e)=>e.reason,'reason',ChildDeliveryStopReason.denial).having((e)=>e.accepted&&e.parked&&e.complete,'truthful completion',isTrue));
      expect(requests.map((r)=>r.url.path.split('/').last), ['add_goal_contribution']);
      expect(requests.where((r)=>r.method=='GET'),isEmpty,reason:'QD001 stops the entire current sync invocation');
      expect(database.lifecycleState,DatabaseLifecycleState.closed);
      final rows = await LedgerAdmissionFixture.inspectClosed(database,location,_outbox);
      final contribution = rows.firstWhere((row) => row['entity_type'] == 'goal_contribution');
      final payment = rows.firstWhere((row) => row['entity_type'] == 'bill_payment');
      expect(contribution['status'], 'parked');
      expect(contribution['failure_class'], 'account_deletion_pending');
      expect(contribution['attempt_count'], 0);
      expect(payment['status'], 'pending');
      expect(payment['attempt_count'], 0);
    }finally{await Supabase.instance.dispose();await admission.finish();}
  });

  test('E4 child successful push reaches verified pull transport', () async {
    await withFileDatabase((database, reopen) async {
      const now = '2026-07-01T00:00:00Z';
      await database.customStatement("INSERT INTO goals(id,name,target_amount,saved_amount,currency,"
          "target_amount_minor,saved_amount_minor,last_notified_saved_amount_minor,vault_skin,status,created_at,server_id,sync_status) "
          "VALUES ('goal-e4','E4',100,0,'EGP',10000,0,0,'classic','active','$now','server-goal','synced');");
      await database.customStatement("INSERT INTO goal_contributions(id,goal_id,amount,amount_minor,created_at) "
          "VALUES ('contribution-e4','goal-e4',25,2500,'$now');");
      final queue = _queue(database);
      await queue.enqueueGoalContribution(PlanningSyncOperation.create, GoalContributionEntity(
          id: 'contribution-e4', goalId: 'goal-e4', amountMoney: Money.parse('25', 'EGP'),
          createdAt: DateTime.utc(2026, 7, 1)));
      final remote = _E4ChildRemote(deny: false);
      await PlanningChildSyncService(db: database, queue: queue, isEnabled: (_) => true,
          isPullEnabled: (_) => true, getAuthUserId: () async => 'user-1',
          mayEgress: () async => true, remote: remote,
          pullCapability: () => ExactTransportCapability.verifiedExact,
          fenceRetry: AccountFenceRetry(delay: (_) async {})).sync();
      expect(remote.rpcs, ['add_goal_contribution']);
      expect(remote.fetchedTables, [
        'user_goal_contributions', 'user_bill_payments', 'user_plan_transaction_links',
      ], reason: 'the matching no-denial service reaches every enabled pull transport');
      expect(remote.pulls, 3);
      expect(await _outbox(database), isEmpty, reason: 'the successful RPC actually ACKs the queued child');
      final contribution = await database.customSelect(
          "SELECT sync_status, server_id FROM goal_contributions WHERE id = 'contribution-e4';").getSingle();
      expect(contribution.read<String>('sync_status'), 'synced');
      expect(contribution.read<String>('server_id'), 'server-contribution-e4');
    });
  });


}


class _E4AccountSink implements AccountsRemoteSink {
  int fields = 0;
  int defaults = 0;
  @override
  Future<Map<String, dynamic>> upsertAccount(Map<String, dynamic> row) async {
    fields++;
    throw const PostgrestException(message: 'refused', code: 'QD001');
  }
  @override
  Future<void> setDefaultAccount(String serverAccountId) async { defaults++; }
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('unexpected account call');
}

class _E4ChildRemote implements PlanningChildRemote {
  _E4ChildRemote({this.deny = true});
  final bool deny;
  final rpcs = <String>[];
  final fetchedTables = <String>[];
  int get pulls => fetchedTables.length;
  @override
  Future<Map<String, dynamic>> callRpc(String name, Map<String, dynamic> params) async {
    rpcs.add(name);
    if (deny) {
      throw const PostgrestException(message: 'refused', code: 'QD001');
    }
    return {
      'contribution': {
        'id': 'server-contribution-e4', 'updated_at': '2026-07-02T00:00:00Z',
      },
      'goal': {
        'id': params['p_goal_id'], 'saved_amount': params['p_amount'],
        'saved_amount_text': '${params['p_amount']}', 'currency': 'EGP',
        'updated_at': '2026-07-02T00:00:00Z',
      },
    };
  }
  @override
  Future<List<Map<String, dynamic>>> fetchRows(String table, {
    required SyncCursor after, int limit = 200,
  }) async {
    fetchedTables.add(table);
    return [];
  }
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected child call');
}


void _e4ConcreteMutationTests() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('E4 concrete SDK atomic boundaries', () {
    late Future<http.Response> Function(http.Request) respond;
    setUpAll(() async {
      await Supabase.initialize(url: 'https://example.supabase.co', anonKey: 'anon',
          authOptions: const FlutterAuthClientOptions(autoRefreshToken: false,detectSessionInUri:false,localStorage:EmptyLocalStorage(),pkceAsyncStorage:_ParentSdkStorage()),
          httpClient: MockClient((request) => respond(request)));
    });
    tearDownAll(() => Supabase.instance.dispose());
    http.Response reply(http.Request request, Object data, [int status = 200]) =>
        http.Response(jsonEncode(data), status, headers: {'content-type': 'application/json'}, request: request);
    for (final account in [false, true]) {
      for (final base in <String?>[null, '2026-07-01T00:00:00Z']) {
        for (final exhausted in [false, true]) {
          test('tombstone account=$account base=$base exhaustion=$exhausted', () async {
            final requests = <http.Request>[];
            var delays = 0;
            respond = (request) async {
              requests.add(request);
              if (exhausted || requests.length == 1) {
                return reply(request, {'message': 'busy', 'code': '55P03'}, 409);
              }
              return reply(request, [{'id': 'server-e4', 'updated_at': '2026-07-02T00:00:00Z'}]);
            };
            final run = AccountFenceRetry(delay: (_) async { delays++; }).runItem(
                isCurrent: () async => true,
                body: () => account
                    ? const SupabaseAccountsRemoteSink().guardedTombstoneAccount('server-e4', base)
                    : const SupabasePlanningRemoteSink().guardedTombstone('user_goals', 'server-e4', base));
            if (exhausted) {
              await expectLater(run, throwsA(isA<PostgrestException>().having((e) => e.code, 'code', '55P03')));
            } else {
              expect((await run)?['id'], 'server-e4');
            }
            expect(requests, hasLength(exhausted ? 3 : 2));
            expect(delays, exhausted ? 2 : 1);
            final first = requests.first;
            expect((jsonDecode(first.body) as Map)['deleted_at'], isA<String>());
            for (final request in requests.skip(1)) {
              expect(identical(first, request), isFalse, reason: 'each SDK retry constructs a fresh request');
              expect(request.url, first.url);
              expect(request.method, first.method);
              expect(request.body, first.body, reason: 'the tombstone timestamp is captured once');
            }
            expect(first.url.queryParameters[base == null ? 'deleted_at' : 'updated_at'],
                base == null ? 'is.null' : 'eq.$base');
          });
        }
      }
    }
    for (final mode in ['insert', 'revive', 'tombstone']) {
      for (final exhausted in [false, true]) {
        test('plan link $mode exhaustion=$exhausted replays mutation only', () async {
          final mutations = <http.Request>[];
          var reads = 0;
          respond = (request) async {
            if (request.method == 'GET') {
              reads++;
              return reply(request, mode == 'insert' ? [] : [{'id': 'link-e4', 'deleted_at': '2026-07-01T00:00:00Z'}]);
            }
            mutations.add(request);
            if (exhausted || mutations.length == 1) {
              return reply(request, {'message': 'busy', 'code': '55P03'}, 409);
            }
            return reply(request, mode == 'tombstone' ? [] : {'id': 'link-e4'});
          };
          final row = <String, dynamic>{'user_id': 'user-1', 'plan_id': 'plan-e4', 'transaction_id': 'tx-e4'};
          final run = AccountFenceRetry(delay: (_) async {}).runItem<Object?>(
              isCurrent: () async => true,
              body: () async {
                const remote = SupabasePlanningChildRemote();
                if (mode == 'tombstone') { await remote.tombstonePlanLink('link-e4'); return null; }
                return remote.upsertPlanLink(row);
              });
          if (exhausted) {
            await expectLater(run, throwsA(isA<PostgrestException>().having((e) => e.code, 'code', '55P03')));
          } else {
            final result = await run;
            if (mode != 'tombstone') expect((result as Map)['id'], 'link-e4');
          }
          expect(reads, mode == 'tombstone' ? 0 : 1, reason: 'the composite lookup is never retried');
          expect(mutations, hasLength(exhausted ? 3 : 2));
          for (final request in mutations.skip(1)) {
            expect(identical(request, mutations.first), isFalse);
            expect(request.url, mutations.first.url);
            expect(request.body, mutations.first.body);
          }
        });
      }
    }
    for (final off in [false, true]) {
      test('nested ${off ? 'OFF' : 'guarded update'} shares one SDK retry budget', () async {
        final requests = <http.Request>[];
        respond = (request) async {
          requests.add(request);
          return reply(request, {'message': 'busy', 'code': '55P03'}, 409);
        };
        final row = <String, dynamic>{'capture_enabled': false, 'planning_enabled': false};
        final run = AccountFenceRetry(delay: (_) async {}).runItem(
            isCurrent: () async => true,
            body: () => retryAccountFenceMutation(() => off
                ? const SupabasePlanningRemoteSink().updateByServerId('user_settings', 'settings-e4', row)
                : const SupabasePlanningRemoteSink().guardedUpdateByServerId('user_goals', 'goal-e4', 'base', row)));
        await expectLater(run, throwsA(isA<PostgrestException>().having((e) => e.code, 'code', '55P03')));
        expect(requests, hasLength(3), reason: 'outer and inner wrappers cannot multiply the budget');
        expect(requests.map((request) => request.body).toSet(), hasLength(1));
      });
    }
  });
}

class _ParentSdkStorage extends GotrueAsyncStorage {
  const _ParentSdkStorage();
  @override
  Future<String?> getItem({required String key})async=>null;
  @override
  Future<void> setItem({required String key,required String value})async{}
  @override
  Future<void> removeItem({required String key})async{}
}
