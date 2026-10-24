import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'dart:async';
import 'package:money_companion/core/sync/account_fence_retry.dart';
import 'package:money_companion/core/sync/sync_health.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show Supabase, FlutterAuthClientOptions, EmptyLocalStorage, GotrueAsyncStorage;
import 'package:money_companion/core/session/account_fence_authority.dart';
import 'package:money_companion/core/session/account_fence_store.dart';
import 'package:money_companion/core/sync/outbox_failure.dart';
import '../capture/ledger_admission_fixture.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/features/gamification/services/engagement_event_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

// MALI-024 — server-authoritative, idempotent engagement events.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

/// Models the server RPC: awards per type, idempotent by event_id + business_key,
/// rejects unknown types / unsupported versions. Never accepts a client XP total.
class _FakeRecorder implements EngagementRemoteRecorder {
  int serverXp = 0;
  final Set<String> seenEvents = {};
  final Set<String> seenBusiness = {};
  int calls = 0;
  Object? failWith;

  @override
  Future<EngagementAck> record({
    required String eventId,
    required String eventType,
    required String occurredAt,
    String? businessKey,
    int eventVersion = 1,
  }) async {
    calls++;
    if (failWith != null) throw failWith!;
    if (eventVersion != 1) {
      throw const PostgrestException(message: 'unsupported version', code: '22023');
    }
    final award = kEngagementAward[eventType];
    if (award == null) {
      throw const PostgrestException(message: 'unknown type', code: '22023');
    }
    final dup =
        seenEvents.contains(eventId) || (businessKey != null && seenBusiness.contains(businessKey));
    if (!dup) {
      serverXp += award;
      seenEvents.add(eventId);
      if (businessKey != null) seenBusiness.add(businessKey);
    }
    return EngagementAck(
      xp: serverXp,
      level: 1 + serverXp ~/ 100,
      awarded: dup ? 0 : award,
    );
  }
}

void main() {
  _engagementMutationStageA();
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late _FakeRecorder recorder;
  late LedgerAdmissionFixture admission;

  EngagementEventService service() => EngagementEventService(
        mayEgress: () async => true,
        db: db,
        recorder: recorder,
        isSyncEnabled: () => true,
        getAuthUserId: () async => 'user-1',
      );

  Future<int> ackXp() async => (await db
          .customSelect('SELECT total_xp FROM xp_levels LIMIT 1;')
          .getSingle())
      .read<int>('total_xp');

  Future<int> countWhere(String where) async => (await db
          .customSelect('SELECT COUNT(*) AS n FROM engagement_events WHERE $where;')
          .getSingle())
      .read<int>('n');

  group('standalone offline engagement', () {
    setUp(() async {
      db = await AppDatabase.open(executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
      recorder = _FakeRecorder();
    });
    tearDown(() => db.close());
  test('offline event creation records a pending event without an award',
      () async {
    await service().enqueue(eventType: 'goal_contribution', eventId: 'e1');
    expect(await countWhere("status='pending'"), 1);
    // No server call happened, aggregate unchanged.
    expect(recorder.calls, 0);
  });

  test('offline progress is visible via projection (acknowledged + pending)',
      () async {
    await service().enqueue(eventType: 'goal_contribution', eventId: 'e1'); // 15
    await service().enqueue(eventType: 'bill_payment', eventId: 'e2'); // 5
    final p = await service().projection();
    expect(p.acknowledgedXp, 0);
    expect(p.pendingCount, 2);
    expect(p.projectedXp, 20, reason: 'acknowledged 0 + projected 15 + 5');
    expect(p.hasPending, isTrue);
  });

  test('a duplicate business action is dropped before it is even queued',
      () async {
    final s = service();
    await s.enqueue(
        eventType: 'goal_contribution', eventId: 'e1', businessKey: 'goal:42');
    await s.enqueue(
        eventType: 'goal_contribution', eventId: 'e2', businessKey: 'goal:42');
    expect(await countWhere('1=1'), 1, reason: 'same business_key → one event');
  });
  });
  group('admitted engagement push mechanisms', () {
    setUp(() async {
      admission = await LedgerAdmissionFixture.open();
      db = admission.database;
      recorder = _FakeRecorder();
    });
    tearDown(() => admission.finish());
  test('push submits events, the server awards, and the ack is mirrored locally',
      () async {
    await service().enqueue(eventType: 'goal_contribution', eventId: 'e1');
    final synced = await service().push();
    expect(synced, 1);
    expect(recorder.serverXp, 15);
    expect(await ackXp(), 15, reason: 'acknowledged server aggregate stored');
    expect(await countWhere("status='synced'"), 1);
    // Projection now equals acknowledged (nothing pending).
    final p = await service().projection();
    expect(p.projectedXp, 15);
    expect(p.pendingCount, 0);
  });

  test('duplicate event replay awards exactly once (idempotent)', () async {
    await service().enqueue(eventType: 'goal_contribution', eventId: 'e1');
    await service().push();
    // Re-enqueue the SAME event id (e.g. from another device / replay) and push.
    await service().enqueue(eventType: 'goal_contribution', eventId: 'e1');
    await service().push();
    expect(recorder.serverXp, 15, reason: 'the same event_id is awarded once');
    expect(await ackXp(), 15);
  });

  test('response lost after server acceptance: retry is idempotent', () async {
    await service().enqueue(eventType: 'goal_contribution', eventId: 'e1');
    // Simulate the server ACCEPTING + recording e1, but the client crashing
    // before it saw the ack — so e1 is still pending locally.
    await recorder.record(
        eventId: 'e1', eventType: 'goal_contribution', occurredAt: 'x');
    expect(recorder.serverXp, 15);
    expect(await countWhere("status='pending'"), 1);
    // The client retries the still-pending event; the server is idempotent, so
    // it does NOT double-award, and the client converges to the acknowledged 15.
    await service().push();
    expect(recorder.serverXp, 15, reason: 'awarded once despite the retry');
    expect(await ackXp(), 15);
    expect(await countWhere("status='synced'"), 1);
  });

  test('the projection removes a pending event exactly once after ack',
      () async {
    await service().enqueue(eventType: 'bill_payment', eventId: 'e1');
    expect((await service().projection()).pendingCount, 1);
    await service().push();
    final p = await service().projection();
    expect(p.pendingCount, 0, reason: 'acknowledged event leaves the projection');
    expect(p.projectedXp, p.acknowledgedXp, reason: 'no double count');
  });

  test('an unknown/malformed event type dead-letters (never awards)', () async {
    await service().enqueue(eventType: 'totally_made_up', eventId: 'e1');
    final synced = await service().push();
    expect(synced, 0);
    expect(await countWhere("status='dead'"), 1);
    expect(recorder.serverXp, 0);
  });

  test('arbitrary XP tampering is impossible — the client submits a TYPE, and '
      'an unknown type is rejected server-side', () async {
    // There is no XP parameter on enqueue/record; the only lever is event_type,
    // and an unrecognised one is rejected (dead-lettered), never awarded.
    await service().enqueue(eventType: 'grant_me_1000000_xp', eventId: 'e1');
    await service().push();
    expect(await ackXp(), 0);
    expect(await countWhere("status='dead'"), 1);
  });

  test('a dead-letter does not block a subsequent valid event; re-arm restores it',
      () async {
    final s = service();
    await s.enqueue(eventType: 'bad_type', eventId: 'bad');
    await s.enqueue(eventType: 'bill_payment', eventId: 'good');
    await s.push();
    expect(await countWhere("status='dead'"), 1);
    expect(await countWhere("status='synced'"), 1, reason: 'valid one still syncs');
    expect(await ackXp(), 5);
    // Re-arm after a compatible upgrade restores the dead event for retry.
    final rearmed = await s.reArmDeadLetter();
    expect(rearmed, 1);
    expect(await countWhere("status='pending'"), 1);
  });

  test('a transient failure keeps the event pending, not dead', () async {
    final s = service();
    await s.enqueue(eventType: 'bill_payment', eventId: 'e1');
    recorder.failWith = const PostgrestException(message: 'net', code: '503');
    await s.push();
    expect(await countWhere("status='pending'"), 1);
    expect(await s.deadLetterCount(), 0);
  });
  });
}

// E4 current-API mutation witnesses. The explicit UUID does not qualify the
// pre-existing default enqueue ID format against any deployed server schema.
void _engagementMutationStageA() {
  const uid='engagement-owner';
  const eventId='550e8400-e29b-41d4-a716-446655440101';
  const businessKey='synthetic-goal:one';
  final occurredAt=DateTime.utc(2026,10,1);
  group('E4 engagement mutation StageA',() {
    late Future<http.Response> Function(http.Request) respond;
    var initialized=false;
    setUpAll(()async {
      await Supabase.initialize(url:'https://example.supabase.co',anonKey:'anon',
          authOptions:const FlutterAuthClientOptions(autoRefreshToken:false,
              detectSessionInUri:false,localStorage:EmptyLocalStorage(),
              pkceAsyncStorage:_EngagementSdkStorage()),
          httpClient:MockClient((request)=>respond(request)));
      initialized=true;
    });
    tearDownAll(()async {if(initialized)await Supabase.instance.dispose();});
    EngagementEventService service(AppDatabase db)=>EngagementEventService(db:db,
        isSyncEnabled:()=>true,getAuthUserId:()async=>uid,mayEgress:()async=>true);
    Future<Map<String,Object?>> row(AppDatabase db)async=>(await db.customSelect(
        "SELECT * FROM engagement_events WHERE event_id='$eventId';").getSingle()).data;
    Future<Map<String,Object?>> aggregate(AppDatabase db)async=>(await db.customSelect(
        'SELECT * FROM xp_levels LIMIT 1;').getSingle()).data;
    Future<void> seed(EngagementEventService sync)=>sync.enqueue(eventId:eventId,
        eventType:'goal_contribution',occurredAt:occurredAt,businessKey:businessKey);
    http.Response reply(http.Request request,Object body,[int status=200])=>
        http.Response(jsonEncode(body),status,headers:{'content-type':'application/json'},request:request);
    void witness(List<http.Request> requests,List<Object> responses,Object response) {
      expect(requests,hasLength(1));final request=requests.single;
      expect(request.method,'POST');expect(request.url.path,'/rest/v1/rpc/record_engagement_event');
      expect(request.url.queryParameters,isEmpty);
      expect(jsonDecode(request.body),{
        'p_event_id':eventId,'p_event_type':'goal_contribution',
        'p_occurred_at':occurredAt.toIso8601String(),
        'p_business_key':businessKey,'p_event_version':1,
      });
      expect(responses,[response]);
    }
    Future<Object?> outcome(Future<int> future) => future.then<Object?>((value)=>value,onError:(Object error)=>error);
    EngagementEventService custom(AppDatabase db,EngagementRemoteRecorder recorder) => EngagementEventService(
        db:db,recorder:recorder,isSyncEnabled:()=>true,getAuthUserId:()async=>uid,mayEgress:()async=>true);
    for(final changed in [false,true]) {
      test('engagement particular origin customRaw=$changed',()async {
        final admission=await LedgerAdmissionFixture.open(uid);final db=admission.database;
        Future<Object?>? producer;final requests=<http.Request>[];
        try {
          final sync=custom(db,_CallbackRecorder((id,type,occurred,key,version) {
            if(changed)throw const PostgrestException(message:'custom raw refusal',code:'QD002');
            return const SupabaseEngagementRecorder().record(eventId:id,eventType:type,
                occurredAt:occurred,businessKey:key,eventVersion:version+1);
          }));
          await seed(sync);final before=await row(db);final xp=await aggregate(db);
          respond=(request)async {requests.add(request);return reply(request,{'xp':15,'level':1});};
          producer=outcome(sync.push());final stopped=await producer;
          expect(stopped,isA<EngagementDeliveryStopped>());
          expect((stopped as EngagementDeliveryStopped).reason,changed?
              EngagementDeliveryStopReason.nonMutationRefusal:EngagementDeliveryStopReason.provenance);
          expect(requests,isEmpty);expect(await row(db),before);expect(await aggregate(db),xp);
          expect(admission.fixture.session.captureLocalWorkAuthority()!.isCurrent,isTrue);
          expect(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(uid)),isNull);
        }finally{try{if(producer!=null)await producer;}finally{await admission.finish();}}
      });
    }
    for(final exhaust in [false,true]) {
      test('engagement bounded contention exhaust=$exhaust has no durable cooldown',()async {
        final admission=await LedgerAdmissionFixture.open(uid);final db=admission.database;
        final requests=<http.Request>[];Future<Object?>? producer;
        try {
          final health=SyncHealth(db:db);final phase=SyncPhaseBinding();
          final sync=EngagementEventService(db:db,health:health,isSyncEnabled:()=>true,
              getAuthUserId:()async=>uid,mayEgress:()async=>true,
              fenceRetry:AccountFenceRetry(delay:(_)async{}));
          await seed(sync);final before=await row(db);final xp=await aggregate(db);
          respond=(request)async {requests.add(request);return exhaust||requests.length<3?
            reply(request,{'code':'55P03','message':'synthetic busy','details':null,'hint':null},400):
            reply(request,{'xp':15,'level':1,'awarded':15});};
          producer=health.runPhase(SyncDomain.engagement,SyncDirection.push,()=>sync.pushWithPhase(phase),
              binding:phase,rethrowErrors:true).then<Object?>((value)=>value,onError:(Object e)=>e);
          await producer;expect(requests,hasLength(3));
          expect(requests.map((r)=>r.body).toSet(),hasLength(1));
          final after=await row(db);expect(after['attempt_count'],0);
          expect(after['status'],exhaust?'pending':'synced');
          if(exhaust){expect(after,before);expect(await aggregate(db),xp);}
          final state=health.of(SyncDomain.engagement);
          expect(state.consecutiveFailures,exhaust?1:0);
          if(exhaust)expect(state.lastPushSuccessAt,isNull);
          expect(admission.fixture.session.captureLocalWorkAuthority()!.isCurrent,isTrue);
          expect(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(uid)),isNull);
        }finally{try{if(producer!=null)await producer;}finally{await admission.finish();}}
      });
    }
    test('engagement ACK never overwrites a changed attempt snapshot or aggregate',()async {
      final admission=await LedgerAdmissionFixture.open(uid);final db=admission.database;
      final reached=Completer<void>();final release=Completer<void>();Future<Object?>? producer;
      try {
        final sync=service(db);await seed(sync);final xp=await aggregate(db);
        respond=(request)async{reached.complete();await release.future;return reply(request,{'xp':15,'level':1});};
        producer=outcome(sync.push());await reached.future;
        await db.customStatement("UPDATE engagement_events SET attempt_count=1 WHERE event_id='$eventId';");
        final replacement=await row(db);release.complete();expect(await producer,0);
        expect(await row(db),replacement);expect(await aggregate(db),xp);
      }finally{try{if(!release.isCompleted)release.complete();if(producer!=null)await producer;}finally{await admission.finish();}}
    });
    test('engagement same UID successor rejects old success and overlap',()async {
      final admission=await LedgerAdmissionFixture.open(uid);final db=admission.database;
      final location=admission.location;final reached=Completer<void>();final release=Completer<void>();Future<Object?>? producer;
      try {
        final sync=service(db);await seed(sync);final before=await row(db);final xp=await aggregate(db);
        final old=admission.fixture.session.captureLocalWorkAuthority()!;
        respond=(request)async{reached.complete();await release.future;return reply(request,{'xp':15,'level':1});};
        producer=outcome(sync.push());await reached.future;
        final overlap=await outcome(sync.push());expect(overlap,isA<EngagementDeliveryStopped>());
        expect((overlap as EngagementDeliveryStopped).reason,EngagementDeliveryStopReason.overlap);
        await admission.fixture.signIn(uid);expect(old.isCurrent,isFalse);
        release.complete();final stopped=await producer;expect(stopped,isA<EngagementDeliveryStopped>());
        expect((stopped as EngagementDeliveryStopped).reason,EngagementDeliveryStopReason.stale);
        final retained=db.lifecycleState==DatabaseLifecycleState.closed?
            await LedgerAdmissionFixture.inspectClosed(db,location,(inspection)async=>(event:await row(inspection),xp:await aggregate(inspection))):
            (event:await row(db),xp:await aggregate(db));
        expect(retained.event,before);expect(retained.xp,xp);
        expect(admission.fixture.session.captureLocalWorkAuthority()!.isCurrent,isTrue);
      }finally{try{if(!release.isCompleted)release.complete();if(producer!=null)await producer;}finally{await admission.finish();}}
    });
    test('engagement concrete denial accepts while ordinary readiness is held',()async {
      final admission=await LedgerAdmissionFixture.open(uid);final db=admission.database;final location=admission.location;
      final reached=Completer<void>();final release=Completer<void>();Future<Object?>? producer;Future<bool>? loading;
      final storage=admission.fixture.storage;
      final retired=Completer<void>();
      void listener(){if(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(uid))!=null&&!retired.isCompleted)retired.complete();}
      admission.fixture.session.addListener(listener);
      void Function()? releaseStorage;
      try {
        final sync=service(db);await seed(sync);final before=await row(db);final xp=await aggregate(db);
        final cap=admission.fixture.session.captureLocalWorkAuthority()!;
        respond=(request)async{reached.complete();await release.future;
          return reply(request,{'code':'QD002','message':'synthetic refusal','details':null,'hint':null},400);};
        producer=outcome(sync.push());await reached.future;
        final storageHold=storage.holdOnce((op,key)=>op=='read'&&key==AccountFenceStore.storageKey);
        releaseStorage=(){if(!storageHold.release.isCompleted)storageHold.release.complete();};
        loading=AccountFenceAuthority.shared.initialize();await storageHold.reached.future;
        expect(cap.isCurrent,isFalse);release.complete();
        await retired.future;
        expect(AccountFenceAuthority.shared.store.ready,isFalse);
        expect(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(uid))!.state,AccountFenceState.gone);
        storageHold.release.complete();await loading;
        final stopped=await producer;expect(stopped,isA<EngagementDeliveryStopped>());
        expect((stopped as EngagementDeliveryStopped).accepted,isTrue);expect(stopped.complete,isTrue);
        final retained=await LedgerAdmissionFixture.inspectClosed(db,location,(inspection)async=>(event:await row(inspection),xp:await aggregate(inspection)));
        expect(retained.event,before);expect(retained.xp,xp);
      }finally{try{if(!release.isCompleted)release.complete();releaseStorage?.call();
        if(loading!=null)await loading;if(producer!=null)await producer;}finally{
          admission.fixture.session.removeListener(listener);await admission.finish();}}
    });
    test('engagement actual provider refuses an unbound DB before SDK or bookkeeping',()async {
      final admission=await LedgerAdmissionFixture.open(uid);final db=admission.database;
      ProviderContainer? container;final requests=<http.Request>[];
      try {
        await seed(service(db));final before=await row(db);final xp=await aggregate(db);
        admission.fixture.session.configureAccountScope(null);
        container=ProviderContainer(overrides:[appDatabaseProvider.overrideWithValue(db),
            syncHealthProvider.overrideWithValue(SyncHealth(db:db))]);
        respond=(request)async{requests.add(request);return reply(request,{'xp':15,'level':1});};
        final stopped=await outcome(container.read(engagementEventServiceProvider).push());
        expect(stopped,isA<EngagementDeliveryStopped>());
        expect((stopped as EngagementDeliveryStopped).reason,EngagementDeliveryStopReason.unbound);
        expect(requests,isEmpty);expect(await row(db),before);expect(await aggregate(db),xp);
        expect(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(uid)),isNull);
      }finally{container?.dispose();await admission.finish();}
    });
    test('engagement started atomic ACK and XP transaction drains before close',()async {
      final probe=LedgerDatabaseProbe();final admission=await LedgerAdmissionFixture.open(uid,probe);
      final db=admission.database;final location=admission.location;
      final reached=Completer<void>();final release=Completer<void>();var terminal=false;var earlyClose=false;
      Future<Object?>? producer;Future<AccountFenceResult>? accepting;
      try {
        final sync=service(db);await seed(sync);
        final authority=AccountFenceAuthority.shared;
        final handle=(await authority.capture(admission.fixture.session,admission.fixture.host))!;
        probe.before=(sql)async{if(sql.startsWith('UPDATE xp_levels SET')){reached.complete();await release.future;}};
        probe.afterTransactionSend=(){if(reached.isCompleted)terminal=true;};
        probe.onClose=(){if(!terminal)earlyClose=true;};
        respond=(request)async=>reply(request,{'xp':15,'level':1});
        producer=outcome(sync.push());await reached.future;
        accepting=authority.accept(handle,AccountFenceState.pending,operationId:'550e8400-e29b-41d4-a716-446655440299');
        expect(probe.closeAttempts,0);expect(terminal,isFalse);
        release.complete();await producer;expect((await accepting).complete,isTrue);
        expect(terminal,isTrue);expect(earlyClose,isFalse);
        final retained=await LedgerAdmissionFixture.inspectClosed(db,location,(inspection)async=>(event:await row(inspection),xp:await aggregate(inspection)));
        expect(retained.event['status'],'synced');expect(retained.xp['total_xp'],15);
      }finally{try{if(!release.isCompleted)release.complete();if(producer!=null)await producer;if(accepting!=null)await accepting;}finally{await admission.finish();}}
    });
    for(final code in ['QD001','QD002']) {
      test('$code actual event RPC retires original authority',()async {
        final admission=await LedgerAdmissionFixture.open(uid);final db=admission.database;
        final location=admission.location;final requests=<http.Request>[];final responses=<Object>[];
        Future<int>? producer;
        try {
          final sync=service(db);await seed(sync);
          final before=await row(db);final xpBefore=await aggregate(db);
          final cap=admission.fixture.session.captureLocalWorkAuthority()!;expect(cap.isCurrent,isTrue);
          final raw=<String,Object?>{'code':code,'message':'synthetic event refusal','details':null,'hint':null};
          respond=(request)async {requests.add(request);responses.add(raw);return reply(request,raw,400);};
          producer=sync.push();
          final stopped=await producer.then<Object?>((_)=>null,onError:(Object e)=>e);
          expect(stopped,isA<EngagementDeliveryStopped>());
          expect((stopped as EngagementDeliveryStopped).reason,EngagementDeliveryStopReason.denial);
          expect(stopped.accepted,isTrue);expect(stopped.complete,isTrue);
          witness(requests,responses,raw);
          // Primary behavior RED; later preservation checks are not counted as
          // reached when the original capability incorrectly remains current.
          expect(cap.isCurrent,isFalse,reason:'the current-owner event mutation refusal retires authority');
          expect(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(uid))!.state,
              code=='QD001'?AccountFenceState.pending:AccountFenceState.gone);
          final retained=await LedgerAdmissionFixture.inspectClosed(db,location,(inspection)async=>
              (event:await row(inspection),xp:await aggregate(inspection)));
          expect(retained.event,before);expect(retained.event['status'],'pending');
          expect(retained.event['attempt_count'],0);expect(retained.xp,xpBefore);
        }finally {
          try{if(producer!=null){await producer.onError((Object error,StackTrace stack){
            if(error is EngagementDeliveryStopped&&error.reason==EngagementDeliveryStopReason.denial){return 0;}
            Error.throwWithStackTrace(error,stack);
          });}}finally{await admission.finish();}
        }
      });
    }
    test('matched actual event RPC ACK updates event and acknowledged aggregate',()async {
      final admission=await LedgerAdmissionFixture.open(uid);final db=admission.database;
      final requests=<http.Request>[];final responses=<Object>[];Future<int>? producer;
      try {
        final sync=service(db);await seed(sync);final before=await row(db);
        final ack=<String,Object?>{'xp':15,'level':1,'awarded':15,'current_streak':0};
        respond=(request)async{requests.add(request);responses.add(ack);return reply(request,ack);};
        producer=sync.push();expect(await producer,1);witness(requests,responses,ack);
        final after=await row(db);expect(after['status'],'synced');expect(after['synced_at'],isNotNull);
        for(final key in ['event_id','event_type','occurred_at','business_key','event_version','created_at']) {
          expect(after[key],before[key]);
        }
        expect(after['attempt_count'],0);
        final xp=await aggregate(db);expect(xp['total_xp'],15);expect(xp['level'],1);
        final projection=await sync.projection();expect(projection.pendingCount,0);
        expect(projection.acknowledgedXp,15);expect(projection.projectedXp,projection.acknowledgedXp);
        expect(admission.fixture.session.captureLocalWorkAuthority()!.isCurrent,isTrue);
        expect(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(uid)),isNull);
      }finally{try{if(producer!=null)await producer;}finally{await admission.finish();}}
    });
    test('ordinary actual event RPC failure retains retry policy without retirement',()async {
      final admission=await LedgerAdmissionFixture.open(uid);final db=admission.database;
      final requests=<http.Request>[];final responses=<Object>[];Future<int>? producer;
      try {
        final sync=service(db);await seed(sync);final before=await row(db);final xpBefore=await aggregate(db);
        final raw=<String,Object?>{'code':'503','message':'synthetic ordinary error','details':null,'hint':null};
        respond=(request)async{requests.add(request);responses.add(raw);return reply(request,raw,503);};
        producer=sync.push();expect(await producer,0);witness(requests,responses,raw);
        final after=await row(db);expect(after['status'],'pending');expect(after['attempt_count'],1);
        expect(after['failure_class'],'serverError');expect(after['synced_at'],isNull);
        for(final key in ['event_id','event_type','occurred_at','business_key','event_version','created_at']) {
          expect(after[key],before[key]);
        }
        expect(await aggregate(db),xpBefore);
        expect(admission.fixture.session.captureLocalWorkAuthority()!.isCurrent,isTrue);
        expect(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(uid)),isNull);
      }finally{try{if(producer!=null)await producer;}finally{await admission.finish();}}
    });
  });
}
class _EngagementSdkStorage extends GotrueAsyncStorage {
  const _EngagementSdkStorage();
  @override
  Future<String?> getItem({required String key})async=>null;
  @override
  Future<void> setItem({required String key,required String value})async{}
  @override
  Future<void> removeItem({required String key})async{}
}

class _CallbackRecorder implements EngagementRemoteRecorder {
  _CallbackRecorder(this.body);
  final Future<EngagementAck> Function(String,String,String,String?,int) body;
  @override
  Future<EngagementAck> record({required String eventId,required String eventType,
      required String occurredAt,String? businessKey,int eventVersion=1}) =>
      body(eventId,eventType,occurredAt,businessKey,eventVersion);
}
