import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:money_companion/core/session/account_fence_authority.dart';
import 'package:money_companion/core/sync/outbox_failure.dart';
import 'package:money_companion/core/sync/account_fence_retry.dart';
import 'package:money_companion/core/sync/sync_health.dart';
import 'package:money_companion/core/session/account_fence_store.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'ledger_admission_fixture.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/repositories/drift_smart_inbox_repository.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/features/capture/services/smart_inbox_sync_service.dart';

/// A-4 (G11): a zero-row server update is a failure with backoff (never an
/// ACK); local-only items never reach the server and never stay pending_sync.
class _Remote implements SmartInboxRemoteSource {
  int matched = 1;
  final calls = <String>[];

  @override
  Future<List<Map<String, dynamic>>> fetchRows(
          {required SyncCursor after, int limit = 200}) async =>
      const [];

  @override
  Future<int> pushStatus(String serverId, String status) async {
    calls.add(serverId);
    return matched;
  }
}

void main() {
  _smartInboxStatusStageA();
  group('G11 status mechanics', () {
  late LedgerAdmissionFixture admission;
  late AppDatabase db;
  late _Remote remote;

  setUp(() async {
    admission = await LedgerAdmissionFixture.open('user-1');
    db = admission.database;
    remote = _Remote();
  });
  tearDown(() async => admission.finish());

  SmartInboxSyncService svc() => SmartInboxSyncService(
        db: db,
        isPullEnabled: () => true,
        getAuthUserId: () async => 'user-1',
        remoteSource: remote,
        mayEgress: () async => true,
      );

  Future<void> serverItem(String id) => db.customStatement('''
    INSERT INTO smart_inbox_items(id, server_id, type, title, status,
      server_created_at, synced_at, created_at, updated_at, pending_sync)
    VALUES ('$id', '$id', 'needs_review', 't', 'open',
      '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z',
      '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 0);
  ''');

  Future<Map<String, Object?>> item(String id) async => (await db
          .customSelect("SELECT * FROM smart_inbox_items WHERE id = '$id';")
          .getSingle())
      .data;

  test('zero matched rows is a failure with backoff, not success', () async {
    await serverItem('srv-1');
    await DriftSmartInboxRepository(db).dismiss('srv-1');
    remote.matched = 0;

    final pushed = await svc().push();

    expect(pushed, 0);
    final r = await item('srv-1');
    expect(r['pending_sync'], 1);
    expect(r['push_attempt_count'], 1);
    expect(r['push_next_retry_at'], isNotNull);

    remote.calls.clear();
    await svc().push();
    expect(remote.calls, isEmpty, reason: 'backoff has not elapsed');
  });

  test('a returned row ACKs and clears the retry state', () async {
    await serverItem('srv-1');
    await DriftSmartInboxRepository(db).dismiss('srv-1');
    await db.customStatement(
        "UPDATE smart_inbox_items SET push_attempt_count = 3, "
        "push_next_retry_at = '2020-01-01T00:00:00Z';");

    expect(await svc().push(), 1);
    final r = await item('srv-1');
    expect(r['pending_sync'], 0);
    expect(r['push_attempt_count'], 0);
    expect(r['push_next_retry_at'], isNull);
  });

  test('a local-only item never calls the server and is not left pending',
      () async {
    final repo = DriftSmartInboxRepository(db);
    final id = await repo.saveUnprocessableCapture(
        payloadId: 'p1', rawMessage: 'x', source: 'sms');
    await repo.dismiss(id);

    expect((await item(id))['pending_sync'], 0);
    await svc().push();
    expect(remote.calls, isEmpty);
    expect((await item(id))['status'], 'dismissed');
  });

  test('a legacy local-only row already stuck at pending_sync=1 is settled '
      'without a server call', () async {
    final repo = DriftSmartInboxRepository(db);
    final id = await repo.saveUnprocessableCapture(
        payloadId: 'p2', rawMessage: 'x', source: 'sms');
    await db.customStatement(
        "UPDATE smart_inbox_items SET status = 'dismissed', pending_sync = 1 "
        "WHERE id = '$id';");

    await svc().push();

    expect(remote.calls, isEmpty);
    expect((await item(id))['pending_sync'], 0);
  });
  });
}


// Actual SDK status PATCH witnesses; this is not AppShell orchestration coverage.
void _smartInboxStatusStageA() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const uid='smart-inbox-owner';
  const serverId='00000000-0000-0000-0000-000000000123';
  group('E4 SmartInbox status StageA',(){
    late Future<http.Response> Function(http.Request) respond;
    var initialized=false;
    setUpAll(()async{
      await Supabase.initialize(url:'https://example.supabase.co',anonKey:'anon',
          authOptions:const FlutterAuthClientOptions(autoRefreshToken:false,
              detectSessionInUri:false,localStorage:EmptyLocalStorage(),
              pkceAsyncStorage:_SmartInboxSdkStorage()),
          httpClient:MockClient((request)=>respond(request)));
      initialized=true;
    });
    tearDownAll(()async{if(initialized)await Supabase.instance.dispose();});
    Future<Map<String,Object?>> row(AppDatabase db)async=>(await db.customSelect(
        "SELECT * FROM smart_inbox_items WHERE server_id='$serverId';").getSingle()).data;
    Future<void> seed(AppDatabase db)async{
      await db.customStatement("INSERT INTO smart_inbox_items(id,server_id,type,title,status,server_created_at,synced_at,created_at,updated_at,pending_sync) VALUES ('local-inbox','$serverId','needs_review','Synthetic status','open','2026-10-01T00:00:00Z','2026-10-01T00:00:00Z','2026-10-01T00:00:00Z','2026-10-01T00:00:00Z',0);");
      await DriftSmartInboxRepository(db).dismiss(serverId);
    }
    SmartInboxSyncService service(AppDatabase db,{AccountFenceRetry? retry,SyncHealth? health})=>SmartInboxSyncService(db:db,fenceRetry:retry,health:health,
        isPullEnabled:()=>true,getAuthUserId:()async=>uid,mayEgress:()async=>true);
    http.Response reply(http.Request request,Object body,[int status=200])=>
        http.Response(jsonEncode(body),status,headers:{'content-type':'application/json'},request:request);
    void mutationWitness(List<http.Request> requests,List<Object> bodies,Object expected){
      expect(requests,hasLength(1));final request=requests.single;
      expect(request.method,'PATCH');expect(request.url.path,'/rest/v1/user_smart_inbox');
      expect(request.url.queryParameters,{'id':'eq.$serverId','select':'id'});
      expect(jsonDecode(request.body),{'status':'dismissed'});expect(bodies,[expected]);
    }
    for(final code in ['QD001','QD002']){
      test('$code actual status PATCH retires original authority',()async{
        final admission=await LedgerAdmissionFixture.open(uid);final db=admission.database;
        final location=admission.location;
        final requests=<http.Request>[];final responses=<Object>[];Future<int>? producer;
        try{
          await seed(db);final before=await row(db);
          final cap=admission.fixture.session.captureLocalWorkAuthority()!;expect(cap.isCurrent,isTrue);
          final raw=<String,Object?>{'code':code,'message':'synthetic mutation refusal','details':null,'hint':null};
          respond=(request)async{requests.add(request);responses.add(raw);return reply(request,raw,400);};
          SmartInboxDeliveryStopped? stopped;
          producer=() async {
            try { return await service(db).push(); }
            on SmartInboxDeliveryStopped catch (error) { stopped=error; return 0; }
          }();
          await producer;
          mutationWitness(requests,responses,raw);
          expect(stopped?.reason,SmartInboxDeliveryStopReason.denial);
          expect(stopped?.accepted,isTrue);expect(stopped?.complete,isTrue);
          // Primary current-API RED. The later state assertions are not counted
          // as observed if current authority incorrectly survives this refusal.
          expect(cap.isCurrent,isFalse,reason:'the observed current-owner status mutation refusal must retire original authority');
          final state=code=='QD001'?AccountFenceState.pending:AccountFenceState.gone;
          expect(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(uid))!.state,state);
          final retained=await LedgerAdmissionFixture.inspectClosed(db,location,row);
          expect(retained,before);expect(retained['push_attempt_count'],0);
        }finally{
          try{if(producer!=null)await producer;}finally{await admission.finish();}
        }
      });
    }
    test('matched status response ACKs and explicit positive pull reaches GET',()async{
      final admission=await LedgerAdmissionFixture.open(uid);final db=admission.database;
      final requests=<http.Request>[];final responses=<Object>[];
      try{
        await seed(db);final ack=<Object>[{'id':serverId}];
        respond=(request)async{requests.add(request);final body=request.method=='PATCH'?ack:<Object>[];responses.add(body);return reply(request,body);};
        final sync=service(db);expect(await sync.push(),1);
        mutationWitness(requests,responses,ack);
        final after=await row(db);expect(after['status'],'dismissed');expect(after['pending_sync'],0);
        expect(after['push_attempt_count'],0);expect(after['push_next_retry_at'],isNull);
        expect(admission.fixture.session.captureLocalWorkAuthority()!.isCurrent,isTrue);
        expect((await sync.pull()).status,SyncPullStatus.completed);
        expect(requests.map((r)=>r.method),['PATCH','GET']);
        expect(requests.last.url.path,'/rest/v1/user_smart_inbox');expect(responses.last,isEmpty);
      }finally{await admission.finish();}
    });
    test('delegated concrete mutation cannot replace the captured target or status', () async {
      final admission=await LedgerAdmissionFixture.open(uid);final db=admission.database;
      var requests=0;
      try {
        await seed(db);final before=await row(db);
        respond=(request)async{requests++;return reply(request,[]);};
        final sync=SmartInboxSyncService(db:db,isPullEnabled:()=>true,
            getAuthUserId:()async=>uid,mayEgress:()async=>true,
            remoteSource:_MismatchedInboxSource());
        await expectLater(sync.push(),throwsA(isA<SmartInboxDeliveryStopped>()
            .having((e)=>e.reason,'reason',SmartInboxDeliveryStopReason.provenance)));
        expect(requests,0);expect(await row(db),before);
        expect(admission.fixture.session.captureLocalWorkAuthority()!.isCurrent,isTrue);
        expect(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(uid)),isNull);
      }finally{await admission.finish();}
    });

    for (final exhausted in [false,true]) {
      test('bounded actual status PATCH contention exhausted=$exhausted', () async {
        final admission=await LedgerAdmissionFixture.open(uid);final db=admission.database;
        final requests=<http.Request>[];var delays=0;
        try {
          await seed(db);
          final before=await row(db);
          respond=(request) async {
            requests.add(request);
            if (exhausted || requests.length==1) {
              return reply(request,{'code':'55P03','message':'busy','details':null,'hint':null},400);
            }
            return reply(request,[{'id':serverId}]);
          };
          final retry=AccountFenceRetry(delay: (_) async {delays++;});
          final health=SyncHealth(db:db);final phase=SyncPhaseBinding();
          expect(await health.runPhase(SyncDomain.smartInbox,SyncDirection.push,
              ()=>service(db,retry:retry,health:health).pushWithPhase(phase),
              binding:phase,rethrowErrors:true),exhausted?0:1);
          if(exhausted) {
            expect(health.of(SyncDomain.smartInbox).consecutiveFailures,1);
            expect(health.of(SyncDomain.smartInbox).lastPushSuccessAt,isNull);
          }
          expect(requests,hasLength(exhausted?3:2));expect(delays,exhausted?2:1);
          expect(requests.map((r)=>r.body).toSet(),{jsonEncode({'status':'dismissed'})});
          expect(requests.map((r)=>r.url).toSet(),hasLength(1));
          expect(identical(requests.first,requests.last),isFalse);
          final after=await row(db);
          expect(after['updated_at'],before['updated_at']);expect(after['push_attempt_count'],0);
          expect(after['pending_sync'],exhausted?1:0);
          if(exhausted) { expect(after['push_next_retry_at'],isNotNull); }
          expect(admission.fixture.session.captureLocalWorkAuthority()!.isCurrent,isTrue);
          expect(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(uid)),isNull);
        } finally { await admission.finish(); }
      });
    }
    test('same UID successor prevents an old status ACK and overlap is refused',()async{
      final admission=await LedgerAdmissionFixture.open(uid);final db=admission.database;
      final requests=<http.Request>[];final reached=Completer<void>();final release=Completer<void>();
      Future<int>? producer;
      try {
        await seed(db);final before=await row(db);final cap=AppSession.instance.captureLocalWorkAuthority()!;
        respond=(request)async{requests.add(request);reached.complete();await release.future;
          return reply(request,[{'id':serverId}]);};
        final sync=service(db);
        producer=()async{
          try{return await sync.push();}
          on SmartInboxDeliveryStopped catch(error){expect(error.reason,SmartInboxDeliveryStopReason.stale);return 0;}
        }();
        expect(await Future.any([reached.future.then((_)=>true),producer.then((_)=>false)]),isTrue);
        await expectLater(sync.push(),throwsA(isA<SmartInboxDeliveryStopped>()
            .having((e)=>e.reason,'reason',SmartInboxDeliveryStopReason.overlap)));
        await admission.fixture.signIn(uid);
        expect(cap.isCurrent,isFalse);expect(AppSession.instance.captureLocalWorkAuthority()!.isCurrent,isTrue);
        release.complete();expect(await producer,0);expect(requests,hasLength(1));
        expect(await row(db),before);
        expect(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(uid)),isNull);
      }finally{
        if(!release.isCompleted)release.complete();
        try{if(producer!=null)await producer;}finally{await admission.finish();}
      }
    });

    test('started exact ACK transaction settles before physical closure',()async{
      final probe=LedgerDatabaseProbe();final admission=await LedgerAdmissionFixture.open(uid,probe);
      final db=admission.database;final reached=Completer<void>();final release=Completer<void>();
      var terminal=false;var earlyClose=false;var requests=0;
      Future<int>? producer;Future<AccountFenceResult>? accepting;
      try {
        await seed(db);
        final handle=(await AccountFenceAuthority.shared.captureForDatabase(AppSession.instance,db))!;
        probe.before=(sql)async {
          if(sql.startsWith('UPDATE smart_inbox_items SET pending_sync=0')) {
            reached.complete();await release.future;
          }
        };
        probe.afterTransactionSettled=(){terminal=true;};
        probe.onClose=(){if(!terminal)earlyClose=true;};
        respond=(request)async{requests++;return reply(request,[{'id':serverId}]);};
        producer=()async{
          try{return await service(db).push();}
          on SmartInboxDeliveryStopped catch(error){expect(error.reason,SmartInboxDeliveryStopReason.stale);return 0;}
        }();
        expect(await Future.any([reached.future.then((_)=>true),producer.then((_)=>false)]),isTrue);
        terminal=false;
        accepting=AccountFenceAuthority.shared.accept(handle,AccountFenceState.pending,
            operationId:'550e8400-e29b-41d4-a716-446655440099');
        expect(probe.closeAttempts,0);expect(release.isCompleted,isFalse);
        release.complete();await producer;
        expect((await accepting).complete,isTrue);expect(terminal,isTrue);expect(earlyClose,isFalse);
        expect(requests,1);expect(db.lifecycleState,DatabaseLifecycleState.closed);
      }finally{
        if(!release.isCompleted)release.complete();
        try{if(producer!=null)await producer;if(accepting!=null)await accepting;}
        finally{probe.before=null;await admission.finish();}
      }
    });

    test('old ordinary failure cannot back off a newer committed edit',()async{
      final admission=await LedgerAdmissionFixture.open(uid);final db=admission.database;
      final reached=Completer<void>();final release=Completer<void>();Future<int>? producer;
      try {
        await seed(db);
        respond=(request)async{reached.complete();await release.future;
          return reply(request,{'code':'XX000','message':'ordinary','details':null,'hint':null},500);};
        producer=service(db).push();
        expect(await Future.any([reached.future.then((_)=>true),producer.then((_)=>false)]),isTrue);
        await DriftSmartInboxRepository(db).resolve(serverId);final newer=await row(db);
        release.complete();expect(await producer,0);expect(await row(db),newer);
      }finally{if(!release.isCompleted)release.complete();
        try{if(producer!=null)await producer;}finally{await admission.finish();}}
    });

    test('held old dismiss ACK cannot clear a committed newer resolve',()async{
      final admission=await LedgerAdmissionFixture.open(uid);final db=admission.database;
      final requests=<http.Request>[];final responses=<Object>[];
      final reached=Completer<void>();final release=Completer<void>();Future<int>? producer;
      try{
        await seed(db);final ack=<Object>[{'id':serverId}];
        respond=(request)async{requests.add(request);reached.complete();await release.future;responses.add(ack);return reply(request,ack);};
        producer=service(db).push();
        expect(await Future.any([reached.future.then((_)=>true),producer.then((_)=>false)]),isTrue);
        expect(requests.single.method,'PATCH');expect(jsonDecode(requests.single.body),{'status':'dismissed'});
        await DriftSmartInboxRepository(db).resolve(serverId);
        final newer=await row(db);expect(newer['status'],'resolved');expect(newer['pending_sync'],1);
        expect(newer['push_attempt_count'],0);expect(newer['push_next_retry_at'],isNull);
        release.complete();await producer;mutationWitness(requests,responses,ack);
        final after=await row(db);
        expect(after['pending_sync'],1,reason:'old response cannot acknowledge the committed newer edit');
        expect(after,newer);expect(admission.fixture.session.captureLocalWorkAuthority()!.isCurrent,isTrue);
      }finally{
        if(!release.isCompleted)release.complete();
        try{if(producer!=null)await producer;}finally{await admission.finish();}
      }
    });
  });
}
class _SmartInboxSdkStorage extends GotrueAsyncStorage {
  const _SmartInboxSdkStorage();
  @override
  Future<String?> getItem({required String key})async=>null;
  @override
  Future<void> setItem({required String key,required String value})async{}
  @override
  Future<void> removeItem({required String key})async{}
}

class _MismatchedInboxSource implements SmartInboxRemoteSource {
  @override
  Future<int> pushStatus(String serverId,String status) =>
      const SupabaseSmartInboxRemoteSource().pushStatus('$serverId-changed',status);
  @override
  Future<List<Map<String,dynamic>>> fetchRows({required SyncCursor after,int limit=200}) async => [];
}
