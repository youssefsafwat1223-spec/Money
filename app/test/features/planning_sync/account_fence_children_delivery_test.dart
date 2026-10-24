import 'dart:async';
import 'package:drift/drift.dart' show QueryExecutor, QueryExecutorUser, SqlDialect, BatchedStatements, TransactionExecutor;
import 'package:money_companion/core/sync/account_fence_retry.dart';
import 'package:money_companion/core/sync/sync_health.dart';
import 'package:money_companion/data/sync/revision_cas.dart';
import 'package:money_companion/data/sync/server_capabilities.dart';
import 'package:money_companion/data/sync/seq_pull.dart';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/session/account_fence_authority.dart';
import 'package:money_companion/core/session/account_fence_store.dart';
import 'package:money_companion/core/sync/outbox_failure.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/data/db/planning_cutover.dart';
import 'package:money_companion/data/sync/exact_transport_capability.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/planning_sync/services/planning_child_sync_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../capture/ledger_admission_fixture.dart';

const _uid = 'user-child';
const _created = '2026-10-01T00:00:00.000Z';
const _updated = '2026-10-02T00:00:00.000Z';
const _canonical = FixedPlanningCutoverCoordinator(PlanningCutoverState.canonical);

enum _Lane { goal, payment, link }

Future<List<Map<String, Object?>>> _outbox(AppDatabase db) async => [
  for (final row in await db.customSelect(
      'SELECT * FROM planning_sync_outbox ORDER BY created_at, id;').get()) row.data,
];

Future<Map<String, Object?>> _row(AppDatabase db, String table, String predicate) async =>
    (await db.customSelect('SELECT * FROM $table WHERE $predicate;').getSingle()).data;

Map<String, Object?> _intent(Map<String, Object?> row) => {
  for (final key in ['id', 'entity_type', 'entity_id', 'operation', 'owner_uid',
    'payload_json', 'op_seq', 'operation_id', 'base_revision']) key: row[key],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Future<http.Response> Function(http.Request) respond;
  setUpAll(() async {
    await Supabase.initialize(url: 'https://example.supabase.co', anonKey: 'anon',
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false,
            detectSessionInUri: false, localStorage: EmptyLocalStorage(),
            pkceAsyncStorage: _MemorySdkStorage()),
        httpClient: MockClient((request) => respond(request)));
  });
  tearDownAll(() => Supabase.instance.dispose());

  Future<void> withChild(Future<void> Function(_ChildHarness) body,{_Lane lane=_Lane.goal,LedgerDatabaseProbe? probe})async{
    final admission=await LedgerAdmissionFixture.open(_uid,probe);
    final h=_ChildHarness(admission,lane);
    try{
      await _seedParents(h.db);await _seedIntent(h.db,h.queue,lane);
      respond=(request)async{h.requests.add(request);return h.respond(request);};
      await body(h);
    }finally{
      for(final c in h.releases){if(!c.isCompleted)c.complete();}
      try{await Future.wait(h.producers);}finally{await admission.finish();}
    }
  }

  for (final lane in _Lane.values) {
    for (final success in [false, true]) {
      final code = lane == _Lane.payment ? 'QD002' : 'QD001';
      test('E4 children ${lane.name} ${success ? 'success receipt ACK counter and positive pull' : '$code retires original authority and stops later child/pull'}', () async {
        final admission = await LedgerAdmissionFixture.open(_uid);
        final db = admission.database;
        final location = admission.location;
        Future<void>? producer;
        try {
          await _seedParents(db);
          final queue = PlanningOutboxQueue(db: db, isSyncEnabled: (_) => true,
              getAuthUserId: () async => _uid,
              getOwnerUid: admission.fixture.session.readLocalDataOwnerUid,
              coordinator: _canonical);
          await _seedIntent(db, queue, lane);
          // A reachable later mutation is public queued intent, never a seeded
          // parked flag. The goal's later child is a payment; other lanes have
          // a later plan link (a different link for the primary link case).
          if (lane == _Lane.goal) {
            await _seedPayment(db, queue);
          } else {
            await _seedLink(db, queue, transaction: 'tx-2');
          }
          final before = await _outbox(db);
          final primary = before.singleWhere((r) => r['entity_id'] == _entityId(lane));
          final later = before.singleWhere((r) => r['entity_id'] != _entityId(lane));
          expect(before, hasLength(2));
          expect(before.every((r) => r['owner_uid'] == _uid && r['attempt_count'] == 0), isTrue);
          expect(primary['operation_id'], matches(RegExp(
              r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')));
          expect(await _outbox(db), before, reason: 'snapshot inspection does not hand out the row');
          expect(await db.customSelect("SELECT * FROM planning_sync_outbox WHERE entity_type IN ('goal','subscription');").get(), isEmpty);
          final childBefore = await _child(db, lane);
          final goalBefore = await _row(db, 'goals', "id='goal-1'");
          final subscriptionBefore = await _row(db, 'subscriptions', "id='bill-1'");
          expect(subscriptionBefore['sync_status'], 'synced');
          final cap = admission.fixture.session.captureLocalWorkAuthority()!;
          final maintenance = await admission.fixture.session.maintenanceAuthority(_uid);
          expect(cap.isCurrent && maintenance.isCurrent, isTrue);
          final requests = <http.Request>[];
          final mutations = <http.Request>[];
          final pulls = <http.Request>[];
          final lookups = <http.Request>[];
          var primaryMutationReached = false;
          http.Request? primaryRequest;
          Map<String,Object?>? handedSnapshot;
          respond = (request) async {
            requests.add(request);
            final path = request.url.path;
            if (request.method == 'GET') {
              if (path == '/rest/v1/user_plan_transaction_links' &&
                  request.url.queryParameters.containsKey('plan_id')) {
                lookups.add(request);
                expect(request.url.queryParameters['user_id'], 'eq.$_uid');
                expect(request.url.queryParameters['plan_id'], 'eq.server-plan-1');
                expect(request.url.queryParameters['transaction_id'],
                    anyOf('eq.server-tx-1', 'eq.server-tx-2'));
                return _reply(request, null);
              }
              expect(path, anyOf('/rest/v1/user_goal_contributions',
                  '/rest/v1/user_bill_payments', '/rest/v1/user_plan_transaction_links'));
              pulls.add(request);
              expect(primaryMutationReached, isTrue);
              return _reply(request, <Object?>[]);
            }
            mutations.add(request);
            expect(request.method, 'POST');
            final body = (jsonDecode(request.body) as Map).cast<String, dynamic>();
            final isPrimary = switch (lane) {
              _Lane.goal => path == '/rest/v1/rpc/add_goal_contribution',
              _Lane.payment => path == '/rest/v1/rpc/record_bill_payment',
              _Lane.link => path == '/rest/v1/user_plan_transaction_links' &&
                  body['transaction_id'] == 'server-tx-1',
            };
            if (isPrimary) {
              expect(primaryMutationReached, isFalse);
              primaryMutationReached = true;
              primaryRequest=request;
              _assertPrimaryRequest(lane, request, body);
              final handed = (await _outbox(db)).singleWhere((r) => r['id'] == primary['id']);
              handedSnapshot=handed;
              expect(_intent(handed), _intent(primary));
              expect(handed['in_flight_seq'], primary['op_seq']);
              final untouched = (await _outbox(db)).singleWhere((r) => r['id'] == later['id']);
              expect(_intent(untouched), _intent(later));
              expect(untouched['attempt_count'], 0);
              if (!success) {
                return _reply(request, {'code': code, 'message': 'synthetic structured refusal',
                  'details': null, 'hint': null}, status: 400);
              }
            } else {
              expect(primaryMutationReached, isTrue);
            }
            if (path == '/rest/v1/rpc/add_goal_contribution') return _reply(request, _goalReceipt(body));
            if (path == '/rest/v1/rpc/record_bill_payment') return _reply(request, _paymentReceipt(body));
            expect(path, '/rest/v1/user_plan_transaction_links');
            return _reply(request, {...body, 'id': body['transaction_id'] == 'server-tx-1'
                ? 'server-link-1' : 'server-link-2', 'updated_at': _updated, 'deleted_at': null});
          };
          final service = PlanningChildSyncService(db: db, queue: queue,
              isEnabled: (_) => true, isPullEnabled: (_) => true,
              getAuthUserId: () async => _uid, mayEgress: () async => true,
              coordinator: _canonical,
              pushCapability: () => ExactTransportCapability.verifiedExact,
              pullCapability: () => ExactTransportCapability.verifiedExact);
          producer = service.sync();
          try { await producer; } on AccountFenceDeliveryCancellation {
            // A future implementation may return the shared typed stop; no
            // new child API/type is required to compile this StageA witness.
          }
          expect(primaryMutationReached, isTrue, reason: 'real mutating SDK HTTP reached before the primary behavioral assertion');
          expect(mutations, isNotEmpty);
          expect(primaryRequest,isNotNull);
          _assertPrimaryRequest(lane,primaryRequest!,
              (jsonDecode(primaryRequest!.body)as Map).cast<String,dynamic>());
          expect(_intent(handedSnapshot!),_intent(primary));
          expect(handedSnapshot!['in_flight_seq'],primary['op_seq']);
          if (!success) {
            // Primary behavioral RED in current code. Further safety checks
            // below are intentionally documented as unreached until fixed.
            expect(cap.isCurrent, isFalse, reason: 'a current raw child refusal retires the original admitted capability');
            expect(maintenance.isCurrent, isFalse);
            expect(AccountFenceAuthority.shared.store.holdFor(
                AccountFenceStore.ownerDigest(_uid))?.state,
                code == 'QD001' ? AccountFenceState.pending : AccountFenceState.gone);
            expect(mutations, hasLength(1)); expect(pulls, isEmpty);
            expect(lookups, hasLength(lane == _Lane.link ? 1 : 0));
            expect(db.lifecycleState, DatabaseLifecycleState.closed);
            final after = await LedgerAdmissionFixture.inspectClosed(db, location, _outbox);
            final rejected = after.singleWhere((r) => r['id'] == primary['id']);
            expect(_intent(rejected), _intent(primary));
            expect(rejected['attempt_count'], 0); expect(rejected['status'], 'parked');
            expect(rejected['in_flight_seq'], primary['op_seq']);
            expect(rejected['failure_class'], code == 'QD001'
                ? 'account_deletion_pending' : 'account_deletion_gone');
            final retained = after.singleWhere((r) => r['id'] == later['id']);
            expect(_intent(retained), _intent(later)); expect(retained['attempt_count'], 0);
            expect(retained['status'], 'pending');
            expect(await LedgerAdmissionFixture.inspectClosed(db, location, (inspection) => _child(inspection, lane)), childBefore);
            expect(await LedgerAdmissionFixture.inspectClosed(db, location, (inspection) => _row(inspection, 'goals', "id='goal-1'")), goalBefore);
            expect(await LedgerAdmissionFixture.inspectClosed(db, location, (inspection) => _row(inspection, 'subscriptions', "id='bill-1'")), subscriptionBefore);
          } else {
            expect(cap.isCurrent && maintenance.isCurrent, isTrue);
            expect(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(_uid)), isNull);
            expect(await _outbox(db), isEmpty);
            expect(mutations, hasLength(2));
            expect(pulls.map((r) => r.url.path), ['/rest/v1/user_goal_contributions',
              '/rest/v1/user_bill_payments', '/rest/v1/user_plan_transaction_links']);
            expect(lookups, hasLength(lane == _Lane.goal ? 0 : lane == _Lane.payment ? 1 : 2));
            final child = await _child(db, lane);
            expect(child['server_id'], switch (lane) {
              _Lane.goal => 'server-gc-1', _Lane.payment => 'server-bp-1', _Lane.link => 'server-link-1',
            });
            expect(child['server_updated_at'], _updated);
            expect(child['sync_status'], 'synced'); expect(child['synced_at'], isNotNull);
            if (lane == _Lane.goal) {
              final goal = await _row(db, 'goals', "id='goal-1'");
              expect(goal['saved_amount_minor'], 2500); expect(goal['saved_amount'], 25.0);
              expect(goal['server_updated_at'], _updated); expect(goal['synced_at'], isNotNull);
              expect(goal['sync_status'], goalBefore['sync_status']);
            }
            if (lane != _Lane.link) {
              final subscription = await _row(db, 'subscriptions', "id='bill-1'");
              expect(subscription['paid_count'], 1); expect(subscription['manual_paid_amount_minor'], 0);
              expect(subscription['server_updated_at'], _updated);
              expect(subscription['sync_status'], 'synced'); expect(subscription['synced_at'], isNotNull);
            }
            expect(requests.indexOf(pulls.first), greaterThan(requests.indexOf(mutations.last)));
          }
        } finally {
          try {
            if (producer != null) {
              try { await producer; } on AccountFenceDeliveryCancellation { /* observed typed stop */ }
            }
          } finally { await admission.finish(); }
        }
      });
    }
  }
  test('E4 child custom read refusal after actual earlier mutation has no inherited origin',()async{
    await withChild((h)async{
      await _seedLink(h.db,h.queue);
      final before=(await _outbox(h.db)).singleWhere((r)=>r['entity_type']=='plan_transaction_link');
      final remote=_ReadRefusalAfterConcreteMutation();
      final result=await _childStop(h.service(remote:remote).sync());
      expect(remote.lookupReached,isTrue);expect(h.requests.map((r)=>r.url.path),['/rest/v1/rpc/add_goal_contribution']);
      expect(result.reason,ChildDeliveryStopReason.nonMutationRefusal);
      expect(result.accepted||result.parked||result.complete,isFalse);
      final after=(await _outbox(h.db)).single;
      expect(_intent(after),_intent(before));expect(after['attempt_count'],0);expect(after['status'],'pending');
      expect((await _row(h.db,'goals',"id='goal-1'"))['saved_amount_minor'],2500);
      expect(h.admission.fixture.session.captureLocalWorkAuthority()!.isCurrent,isTrue);
      expect(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(_uid)),isNull);
    });
  });

  test('E4 child actual SDK maybeSingle normalizes read QD into ordinary HTTP400',()async{
    await withChild((h)async{
      var code='';
      h.respond=(r)async=>_reply(r,{'code':'QD002','message':'read refusal','details':null,'hint':null},status:400);
      try{await const SupabasePlanningChildRemote().findPlanLink(userId:_uid,planId:'server-plan-1',transactionId:'server-tx-1');fail('expected SDK refusal');}
      on PostgrestException catch(error){code=error.code!;expect(decodeChildAccountDenial(error),isNull);}
      expect(code,'400');expect(h.requests.single.method,'GET');
      expect(AccountFenceAuthority.shared.permits(_uid),isTrue);
    },lane:_Lane.link);
  });

  test('E4 child unproven synchronous custom remote raw refusal stops without hold',()async{
    await withChild((h)async{
      final before=(await _outbox(h.db)).single;
      expect((await _childStop(h.service(remote:_SynchronousRawChild()).sync())).reason,ChildDeliveryStopReason.nonMutationRefusal);
      expect(_intent((await _outbox(h.db)).single),_intent(before));expect((await _outbox(h.db)).single['attempt_count'],0);
      expect(h.requests,isEmpty);expect(AccountFenceAuthority.shared.permits(_uid),isTrue);
    });
  });

  test('E4 child receipt parsing failure is ordinary and never mutation denial',()async{
    await withChild((h)async{
      final before=(await _outbox(h.db)).single;
      final childBefore=await _child(h.db,_Lane.goal);
      final parentBefore=await _row(h.db,'goals',"id='goal-1'");
      h.respond=(r)async=>r.method=='GET'?_reply(r,[]):_reply(r,{'contribution':'not a receipt','goal':{}});
      await h.service().sync();
      expect(h.requests.first.method,'POST');
      final after=(await _outbox(h.db)).single;
      expect(after['attempt_count'],0);expect(after['status'],'dead_letter');
      expect(after['failure_class'],OutboxFailureClass.corruptedPayload.reason);
      expect(_intent(after),_intent(before));
      expect(await _child(h.db,_Lane.goal),childBefore);
      expect(await _row(h.db,'goals',"id='goal-1'"),parentBefore);
      expect(AccountFenceAuthority.shared.permits(_uid),isTrue);
      expect(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(_uid)),isNull);
    });
  });

  test('E4 child original negative survives held store readiness read',()async{
    await withChild((h)async{
      final reached=Completer<void>();final response=h.release();
      h.respond=(r)async{reached.complete();await response.future;return _reply(r,{'code':'QD001','message':'mutation refusal'},status:400);};
      final running=h.track(_childStop(h.service().sync()));await reached.future;
      final hold=h.admission.fixture.storage.holdOnce((op,key)=>op=='read'&&key==AccountFenceStore.storageKey);h.releases.add(hold.release);
      final loading=h.track(AccountFenceAuthority.shared.initialize());await hold.reached.future;
      expect(h.admission.fixture.session.captureLocalWorkAuthority()!.isCurrent,isFalse);
      final accepted=Completer<void>();
      void listener(){if(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(_uid))!=null&&!accepted.isCompleted){accepted.complete();}}
      h.admission.fixture.session.addListener(listener);
      try{response.complete();expect(await Future.any([accepted.future.then((_)=>true),running.then((_)=>false)]),isTrue);}
      finally{h.admission.fixture.session.removeListener(listener);hold.release.complete();}
      final result=await running;await loading;expect(result.accepted&&result.parked&&result.complete,isTrue);
    });
  });

  for(final successor in [_uid,'child-B']){
    test('E4 child stale mutation response preserves original and successor $successor',()async{
      await withChild((h)async{
        final reached=Completer<void>();final response=h.release();final db=h.db;final location=h.admission.location;
        h.respond=(r)async{reached.complete();await response.future;return successor==_uid?h.success(r):_reply(r,{'code':'QD002','message':'late refusal'},status:400);};
        final running=h.track(_childStop(h.service().sync()));await reached.future;
        final rows=await _outbox(db);final goal=await _row(db,'goals',"id='goal-1'");final child=await _child(db,_Lane.goal);
        await h.admission.fixture.signIn(successor);final scope=h.admission.fixture.host.current;final cap=h.admission.fixture.session.captureLocalWorkAuthority()!;
        response.complete();final result=await running;expect(result.accepted||result.parked||result.complete,isFalse);
        expect(h.admission.fixture.host.current,same(scope));expect(cap.isCurrent,isTrue);expect(h.requests,hasLength(1));
        Future<T> read<T>(Future<T>Function(AppDatabase) f)=>db.lifecycleState==DatabaseLifecycleState.closed?LedgerAdmissionFixture.inspectClosed(db,location,f):f(db);
        expect(await read(_outbox),rows);expect(await read((db)=>_row(db,'goals',"id='goal-1'")),goal);expect(await read((db)=>_child(db,_Lane.goal)),child);
      });
    });
  }

  for(final retirePhase in [false,true]){
    test('E4 child bound epoch additional phase controls held capability retired=$retirePhase',()async{
      await withChild((h)async{
        final a=AccountFenceAuthority.shared;final handle=(await a.capture(h.admission.fixture.session,h.admission.fixture.host))!;
        final lifecycle=_RestrictedChildPhase(a,handle,h.db);final phase=SyncPhaseBinding()..bind(lifecycle);
        final reached=Completer<void>();final release=h.release();var heads=0;
        final gate=RevisionCasGate(db:h.db,capability:()async{reached.complete();await release.future;return ServerCapabilityState.verified;},remote:_ChildHead(()async{heads++;return const SyncHead(lastSeq:1,epoch:'child-epoch');}));
        final running=h.track(gate.deleteEpochForChildren(_uid,authority:a,handle:handle,database:h.db,phase:phase).then<Object?>((v)=>v,onError:(Object e)=>e));
        await reached.future;if(retirePhase)lifecycle.enabled=false;release.complete();final result=await running;
        if(retirePhase){expect(result,isA<ChildDeliveryStopped>().having((e)=>e.reason,'reason',ChildDeliveryStopReason.stale));expect(heads,0);}
        else{expect(result,'child-epoch');expect(heads,1);}
        expect(a.isCurrentForDatabase(handle,h.db),isTrue);expect(h.requests,isEmpty);
      });
    });
  }

  for(final cap in [ServerCapabilityState.unknown,ServerCapabilityState.verified,ServerCapabilityState.unsupported]){
    test('E4 child delete epoch no head preserves protocol disposition $cap',()async{
      await withChild((h)async{
        await h.db.customStatement("UPDATE goal_contributions SET server_id='server-gc-1';");await h.db.customStatement("UPDATE planning_sync_outbox SET operation='delete';");
        final gate=RevisionCasGate(db:h.db,capability:()async=>cap,remote:_ChildHead(()async=>null));
        await h.service(gate:gate).sync();final row=(await _outbox(h.db)).single;
        expect(h.requests.every((r)=>r.method=='GET'),isTrue);
        expect(h.requests,hasLength(3),reason:'epoch protocol uncertainty retains current lifetime following pull');
        if(cap==ServerCapabilityState.unsupported){expect(row['status'],'dead_letter');expect(row['failure_class'],'permanentValidation');}
        else{expect(row['status'],'pending');expect(row['attempt_count'],0);expect(row['in_flight_seq'],isNull);}
        expect(AccountFenceAuthority.shared.permits(_uid),isTrue);
      });
    });
  }

  test('E4 child concrete link undelete retries the same bounded mutation',()async{
    await withChild((h)async{
      h.respond=(r)async{
        if(r.method=='GET')return r.url.queryParameters.containsKey('plan_id')?_reply(r,{'id':'server-link-1','updated_at':_updated,'deleted_at':_created}):_reply(r,[]);
        if(h.requests.where((r)=>r.method=='PATCH').length==1)return _reply(r,{'code':'55P03','message':'busy','details':null,'hint':null},status:400);
        return _reply(r,{'id':'server-link-1','updated_at':_updated,'deleted_at':null});
      };
      await h.service(retry:AccountFenceRetry(delay:(_)async{})).sync();
      final patches=h.requests.where((r)=>r.method=='PATCH').toList();
      expect(patches,hasLength(2));expect(identical(patches[0],patches[1]),isFalse);
      expect(patches[0].url,patches[1].url);expect(patches[0].body,patches[1].body);
      expect(jsonDecode(patches.singleWhere((r)=>identical(r,patches.first)).body),{'deleted_at':null});
      expect(await _outbox(h.db),isEmpty);expect((await _child(h.db,_Lane.link))['server_id'],'server-link-1');
    },lane:_Lane.link);
  });

  test('E4 child concrete link lookup successor prevents following mutation',()async{
    await withChild((h)async{
      final reached=Completer<void>();final release=h.release();final db=h.db;final loc=h.admission.location;
      h.respond=(r)async{reached.complete();await release.future;return _reply(r,null);};
      final running=h.track(_childStop(h.service().sync()));await reached.future;
      final before=await _outbox(db);final child=await _child(db,_Lane.link);
      final oldCap=h.admission.fixture.session.captureLocalWorkAuthority()!;
      await h.admission.fixture.signIn(_uid);release.complete();
      expect((await running).reason,ChildDeliveryStopReason.stale);expect(oldCap.isCurrent,isFalse);expect(h.requests.map((r)=>r.method),['GET']);
      Future<T> inspect<T>(Future<T>Function(AppDatabase) read)=>db.lifecycleState==DatabaseLifecycleState.closed?LedgerAdmissionFixture.inspectClosed(db,loc,read):read(db);
      expect(await inspect(_outbox),before);expect(await inspect((db)=>_child(db,_Lane.link)),child);
      expect(h.admission.fixture.session.captureLocalWorkAuthority()!.isCurrent,isTrue);
    },lane:_Lane.link);
  });

  test('E4 child actual goal tombstone preserves RPC receipt and applies counter',()async{
    await withChild((h)async{
      await h.db.customStatement("UPDATE goal_contributions SET server_id='server-gc-1';");
      await h.db.customStatement("UPDATE planning_sync_outbox SET operation='delete';");
      h.respond=(r)async=>r.method=='GET'?_reply(r,[]):_reply(r,{'outcome':'applied','row':{'id':'server-gc-1','goal_id':'server-goal-1','updated_at':_updated,'deleted_at':_updated},'goal':{'id':'server-goal-1','currency':'EGP','saved_amount_text':'0.00','updated_at':_updated}});
      final gate=RevisionCasGate(db:h.db,capability:()async=>ServerCapabilityState.verified,remote:_ChildHead(()async=>const SyncHead(lastSeq:2,epoch:'delete-epoch')));
      await h.service(gate:gate).sync();
      expect(h.requests.first.url.path,'/rest/v1/rpc/sync_tombstone_goal_contribution');
      expect(jsonDecode(h.requests.first.body),{'p_expected_epoch':'delete-epoch','p_id':'server-gc-1'});
      expect(await _outbox(h.db),isEmpty);expect((await _row(h.db,'goals',"id='goal-1'"))['saved_amount_minor'],0);
      expect((await _child(h.db,_Lane.goal))['sync_status'],'synced');
    });
  });

  test('E4 child actual missing payment delete receipt converges without counter rewrite',()async{
    await withChild((h)async{
      await h.db.customStatement("UPDATE bill_payments SET server_id='server-bp-1';");
      await h.db.customStatement("UPDATE planning_sync_outbox SET operation='delete';");
      final parent=await _row(h.db,'subscriptions',"id='bill-1'");
      h.respond=(r)async=>r.method=='GET'?_reply(r,[]):_reply(r,{'payment':null,'subscription':null});
      await h.service().sync();expect(h.requests.first.url.path,'/rest/v1/rpc/delete_bill_payment');
      expect(jsonDecode(h.requests.first.body),{'p_payment_id':'server-bp-1'});
      expect(await _outbox(h.db),isEmpty);expect(await _row(h.db,'subscriptions',"id='bill-1'"),parent);
    },lane:_Lane.payment);
  });

  for(final holder in ['coalesced','null']){
    test('E4 child ACK counter exact holder $holder',()async{
      await withChild((h)async{
        final reached=Completer<void>();final release=h.release();
        h.respond=(r)async{if(r.method=='GET')return h.success(r);if(!reached.isCompleted)reached.complete();await release.future;return h.success(r);};
        final running=h.track(h.service().sync());await reached.future;
        if(holder=='coalesced'){
          await h.queue.enqueueGoalContribution(PlanningSyncOperation.create,GoalContributionEntity(id:'gc-1',goalId:'goal-1',amountMoney:Money.parse('25','EGP'),createdAt:DateTime.parse(_created),note:'new intent'));
        }else{await h.db.customStatement('UPDATE planning_sync_outbox SET in_flight_seq=NULL;');}
        final before=(await _outbox(h.db)).single;final child=await _child(h.db,_Lane.goal);final parent=await _row(h.db,'goals',"id='goal-1'");
        release.complete();await running;final after=(await _outbox(h.db)).single;
        if(holder=='null'){
          expect(after,before);expect(await _child(h.db,_Lane.goal),child);expect(await _row(h.db,'goals',"id='goal-1'"),parent);
        }else{
          expect(after['op_seq'],before['op_seq']);expect(after['payload_json'],before['payload_json']);expect(after['operation_id'],before['operation_id']);expect(after['attempt_count'],0);
          expect(after['status'],'pending');expect(after['in_flight_seq'],isNull);
          expect((await _row(h.db,'goals',"id='goal-1'"))['saved_amount_minor'],2500);
          expect((await _child(h.db,_Lane.goal))['server_id'],'server-gc-1');expect((await _child(h.db,_Lane.goal))['sync_status'],isNot('synced'));
        }
        expect(h.requests.where((r)=>r.method=='POST'),hasLength(1));
      });
    });
  }

  test('E4 child started ACK counter transaction terminal precedes physical close',()async{
    final probe=_ChildCommitProbe();
    await withChild((h)async{
      final authority=AccountFenceAuthority.shared;final handle=(await authority.capture(h.admission.fixture.session,h.admission.fixture.host))!;
      final reached=Completer<void>();final release=h.release();var terminal=false;var early=false;
      probe.before=(sql)async{if(sql.trimLeft().startsWith('UPDATE goals SET')&&!reached.isCompleted){terminal=false;reached.complete();await release.future;}};
      probe.onOuterTerminal=()=>terminal=true;probe.onClose=(){if(!terminal)early=true;};
      final running=h.track(_childStop(h.service().sync()));
      expect(await Future.any([reached.future.then((_)=>true),running.then((_)=>false)]),isTrue);
      final denied=h.track(authority.accept(handle,AccountFenceState.pending,operationId:'00000000-0000-0000-0000-000000000099'));
      expect(probe.closeAttempts,0);release.complete();await running;
      expect((await denied).complete,isTrue);expect(terminal,isTrue);expect(early,isFalse);
      expect(h.requests.map((r)=>r.method),['POST']);
    },probe:probe);
  });

  test('E4 child parking failure remains restrictive incomplete and retains intent',()async{
    final probe=LedgerDatabaseProbe();
    await withChild((h)async{
      final db=h.db;final loc=h.admission.location;final before=(await _outbox(db)).single;final child=await _child(db,_Lane.goal);
      h.respond=(r)async=>_reply(r,{'code':'QD001','message':'mutation refusal','details':null,'hint':null},status:400);
      var reached=false;
      probe.before=(sql)async{if(sql.trimLeft().startsWith("UPDATE planning_sync_outbox SET status = 'parked'")&&sql.contains('account_deletion_pending')){reached=true;throw StateError('controlled child parking failure');}};
      final result=await _childStop(h.service().sync());expect(reached,isTrue);
      expect(result.reason,ChildDeliveryStopReason.denial);expect(result.accepted,isTrue);expect(result.parked,isFalse);expect(result.complete,isFalse);
      expect(db.lifecycleState,DatabaseLifecycleState.closed);expect(AccountFenceAuthority.shared.permits(_uid),isFalse);
      final after=(await LedgerAdmissionFixture.inspectClosed(db,loc,_outbox)).single;
      expect(_intent(after),_intent(before));expect(after['attempt_count'],0);expect(after['status'],'pending');
      expect(await LedgerAdmissionFixture.inspectClosed(db,loc,(db)=>_child(db,_Lane.goal)),child);expect(h.requests,hasLength(1));
    },probe:probe);
  });

  test('E4 child direct missing binding and concurrent overlap refuse without extra work',()async{
    await withChild((h)async{
      final service=h.service();final reached=Completer<void>();final release=h.release();
      h.respond=(r)async{if(r.method=='GET')return h.success(r);if(!reached.isCompleted)reached.complete();await release.future;return h.success(r);};
      final running=h.track(service.sync());await reached.future;
      expect((await _childStop(service.sync())).reason,ChildDeliveryStopReason.overlap);
      expect(h.requests,hasLength(1));release.complete();await running;expect(await _outbox(h.db),isEmpty);
      h.admission.fixture.session.configureAccountScope(null);
      expect((await _childStop(h.service().sync())).reason,ChildDeliveryStopReason.unbound);expect(h.requests.where((r)=>r.method=='POST'),hasLength(1));
      h.admission.fixture.session.configureAccountScope(h.admission.fixture.host);
    });
  });

  test('E4 child link final awaited queue currency refuses retired supplied phase',()async{
    final probe=LedgerDatabaseProbe();
    await withChild((h)async{
      final a=AccountFenceAuthority.shared;final handle=(await a.capture(h.admission.fixture.session,h.admission.fixture.host))!;
      final lifecycle=_RestrictedChildPhase(a,handle,h.db);final phase=SyncPhaseBinding()..bind(lifecycle);var reached=false;
      probe.afterSelect=(sql)async{if(sql.startsWith('SELECT 1 FROM planning_sync_outbox')&&sql.contains('operation_id =')){reached=true;lifecycle.enabled=false;}};
      final before=(await _outbox(h.db)).single;final child=await _child(h.db,_Lane.link);
      expect((await _childStop(h.service().syncWithPhase(phase))).reason,ChildDeliveryStopReason.stale);
      expect(reached,isTrue);expect(h.requests.map((r)=>r.method),['GET']);
      expect(_intent((await _outbox(h.db)).single),_intent(before));expect((await _outbox(h.db)).single['attempt_count'],0);
      expect(await _child(h.db,_Lane.link),child);expect(a.isCurrentForDatabase(handle,h.db),isTrue);
    },lane:_Lane.link,probe:probe);
  });

  test('E4 child bound epoch recorded read errors remain errors and shared cancellation propagates',()async{
    final probe=LedgerDatabaseProbe();
    await withChild((h)async{
      final a=AccountFenceAuthority.shared;final handle=(await a.capture(h.admission.fixture.session,h.admission.fixture.host))!;
      final phase=SyncPhaseBinding()..bind(_RestrictedChildPhase(a,handle,h.db));var heads=0;var reached=false;
      final readError=StateError('controlled recorded epoch read');
      probe.before=(sql)async{if(sql.contains("entity = 'seq_epoch:")){reached=true;throw readError;}};
      final gate=RevisionCasGate(db:h.db,capability:()async=>ServerCapabilityState.verified,remote:_ChildHead(()async{heads++;return null;}));
      await expectLater(gate.deleteEpochForChildren(_uid,authority:a,handle:handle,database:h.db,phase:phase),throwsA(same(readError)));
      expect(reached,isTrue);expect(heads,0);probe.before=null;
      const cancelled=LedgerDeliveryStopped(LedgerDeliveryStopReason.stale);
      final cancelledGate=RevisionCasGate(db:h.db,capability:()async=>throw cancelled,remote:_ChildHead(()async{heads++;return null;}));
      await expectLater(cancelledGate.deleteEpochForChildren(_uid,authority:a,handle:handle,database:h.db,phase:phase),throwsA(same(cancelled)));
      expect(heads,0);expect(a.isCurrentForDatabase(handle,h.db),isTrue);expect(h.requests,isEmpty);
    },probe:probe);
  });

  test('E4 child exact health phase records consent refusal without borrowing global notes',()async{
    await withChild((h)async{
      final health=SyncHealth(db:h.db);final phase=SyncPhaseBinding();
      final service=PlanningChildSyncService(db:h.db,queue:h.queue,isEnabled:(_)=>true,getAuthUserId:()async=>_uid,mayEgress:()async=>false,health:health);
      final before=await _outbox(h.db);
      await health.runPhase(SyncDomain.children,SyncDirection.push,()=>service.syncWithPhase(phase),binding:phase,rethrowErrors:true);
      expect(phase.isBound,isTrue);expect(phase.isCurrent,isTrue);expect(health.of(SyncDomain.children).lastErrorClass,SyncErrorClass.consentBlocked);
      expect(health.of(SyncDomain.children).consecutiveFailures,0);expect(await _outbox(h.db),before);expect(h.requests,isEmpty);
      final persisted=await h.db.customSelect("SELECT last_id FROM sync_cursors WHERE entity='sync_health:children';").getSingle();
      expect(persisted.read<String>('last_id'),contains('consentBlocked'));
    });
  });


}

String _entityId(_Lane lane) => switch (lane) {
  _Lane.goal => 'gc-1', _Lane.payment => 'bp-1', _Lane.link => 'plan-1:tx-1',
};
Future<Map<String, Object?>> _child(AppDatabase db, _Lane lane) => switch (lane) {
  _Lane.goal => _row(db, 'goal_contributions', "id='gc-1'"),
  _Lane.payment => _row(db, 'bill_payments', "id='bp-1'"),
  _Lane.link => _row(db, 'plan_transaction_links', "plan_id='plan-1' AND transaction_id='tx-1'"),
};
http.Response _reply(http.Request request, Object? data, {int status = 200}) =>
    http.Response(jsonEncode(data), status,
        headers: {'content-type': 'application/json'}, request: request);

void _assertPrimaryRequest(_Lane lane, http.Request request, Map<String, dynamic> body) {
  switch (lane) {
    case _Lane.goal:
      expect(request.url.path, '/rest/v1/rpc/add_goal_contribution');
      expect(body, {'p_goal_id': 'server-goal-1', 'p_client_request_id': 'gc-1',
        'p_local_id': 'gc-1', 'p_amount': '25.00', 'p_created_at': _created, 'p_note': null});
    case _Lane.payment:
      expect(request.url.path, '/rest/v1/rpc/record_bill_payment');
      expect(body, {'p_subscription_id': 'server-bill-1', 'p_transaction_id': 'server-tx-1',
        'p_client_request_id': 'bp-1', 'p_local_id': 'bp-1', 'p_amount': '10.00', 'p_currency': 'EGP',
        'p_period_start': '2026-10-01T00:00:00.000Z', 'p_period_end': '2026-10-31T00:00:00.000Z',
        'p_paid_at': _created, 'p_installment_index': null, 'p_note': null});
    case _Lane.link:
      expect(request.url.path, '/rest/v1/user_plan_transaction_links');
      expect(body, {'user_id': _uid, 'plan_id': 'server-plan-1', 'transaction_id': 'server-tx-1',
        'client_request_id': 'plan-1:tx-1', 'created_at': _created});
  }
}

Map<String, dynamic> _goalReceipt(Map<String, dynamic> body) => {
  'contribution': {'id': 'server-gc-1', 'local_id': body['p_local_id'],
    'goal_id': body['p_goal_id'], 'amount_text': '25.00', 'currency': 'EGP',
    'created_at': body['p_created_at'], 'note': null, 'updated_at': _updated, 'deleted_at': null},
  'goal': {'id': body['p_goal_id'], 'currency': 'EGP', 'saved_amount_text': '25.00', 'updated_at': _updated},
};
Map<String, dynamic> _paymentReceipt(Map<String, dynamic> body) => {
  'payment': {'id': 'server-bp-1', 'local_id': body['p_local_id'],
    'subscription_id': body['p_subscription_id'], 'transaction_id': body['p_transaction_id'],
    'amount_text': '10.00', 'currency': 'EGP', 'period_start': body['p_period_start'],
    'period_end': body['p_period_end'], 'paid_at': body['p_paid_at'], 'created_at': _created,
    'updated_at': _updated, 'deleted_at': null, 'installment_index': null, 'note': null},
  'subscription': {'id': body['p_subscription_id'], 'paid_count': 1,
    'manual_paid_amount_text': '0.00', 'currency': 'EGP', 'updated_at': _updated},
};

Future<void> _seedParents(AppDatabase db) async {
  await db.customStatement("INSERT INTO merchants(id,raw_name,normalized_name,first_seen_at,last_seen_at) VALUES ('merchant-1','Synthetic','synthetic','$_created','$_created');");
  await db.customStatement("INSERT INTO goals(id,name,target_amount,saved_amount,currency,target_amount_minor,saved_amount_minor,last_notified_saved_amount_minor,vault_skin,status,created_at,server_id,sync_status) VALUES ('goal-1','Synthetic goal',100,0,'EGP',10000,0,0,'classic','active','$_created','server-goal-1','synced');");
  await db.customStatement("INSERT INTO subscriptions(id,merchant_id,amount,period,next_due_date,is_confirmed,reminder_on,name,type,currency,frequency,created_at,status,server_id,sync_status,paid_count,manual_paid_amount,manual_paid_amount_minor) VALUES ('bill-1','merchant-1',10,'monthly','$_created',1,1,'Synthetic subscription','subscription','EGP','monthly','$_created','active','server-bill-1','synced',0,5,500);");
  await db.customStatement("INSERT INTO plans(id,name,budget_amount,currency,start_date,end_date,account_ids,card_last4s,status,created_at,server_id,sync_status) VALUES ('plan-1','Synthetic plan',1000,'EGP','$_created','2026-11-01T00:00:00Z','','','active','$_created','server-plan-1','synced');");
  for (final id in ['tx-1', 'tx-2']) {
    await db.customStatement("INSERT INTO transactions(id,amount,currency,type,source,occurred_at,raw_message,parse_confidence,status,created_at,updated_at,server_id,sync_status) VALUES ('$id',10,'EGP','payment','manual','$_created','',1,'confirmed','$_created','$_created','server-$id','synced');");
  }
  await backfillNonPlanningMoneyV30(db);
}
Future<void> _seedIntent(AppDatabase db, PlanningOutboxQueue queue, _Lane lane) async {
  switch (lane) {
    case _Lane.goal:
      await db.customStatement("INSERT INTO goal_contributions(id,goal_id,amount,amount_minor,created_at) VALUES ('gc-1','goal-1',25,2500,'$_created');");
      await queue.enqueueGoalContribution(PlanningSyncOperation.create, GoalContributionEntity(
          id: 'gc-1', goalId: 'goal-1', amountMoney: Money.parse('25', 'EGP'), createdAt: DateTime.parse(_created)));
    case _Lane.payment: await _seedPayment(db, queue);
    case _Lane.link: await _seedLink(db, queue);
  }
}
Future<void> _seedPayment(AppDatabase db, PlanningOutboxQueue queue) async {
  await db.customStatement("INSERT INTO bill_payments(id,bill_id,amount,amount_minor,currency,period_start,period_end,paid_at,transaction_id) VALUES ('bp-1','bill-1',10,1000,'EGP','2026-10-01','2026-10-31','$_created','tx-1');");
  await queue.enqueueBillPayment(PlanningSyncOperation.create, BillPaymentEntity(id: 'bp-1',
      billId: 'bill-1', amountMoney: Money.parse('10', 'EGP'), currency: 'EGP',
      periodStart: DateTime.utc(2026, 10, 1), periodEnd: DateTime.utc(2026, 10, 31),
      paidAt: DateTime.parse(_created), transactionId: 'tx-1'));
}
Future<void> _seedLink(AppDatabase db, PlanningOutboxQueue queue, {String transaction = 'tx-1'}) async {
  await db.customStatement("INSERT INTO plan_transaction_links(plan_id,transaction_id,created_at) VALUES ('plan-1','$transaction','$_created');");
  await queue.enqueuePlanLink(PlanningSyncOperation.create, planId: 'plan-1',
      transactionId: transaction, createdAt: DateTime.parse(_created));
}

class _MemorySdkStorage extends GotrueAsyncStorage {
  const _MemorySdkStorage();
  @override
  Future<String?> getItem({required String key}) async => null;
  @override
  Future<void> setItem({required String key, required String value}) async {}
  @override
  Future<void> removeItem({required String key}) async {}
}

Future<ChildDeliveryStopped> _childStop(Future<void> work)async{
  try{await work;throw StateError('expected child stop');}on ChildDeliveryStopped catch(error){return error;}
}
class _ChildHarness {
  _ChildHarness(this.admission,this.lane);
  final LedgerAdmissionFixture admission;
  final _Lane lane;
  AppDatabase get db=>admission.database;
  PlanningOutboxQueue get queue=>PlanningOutboxQueue(db:db,isSyncEnabled:(_)=>true,getAuthUserId:()async=>_uid,getOwnerUid:admission.fixture.session.readLocalDataOwnerUid,coordinator:_canonical);
  final requests=<http.Request>[];
  final releases=<Completer<void>>[];
  final producers=<Future<Object?>>[];
  Future<http.Response> Function(http.Request)? custom;
  Future<http.Response> Function(http.Request) get respond=>custom??success;
  set respond(Future<http.Response>Function(http.Request) value)=>custom=value;
  Completer<void> release(){final c=Completer<void>();releases.add(c);return c;}
  Future<T> track<T>(Future<T> work){producers.add(work);return work;}
  Future<http.Response> success(http.Request r)async{
    if(r.method=='GET')return _reply(r,r.url.queryParameters.containsKey('plan_id')?null:[]);
    final body=(jsonDecode(r.body)as Map).cast<String,dynamic>();
    if(r.url.path.endsWith('add_goal_contribution'))return _reply(r,_goalReceipt(body));
    if(r.url.path.endsWith('record_bill_payment'))return _reply(r,_paymentReceipt(body));
    return _reply(r,{...body,'id':'server-link-1','updated_at':_updated,'deleted_at':null});
  }
  PlanningChildSyncService service({PlanningChildRemote? remote,RevisionCasGate? gate,SyncHealth? health,AccountFenceRetry? retry})=>PlanningChildSyncService(db:db,queue:queue,isEnabled:(_)=>true,isPullEnabled:(_)=>true,getAuthUserId:()async=>_uid,mayEgress:()async=>true,remote:remote,casGate:gate,health:health,fenceRetry:retry,coordinator:_canonical,pushCapability:()=>ExactTransportCapability.verifiedExact,pullCapability:()=>ExactTransportCapability.verifiedExact);
}
class _SynchronousRawChild implements PlanningChildRemote {
  @override
  Future<Map<String,dynamic>> callRpc(String name,Map<String,dynamic> params)=>throw const PostgrestException(message:'unproven custom',code:'QD001');
  @override
  dynamic noSuchMethod(Invocation i)=>throw StateError('unexpected custom method');
}
class _ChildHead implements SeqRemote {
  _ChildHead(this.read);final Future<SyncHead?>Function() read;
  @override
  Future<SyncHead?> fetchHead(String uid)=>read();
  @override
  dynamic noSuchMethod(Invocation i)=>throw StateError('unexpected seq method');
}
class _RestrictedChildPhase implements SyncPhaseLifecycle {
  _RestrictedChildPhase(this.a,this.handle,this.database);final AccountFenceAuthority a;final AccountFenceHandle handle;
  @override
  final AppDatabase database;
  bool enabled=true;
  @override
  bool get isCurrent=>enabled&&a.isCurrentForDatabase(handle,database);
  @override
  Future<T> runLocal<T>(Future<T>Function() work)=>a.runCurrentLocal(handle,database,work);
}

// Track only real outer transaction terminal settlement; nested ACKs are not enough.
class _ChildCommitProbe extends LedgerDatabaseProbe {
  void Function()? onOuterTerminal;
  @override
  TransactionExecutor beginTransaction()=>_ChildCommitTransaction(super.beginTransaction(),()=>onOuterTerminal?.call(),true);
}
class _ChildCommitTransaction extends TransactionExecutor {
  _ChildCommitTransaction(this.delegate,this.terminal,this.outer);
  final TransactionExecutor delegate;final void Function() terminal;final bool outer;
  @override
  bool get supportsNestedTransactions=>delegate.supportsNestedTransactions;
  @override
  SqlDialect get dialect=>delegate.dialect;
  @override
  Future<bool> ensureOpen(QueryExecutorUser user)=>delegate.ensureOpen(user);
  @override
  Future<List<Map<String,Object?>>> runSelect(String sql,List<Object?> args)=>delegate.runSelect(sql,args);
  @override
  Future<int> runInsert(String sql,List<Object?> args)=>delegate.runInsert(sql,args);
  @override
  Future<int> runUpdate(String sql,List<Object?> args)=>delegate.runUpdate(sql,args);
  @override
  Future<int> runDelete(String sql,List<Object?> args)=>delegate.runDelete(sql,args);
  @override
  Future<void> runCustom(String sql,[List<Object?>? args])=>delegate.runCustom(sql,args);
  @override
  Future<void> runBatched(BatchedStatements statements)=>delegate.runBatched(statements);
  @override
  TransactionExecutor beginTransaction()=>_ChildCommitTransaction(delegate.beginTransaction(),terminal,false);
  @override
  QueryExecutor beginExclusive()=>delegate.beginExclusive();
  @override
  Future<void> send()async{await delegate.send();if(outer)terminal();}
  @override
  Future<void> rollback()async{await delegate.rollback();if(outer)terminal();}
  @override
  Future<void> close()=>delegate.close();
}

class _ReadRefusalAfterConcreteMutation implements PlanningChildRemote {
  final concrete=const SupabasePlanningChildRemote();bool lookupReached=false;
  @override
  Future<Map<String,dynamic>> callRpc(String name,Map<String,dynamic> params)=>concrete.callRpc(name,params);
  @override
  Future<Map<String,dynamic>> upsertPlanLink(Map<String,dynamic> row)async{await findPlanLink(userId:row['user_id'] as String,planId:row['plan_id'] as String,transactionId:row['transaction_id'] as String);throw StateError('no mutation after read refusal');}
  @override
  Future<Map<String,dynamic>?> findPlanLink({required String userId,required String planId,required String transactionId})async{lookupReached=true;throw const PostgrestException(message:'custom unproven read refusal',code:'QD002');}
  @override
  dynamic noSuchMethod(Invocation i)=>throw StateError('unexpected custom read operation');
}
