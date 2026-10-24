import 'package:money_companion/features/capture/services/notification_log_service.dart';
import 'package:money_companion/features/capture/services/notification_log_sync_service.dart';
import 'package:money_companion/data/sync/sender_bank_mapping_sync_service.dart';
import 'package:money_companion/data/repositories/drift_sender_bank_mapping_repository.dart';
import 'package:money_companion/domain/repositories/sender_bank_mapping_repository.dart';
import 'package:money_companion/features/planning_sync/services/planning_push_service.dart';
import 'package:money_companion/data/repositories/drift_category_repository.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import '../../features/capture/ledger_admission_fixture.dart';
import 'package:money_companion/features/planning_sync/services/accounts_push_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show QueryExecutor, QueryExecutorUser, SqlDialect, BatchedStatements, TransactionExecutor;
import 'package:drift/native.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:money_companion/core/sync/outbox_failure.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/features/capture/services/ledger_outbox_queue.dart';
import 'package:money_companion/features/capture/services/ledger_push_service.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/session/account_fence_authority.dart';
import 'package:money_companion/core/session/account_fence_store.dart';
import 'package:money_companion/core/session/account_scope.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/creation_policy.dart';
import 'package:money_companion/data/db/database_key_store.dart';

import 'f2_fixture.dart';

const _op = '550e8400-e29b-41d4-a716-446655440000';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late F2Fixture f;
  late void Function() restore;
  AccountFenceAuthority getAuthority() => AccountFenceAuthority.shared;
  setUp(() async {
    restore = AccountFenceAuthority.replacePersistenceForTest();
    f = await F2Fixture.create(afterWithdraw: () async {});
    f.session.configureAccountScope(f.host);
    await f.signIn('uid-a');
  });
  tearDown(() async {
    f.storage.gate = null;
    await f.dispose();
    restore();
  });

  Future<AccountFenceHandle> capture() async {
    final handle = await getAuthority().capture(f.session, f.host);
    expect(handle, isNotNull);
    return handle!;
  }

  test('E4 explicit switch rejects inherited active outer reservation after inner settled', () async {
    final db=f.host.current!.database;final scope=f.host.current;final cap=f.session.captureLocalWorkAuthority()!;
    final marker=f.storage.data[kMarkerKey];final generation=f.storage.data[kGenerationKey];
    final attempts=f.storage.attempts.length;final epoch=cap.epoch;
    final releaseOuter=Completer<void>();final inheritedDone=Completer<void>();
    Future<Object?>? transition;Future<void>? continuation;
    final outer=f.session.runAdmittedLocalOperation(cap,()async {
      await f.session.runAdmittedLocalOperation(cap,()async {
        // This continuation inherits BOTH reservations but runs after inner settles.
        continuation=()async {
          await inheritedDone.future;
          transition=f.session.setIdentity(method:'google',email:'uid-b@example.com',userId:'uid-b')
              .then<Object?>((_)=>null,onError:(Object e)=>e);
          final result=await transition;
          expect(result,isA<StateError>());
          expect((result as StateError).message,'identity_transition_inside_local_operation');
        }();
      });
      inheritedDone.complete();
      await releaseOuter.future;
    });
    try {
      await Future<void>.delayed(Duration.zero);
      await continuation;
      expect(cap.epoch,epoch);expect(cap.isCurrent,isTrue);expect(f.host.current,same(scope));
      expect(db.lifecycleState,DatabaseLifecycleState.open);
      expect(f.storage.data[kMarkerKey],marker);expect(f.storage.data[kGenerationKey],generation);
      expect(f.storage.attempts.length,attempts);
    }finally{if(!releaseOuter.isCompleted)releaseOuter.complete();await continuation;await outer;}
    await f.signIn('uid-b');
    expect(f.host.current!.uid,'uid-b');expect(cap.isCurrent,isFalse);
  });

  test('E4 explicit switch supersession drains fixed old work before C owner mutation', () async {
    final cap=f.session.captureLocalWorkAuthority()!;final db=f.host.current!.database;
    final entered=Completer<void>();final release=Completer<void>();
    final old=f.session.runAdmittedLocalOperation(cap,()async{entered.complete();await release.future;});
    await entered.future;
    final before=f.storage.attempts.length;
    final b=f.signIn('uid-b').then<Object?>((_)=>null,onError:(Object e)=>e);
    final c=f.signIn('uid-c').then<Object?>((_)=>null,onError:(Object e)=>e);
    try {
      await Future<void>.delayed(Duration.zero);
      expect(cap.isCurrent,isFalse);expect(db.lifecycleState,DatabaseLifecycleState.open);
      expect(f.storage.attempts.length,before);
      release.complete();await old;
      expect(await b,isA<StaleAdmissionException>());expect(await c,isNull);
      expect(f.host.current!.uid,'uid-c');expect(f.storage.data[kMarkerKey],'uid-c');
      expect(f.storage.attempts.skip(before).where((v)=>v.contains('=uid-b')),isEmpty);
    }finally{if(!release.isCompleted)release.complete();await old;await b;await c;}
  });

  test('E4 notification closed full snapshot intent mismatch and one-use denial', () async {
    final db=f.host.current!.database;final location=f.host.current!.location!;
    await NotificationLogService(db).recordCreated(channel:'local_ios',notificationType:'ticket');
    final snapshot=(await db.customSelect('SELECT * FROM notification_log_events;').getSingle()).data;
    final handle=await capture();final authority=getAuthority();
    expect(await authority.captureNotificationIntent(handle,db,{...snapshot,'event_type':'unknown'}),isNull);
    expect(await authority.captureNotificationIntent(handle,db,{...snapshot,'sync_attempt_count':1}),isNull);
    expect(await authority.captureNotificationIntent(handle,db,{...snapshot,'notification_log_id':'changed-target'}),isNull);
    final intent=(await authority.captureNotificationIntent(handle,db,snapshot))!;
    final result=await authority.acceptNotificationDenial(handle,db,intent,AccountFenceState.pending);
    expect(result.accepted&&result.complete,isTrue);
    expect(db.lifecycleState,DatabaseLifecycleState.closed);
    final repeated=await authority.acceptNotificationDenial(handle,db,intent,AccountFenceState.gone);
    expect(repeated.accepted||repeated.complete,isFalse);
    expect(getAuthority().store.holdFor(AccountFenceStore.ownerDigest('uid-a'))!.state,AccountFenceState.pending);
    expect(await LedgerAdmissionFixture.inspectClosed(db,location,(inspection)async=>
        (await inspection.customSelect('SELECT * FROM notification_log_events;').getSingle()).data),snapshot);
  });

  test('E4 notification actual SDK denial durable write failure remains restrictive and untouched', () async {
    final db=f.host.current!.database;final location=f.host.current!.location!;
    final producer=NotificationLogService(db);
    final id=await producer.recordCreated(channel:'local_ios',notificationType:'failure-truth');
    await producer.recordSent(logId:id,channel:'local_ios',notificationType:'failure-truth');
    Future<List<Map<String,Object?>>> rows(AppDatabase d)async=>[
      for(final row in await d.customSelect('SELECT * FROM notification_log_events ORDER BY rowid;').get())row.data,
    ];
    final before=await rows(db);final cap=f.session.captureLocalWorkAuthority()!;var reached=false;
    f.storage.gate=(op,key)async{if(op=='write'&&key==AccountFenceStore.storageKey){
      reached=true;throw StateError('controlled notification hold write');
    }};
    final requests=<http.Request>[];
    final client=SupabaseClient('https://example.supabase.co','anon',
      authOptions:const AuthClientOptions(autoRefreshToken:false),httpClient:MockClient((request)async{
        requests.add(request);return http.Response(jsonEncode({'code':'QD002','message':'gone','details':null,'hint':null}),
          400,headers:{'content-type':'application/json'},request:request);
      }));
    try {
      await F2Fixture.recoverSession_(client,'uid-a');
      final result=await NotificationLogSyncService(db:db,getClient:()=>client,
        getAuthUserId:()async=>client.auth.currentUser?.id,getCurrentAuthUserId:()=>client.auth.currentUser?.id,
        mayEgress:()async=>true,getInstallId:()async=>'failure-install').debugSyncBatch('uid-a')
        .then<Object?>((_)=>null,onError:(Object e)=>e);
      expect(requests,hasLength(1));expect(requests.single.method,'POST');
      expect(requests.single.url.path,'/rest/v1/notification_logs');
      expect(requests.single.url.queryParameters,{'on_conflict':'id'});
      final body=jsonDecode(requests.single.body) as Map;
      expect(body['id'],id);expect(body['user_id'],'uid-a');expect(body['status'],'pending');
      expect(body['install_id'],'failure-install');expect(body['notification_type'],'failure-truth');
      expect(reached,isTrue);expect(result,isA<NotificationDeliveryStopped>());
      expect((result as NotificationDeliveryStopped).accepted,isTrue);expect(result.complete,isFalse);
      expect(cap.isCurrent,isFalse);expect(db.lifecycleState,DatabaseLifecycleState.closed);
      expect(getAuthority().store.ready,isFalse);expect(getAuthority().store.allows(AccountFenceStore.ownerDigest('uid-a')),isFalse);
      expect(getAuthority().store.holdFor(AccountFenceStore.ownerDigest('uid-a'))!.state,AccountFenceState.gone);
      expect(await LedgerAdmissionFixture.inspectClosed(db,location,rows),before);
    }finally{await client.dispose();f.storage.gate=null;}
  });

  test('E4 sender actual SDK batch denial preserves intent when durable hold write fails', () async {
    final db = f.host.current!.database; final location = f.host.current!.location!;
    final repo = DriftSenderBankMappingRepository(db);
    final mapping = await repo.saveSuggestion(const SenderBankMappingDraft(senderId: 'one',
        suggestedBankName: 'Bank', suggestedCountry: 'SA', confidence: .9));
    await repo.confirm(mappingId: mapping.id, bankKey: 'bank');
    Future<List<Map<String, Object?>>> rows(AppDatabase database) async => [
      for (final row in await database.customSelect('SELECT * FROM sender_bank_mappings;').get()) row.data,
    ];
    final before = await rows(db); final cap = f.session.captureLocalWorkAuthority()!;
    var reached = false;
    f.storage.gate = (op, key) async {
      if (op == 'write' && key == AccountFenceStore.storageKey) {
        reached = true; throw StateError('controlled durable denial write');
      }
    };
    final requests = <http.Request>[];
    final client = SupabaseClient('https://example.supabase.co', 'anon',
        authOptions: const AuthClientOptions(autoRefreshToken: false), httpClient: MockClient((request) async {
      requests.add(request);
      return http.Response(jsonEncode({'code': 'QD001', 'message': 'pending', 'details': null, 'hint': null}),
          400, headers: {'content-type': 'application/json'}, request: request);
    }));
    try {
      final result = await SenderBankMappingSyncService(db: db,
          remoteStore: SupabaseSenderBankMappingRemoteStore(client), currentUserId: () => 'uid-a',
          mayEgress: () async => true).push().then<Object>((v) => v, onError: (Object e) => e);
      expect(requests, hasLength(1)); expect(requests.single.method, 'POST');
      expect(requests.single.url.path, '/rest/v1/sender_bank_mappings');
      expect((jsonDecode(requests.single.body) as List).single['user_id'], 'uid-a');
      expect(reached, isTrue); expect(result, isA<SenderMappingDeliveryStopped>());
      expect((result as SenderMappingDeliveryStopped).accepted, isTrue); expect(result.complete, isFalse);
      expect(cap.isCurrent, isFalse); expect(db.lifecycleState, DatabaseLifecycleState.closed);
      expect(getAuthority().store.ready, isFalse);
      expect(getAuthority().store.allows(AccountFenceStore.ownerDigest('uid-a')), isFalse);
      expect(getAuthority().store.holdFor(AccountFenceStore.ownerDigest('uid-a'))!.state, AccountFenceState.pending);
      expect(await LedgerAdmissionFixture.inspectClosed(db, location, rows), before);
    } finally { await client.dispose(); f.storage.gate = null; }
  });

  test('E4 authority diagnostic B public concurrent captured resume preserves one lifetime', () async {
    final client = await f.clientFor('uid-a');
    final publications = <SessionStatus>[];
    void listener() => publications.add(f.session.status);
    f.session.addListener(listener);
    try {
      await f.session.drainAdmissions();
      final local = f.session.captureLocalWorkAuthority()!;
      final scope = f.host.current;
      final before = f.storage.attempts.length;
      final writesBefore = f.storage.writes.length;
      final hold = f.storage.holdOnce((op, key) => op == 'read' && key == AccountFenceStore.storageKey);
      final a = f.session.revalidateSupabaseSessionOnResume(client, authority: local);
      final b = f.session.revalidateSupabaseSessionOnResume(client, authority: local);
      final aOutcome = a.then<Object?>((_) => null, onError: (Object e) => e);
      final bOutcome = b.then<Object?>((_) => null, onError: (Object e) => e);
      await hold.reached.future;
      expect(local.isCurrent, isFalse);
      expect(f.storage.attempts.skip(before), isEmpty);
      expect(identical(f.host.current, scope), isTrue);
      hold.release.complete();
      expect(await aOutcome, isNull);
      expect(await bOutcome, isNull);
      expect(publications, isNotEmpty);
      expect(publications, everyElement(SessionStatus.authenticated));
      expect(f.session.status, SessionStatus.authenticated);
      expect(identical(f.host.current, scope), isTrue);
      expect(local.isCurrent, isTrue);
      expect(f.storage.writes.skip(writesBefore).where((write) =>
          write == 'onboarding_current_account_v1=uid:uid-a'), isNotEmpty);
      // Redundant void resumes may conservatively return while another finishes.
      // A subsequent quiet shell check must actually reconcile and complete.
      publications.clear();
      final quietWritesBefore = f.storage.writes.length;
      expect(await f.session.revalidateForShell(client), isTrue);
      expect(f.storage.writes.skip(quietWritesBefore).where((write) =>
          write == 'onboarding_current_account_v1=uid:uid-a'), hasLength(1));
      expect(publications, [SessionStatus.authenticated]);
      expect(identical(f.host.current, scope), isTrue);
      expect(local.isCurrent, isTrue);
    } finally {
      f.session.removeListener(listener);
      await client.dispose();
    }
  });

  test('E4 authority diagnostic B actual shell result reaches identity publication', () async {
    final client = await f.clientFor('uid-a');
    final publications = <SessionStatus>[];
    void listener() => publications.add(f.session.status);
    f.session.addListener(listener);
    try {
      await f.session.drainAdmissions();
      final local = f.session.captureLocalWorkAuthority()!;
      final scope = f.host.current;
      final writesBefore = f.storage.writes.length;
      final attemptsBefore = f.storage.attempts.length;
      final hold = f.storage.holdOnce((op, key) => op == 'read' && key == AccountFenceStore.storageKey);
      final loading = getAuthority().initialize();
      final shell = f.session.revalidateForShell(client);
      final shellOutcome = shell.then<Object?>((value) => value, onError: (Object e) => e);
      await hold.reached.future;
      expect(f.storage.attempts.skip(attemptsBefore), isEmpty);
      expect(local.isCurrent, isFalse);
      hold.release.complete();
      expect(await loading, isTrue);
      expect(await shellOutcome, isTrue);
      expect(f.storage.writes.skip(writesBefore).where((write) =>
          write == 'onboarding_current_account_v1=uid:uid-a'), hasLength(1));
      expect(publications, List<SessionStatus>.filled(1, SessionStatus.authenticated),
          reason: 'each awaited public reconcile reaches its final session notification');
      expect(f.session.status, SessionStatus.authenticated);
      expect(identical(f.host.current, scope), isTrue);
      expect(local.isCurrent, isTrue);
    } finally {
      f.session.removeListener(listener);
      await client.dispose();
    }
  });

  test('E4 authority diagnostic B public captured resume cannot release persisted hold', () async {
    final client = await f.clientFor('uid-a');
    try {
      final scope = f.host.current!;
      final local = f.session.captureLocalWorkAuthority()!;
      expect(await getAuthority().store.record(AccountFenceStore.ownerDigest('uid-a'),
          AccountFenceRecord(state: AccountFenceState.pending, operationId: _op,
            ownerGeneration: f.storage.data[kGenerationKey]!,
            replicaDigest: AccountFenceStore.replicaDigest(scope.location!.dbPath, scope.location!.keyName),
            scopeGeneration: scope.generation)), isTrue);
      final stored = f.storage.data[AccountFenceStore.storageKey];
      final before = f.storage.attempts.length;
      await f.session.revalidateSupabaseSessionOnResume(client, authority: local);
      expect(local.isCurrent, isFalse);
      expect(f.storage.attempts.skip(before), isEmpty);
      expect(f.storage.data[AccountFenceStore.storageKey], stored);
      expect(getAuthority().permits('uid-a'), isFalse);
    } finally {
      await client.dispose();
    }
  });

  test('E4 authority required explicit admission retires before held fence read', () async {
    final oldLocal = f.session.captureLocalWorkAuthority()!;
    final oldMaintenance = await f.session.maintenanceAuthority('uid-a');
    final hold = f.storage.holdOnce((op, key) => op == 'read' && key == AccountFenceStore.storageKey);
    final entering = f.session.setIdentity(method: 'google', userId: 'uid-b');
    final outcome = entering.then<Object?>((_) => null, onError: (Object error) => error);
    try {
      // This assertion intentionally runs before the first yield after entry.
      expect(f.session.status, SessionStatus.needsOnboarding);
      expect(oldLocal.isCurrent, isFalse);
      expect(oldMaintenance.isCurrent, isFalse);
      expect(f.session.captureLocalWorkAuthority(), isNull);
      await hold.reached.future;
    } finally {
      hold.release.complete();
      await outcome;
    }
  });

  for (final successor in ['uid-a', 'uid-b']) {
    test('E4 authority required old held guard cannot clear $successor successor', () async {
      final hold = f.storage.holdOnce((op, key) => op == 'read' && key == AccountFenceStore.storageKey);
      final old = f.session.setIdentity(method: 'google', userId: 'uid-old');
      final oldOutcome = old.then<Object?>((_) => null, onError: (Object error) => error);
      await hold.reached.future;
      final next = f.signIn(successor);
      final nextOutcome = next.then<Object?>((_) => null, onError: (Object error) => error);
      hold.release.complete();
      expect(await oldOutcome, isA<StaleAdmissionException>());
      expect(await nextOutcome, isNull);
      final scope = f.host.current;
      expect(scope?.uid, successor);
      expect(f.storage.data[kMarkerKey], successor);
      expect(f.session.status, SessionStatus.authenticated);
      expect(f.session.captureLocalWorkAuthority()!.isCurrent, isTrue);
      expect(await getAuthority().capture(f.session, f.host), isNotNull);
      expect(identical(f.host.current, scope), isTrue);
    });
  }

  for (final marker in <String?>[null, '', 'owner-transition-pending:unproven']) {
    test('E4 authority required retained nonguest load rejects owner=$marker', () async {
      final oldDatabase = f.host.current!.database;
      await f.host.detach();
      expect(oldDatabase.lifecycleState, DatabaseLifecycleState.closed);
      f.session.configureAccountScope(null);
      expect(f.host.activeUid, isNull);
      expect(f.session.captureLocalWorkAuthority(), isNull);
      if (marker == null) {
        f.storage.data.remove(kMarkerKey);
      } else {
        f.storage.data[kMarkerKey] = marker;
      }
      final metadata = <String, String?>{
        for (final key in ['auth_method', 'onboarding_current_account_v1', 'onboarding_completed_accounts_v1'])
          key: f.storage.data[key],
      };
      expect(metadata['auth_method'], 'google');
      expect(metadata['onboarding_completed_accounts_v1'], contains('uid:uid-a'));
      final before = f.storage.attempts.length;
      try {
        await f.session.load();
        expect(f.session.status, SessionStatus.needsOnboarding);
        expect(f.session.captureLocalWorkAuthority(), isNull);
        expect(f.host.activeUid, isNull);
        expect(f.storage.attempts.skip(before), isEmpty);
        for (final entry in metadata.entries) {
          expect(f.storage.data[entry.key], entry.value);
        }
      } finally {
        f.storage.data[kMarkerKey] = 'uid-a';
      }
    });
  }

  test('E4 authority required retained valid owner load remains authenticated', () async {
    await f.session.load();
    expect(f.session.status, SessionStatus.authenticated);
    expect(f.host.current?.uid, 'uid-a');
    expect(f.session.captureLocalWorkAuthority()!.isCurrent, isTrue);
  });

  test('E4 authority required retained guest load permits absent owner', () async {
    await f.session.signOut();
    await f.session.completeOnboarding(method: 'guest');
    await f.host.detach();
    f.session.configureAccountScope(null);
    f.storage.data.remove(kMarkerKey);
    try {
      await f.session.load();
      expect(f.session.isGuest, isTrue);
      expect(f.session.status, SessionStatus.authenticated);
      expect(f.host.activeUid, isNull);
    } finally {
      f.storage.data[kMarkerKey] = 'uid-a';
    }
  });

  for (final state in AccountFenceState.values) {
    test('E4 authority current ${state.name} retires real capabilities before blocked persistence', () async {
      final handle = await capture();
      final local = f.session.captureLocalWorkAuthority()!;
      final maintenance = await f.session.maintenanceAuthority('uid-a');
      final database = f.host.current!.database;
      final epoch = CloudEgressGate.instance.epoch;
      final keyBefore = Map<String, String>.from(f.storage.data);
      final deletesBefore = List<String>.from(f.storage.deletes);
      final hold = f.storage.holdOnce((op, key) => op == 'write' && key == AccountFenceStore.storageKey);
      final run = getAuthority().accept(handle, state, operationId: _op);
      expect(local.isCurrent, isFalse);
      expect(maintenance.isCurrent, isFalse);
      expect(CloudEgressGate.instance.epoch, greaterThan(epoch));
      expect(() => f.session.runAdmittedLocalOperation(local, () async => 1),
          throwsA(isA<StaleAdmissionException>()));
      await hold.reached.future;
      final sameUid = f.signIn('uid-a').then<Object?>((_) => null,
          onError: (Object error) => error);
      final denied = await getAuthority().capture(f.session, f.host);
      expect(denied, isNull);
      hold.release.complete();
      final result = await run;
      expect(await sameUid, isA<AccountFenceDeniedException>());
      expect(result.accepted, isTrue); expect(result.complete, isTrue);
      expect(database.lifecycleState, DatabaseLifecycleState.closed);
      expect(f.host.current?.uid, isNull);
      expect(f.storage.data[kMarkerKey], 'uid-a');
      expect(f.storage.data[kGenerationKey] == keyBefore[kGenerationKey], isTrue);
      expect(f.storage.deletes, deletesBefore, reason: 'denial performs no new deletion');
      expect(await f.artifactsOf('uid-a'), ['dir', 'key', 'registry']);
      expect(f.order, isEmpty);
      await expectLater(f.signIn('uid-a'), throwsA(isA<AccountFenceDeniedException>()));
      await expectLater(f.session.maintenanceAuthority('uid-a'), throwsA(isA<AccountFenceDeniedException>()));
    });
  }

  for (final successor in ['uid-a', 'uid-b']) {
    test('E4 authority stale denial leaves committed $successor successor unchanged', () async {
      final old = await capture();
      await f.signIn(successor);
      final scope = f.host.current;
      final capability = f.session.captureLocalWorkAuthority()!;
      final before = f.storage.attempts.length;
      final result = await getAuthority().accept(old, AccountFenceState.gone, operationId: _op);
      expect(result.accepted, isFalse); expect(result.complete, isFalse);
      expect(identical(f.host.current, scope), isTrue);
      expect(capability.isCurrent, isTrue);
      expect(f.storage.attempts.skip(before), isEmpty);
      expect(f.storage.data[AccountFenceStore.storageKey], isNull);
    });
  }

  test('E4 authority wrapper-only host evidence refuses capture', () async {
    f.session.configureAccountScope(f.scope);
    expect(await getAuthority().capture(f.session, f.host), isNull);
  });

  test('E4 authority owner proof read cannot adopt a same-UID successor', () async {
    final hold = f.storage.holdOnce((op, key) => op == 'read' && key == kGenerationKey);
    final capturing = getAuthority().capture(f.session, f.host);
    await hold.reached.future;
    await f.signIn('uid-a');
    hold.release.complete();
    expect(await capturing, isNull);
    expect(f.session.captureLocalWorkAuthority()!.isCurrent, isTrue);
  });

  test('E4 authority missing unreadable or changed owner token refuses capture', () async {
    final before = f.storage.data[kGenerationKey]!;
    f.storage.data[kGenerationKey] = 'different-token';
    expect(await getAuthority().capture(f.session, f.host), isNull);
    f.storage.data[kGenerationKey] = before;
    f.storage.gate = (op, key) async {
      if (op == 'read' && key == kGenerationKey) throw StateError('unavailable');
    };
    expect(await getAuthority().capture(f.session, f.host), isNull);
  });

  test('E4 authority registered local reservation covers reentrant denial and independent DB completion', () async {
    final handle = await capture();
    final capability = f.session.captureLocalWorkAuthority()!;
    final database = f.host.current!.database;
    final arrived = Completer<void>(); final release = Completer<void>();
    late Future<AccountFenceResult> denial;
    final local = f.session.runAdmittedLocalOperation(capability, () {
      final transaction = database.transaction(() async {
        await database.customStatement('CREATE TABLE fence_probe(value TEXT);');
        arrived.complete();
        await release.future;
        await database.customStatement("INSERT INTO fence_probe VALUES ('committed');");
      });
      // Reentrant acceptance before action returns its future: the real local
      // reservation must already be visible to the denial's drain snapshot.
      denial = getAuthority().accept(handle, AccountFenceState.pending, operationId: _op);
      return transaction;
    });
    await arrived.future;
    var denialDone = false; denial.then((_) => denialDone = true);
    final bStarted = Completer<void>();
    f.initialize = (db, uid) async {
      if (uid == 'uid-b') bStarted.complete();
      return const AccountScopeInit();
    };
    final successor = f.signIn('uid-b');
    expect(denialDone, isFalse);
    expect(bStarted.isCompleted, isFalse);
    expect(database.lifecycleState, DatabaseLifecycleState.open);
    release.complete(); await local;
    expect((await denial).complete, isTrue);
    await successor;
    expect(database.lifecycleState, DatabaseLifecycleState.closed);
    expect(f.host.current?.uid, 'uid-b');
    expect(bStarted.isCompleted, isTrue);
  });

  for (final launch in [false, true]) {
    test('E4 authority direct host launch=$launch read race never waits on its own cleanup', () async {
      final handle = await capture();
      final old = f.host.current!.database;
      final hold = f.storage.holdOnce((op, key) => op == 'read' && key == AccountFenceStore.storageKey);
      final transition = launch ? f.host.openAtLaunch('uid-b') : f.host.activate('uid-b');
      final outcome = transition.then<Object?>((_) => null, onError: (Object e) => e);
      await hold.reached.future;
      expect(f.session.captureLocalWorkAuthority()!.isCurrent, isFalse,
          reason: 'ordinary capability remains fail-closed during readiness read');
      final denial = getAuthority().accept(handle, AccountFenceState.gone, operationId: _op);
      hold.release.complete();
      final result = await denial;
      await outcome;
      expect(result.complete, isTrue);
      expect(old.lifecycleState, DatabaseLifecycleState.closed);
      expect(f.host.current?.uid, isNot('uid-b'));
      expect(await f.artifactsOf('uid-b'), isEmpty);
    });
  }

  for (final successor in ['uid-a', 'uid-b']) {
    test('E4 authority stale launch read leaves committed $successor status and capabilities intact', () async {
      final hold = f.storage.holdOnce((op, key) => op == 'read' && key == kMarkerKey);
      final launch = f.session.prepareLaunchAdmission();
      await hold.reached.future;
      await f.signIn(successor);
      final scope = f.host.current;
      final capability = f.session.captureLocalWorkAuthority()!;
      hold.release.complete();
      expect((await launch).blocked, isTrue);
      expect(identical(f.host.current, scope), isTrue);
      expect(f.session.status, SessionStatus.authenticated);
      expect(capability.isCurrent, isTrue);
    });
  }

  for (final state in AccountFenceState.values) {
    test('E4 authority persisted ${state.name} load cannot finish onboarding or write consent', () async {
      final scope = f.host.current!;
      final generation = f.storage.data[kGenerationKey]!;
      expect(await getAuthority().store.record(AccountFenceStore.ownerDigest('uid-a'),
          AccountFenceRecord(state: state, operationId: _op,
            ownerGeneration: generation, replicaDigest: AccountFenceStore.replicaDigest(
                scope.location!.dbPath, scope.location!.keyName), scopeGeneration: scope.generation)), isTrue);
      await f.session.load();
      final before = f.storage.attempts.length;
      await f.session.finishOnboarding();
      await f.session.markConsentPromptSeen();
      expect(f.session.status, isNot(SessionStatus.authenticated));
      expect(f.storage.attempts.skip(before), isEmpty,
          reason: 'persisted hold cannot republish onboarding or write consent');
    });

    test('E4 authority accepted ${state.name} denial blocks new consent writes', () async {
      final handle = await capture();
      expect((await getAuthority().accept(handle, state, operationId: _op)).complete, isTrue);
      final before = f.storage.attempts.length;
      await f.session.markConsentPromptSeen();
      expect(f.storage.attempts.skip(before), isEmpty);
    });
  }

  for (final successor in ['uid-a', 'uid-b']) {
    test('E4 authority old load read cannot change committed $successor state', () async {
      final hold = f.storage.holdOnce((op, key) => op == 'read' && key == 'auth_email');
      final loading = f.session.load();
      await hold.reached.future;
      await f.signIn(successor);
      final scope = f.host.current;
      final capability = f.session.captureLocalWorkAuthority()!;
      final email = f.session.email;
      hold.release.complete();
      await loading;
      expect(identical(f.host.current, scope), isTrue);
      expect(f.session.status, SessionStatus.authenticated);
      expect(f.session.email, email);
      expect(capability.isCurrent, isTrue);
    });
  }

  test('E4 authority whole-instance replacement rejects active cleanup and stale restore leases', () async {
    final handle = await capture();
    final hold = f.storage.holdOnce((op, key) => op == 'write' && key == AccountFenceStore.storageKey);
    final authority = getAuthority();
    final denial = authority.accept(handle, AccountFenceState.gone, operationId: _op);
    await hold.reached.future;
    f.session.configureAccountScope(null);
    expect(AccountFenceAuthority.replacePersistenceForTest, throwsStateError);
    expect(identical(getAuthority(), authority), isTrue);
    hold.release.complete(); expect((await denial).complete, isTrue);
    final outer = AccountFenceAuthority.replacePersistenceForTest();
    final outerInstance = getAuthority();
    final inner = AccountFenceAuthority.replacePersistenceForTest();
    final innerInstance = getAuthority();
    expect(outer, throwsStateError);
    expect(identical(getAuthority(), innerInstance), isTrue);
    inner();
    expect(identical(getAuthority(), outerInstance), isTrue);
    expect(inner, throwsStateError);
    expect(identical(getAuthority(), outerInstance), isTrue);
    outer();
    expect(identical(getAuthority(), authority), isTrue);
    expect(outer, throwsStateError);
  });

  for (final successor in ['uid-a', 'uid-b']) {
    for (final boundary in ['strict-owner-read', 'delete']) {
      test('E4 authority old launch cleanup $boundary drains before committed $successor', () async {
        // Explicit removal is a precondition from the existing removal contract,
        // not an account-fence action. It leaves identity cleanup for launch.
        await f.flow.remove('uid-a');
        final reached = Completer<void>(); final release = Completer<void>();
        final launchZoneKey = Object();
        var launchGlobalPurges = 0;
        if (boundary == 'strict-owner-read') {
          f.session.configureCaptureOwnerClear(() async {
            if (Zone.current[launchZoneKey] == true) launchGlobalPurges++;
            return true;
          });
          var markerReads = 0;
          f.storage.gate = (op, key) async {
            // Launch reads its initial marker, then the post-resume marker;
            // the third read belongs to strict original-owner cleanup.
            if (op == 'read' && key == kMarkerKey && ++markerReads == 3) {
              reached.complete(); await release.future;
            }
          };
        } else {
          f.storage.gate = (op, key) async {
            if (op == 'delete' && key == 'auth_method' && !reached.isCompleted) {
              reached.complete(); await release.future;
            }
          };
        }
        final launch = runZoned(f.session.prepareLaunchAdmission,
            zoneValues: {launchZoneKey: true});
        await reached.future;
        final entering = Completer<void>();
        f.initialize = (db, uid) async {
          if (uid == successor && !entering.isCompleted) entering.complete();
          return const AccountScopeInit();
        };
        final committing = f.signIn(successor);
        expect(entering.isCompleted, isFalse);
        release.complete();
        expect((await launch).blocked, isTrue);
        await committing;
        expect(f.host.current?.uid, successor);
        expect(f.session.status, SessionStatus.authenticated);
        expect(f.session.captureLocalWorkAuthority()!.isCurrent, isTrue);
        expect(f.storage.data[kMarkerKey], successor);
        expect(launchGlobalPurges, 0, reason: 'strict launch cleanup invokes no global purge');
      });
    }
  }

  test('E4 authority delayed exact-scope close never touches a committed replacement', () async {
    final old = f.host.current!;
    await f.signIn('uid-b');
    final replacement = f.host.current;
    final capability = f.session.captureLocalWorkAuthority()!;
    await f.host.closeAccountFenceScope(old);
    expect(identical(f.host.current, replacement), isTrue);
    expect(old.database.lifecycleState, DatabaseLifecycleState.closed);
    expect(capability.isCurrent, isTrue);
  });

  for (final marker in <String?>[null, '', 'owner-transition-pending:unproven']) {
    test('E4 authority nonguest unproven owner=$marker cannot publish authenticated', () async {
      await f.session.signOut();
      expect(f.host.current?.uid, isNull);
      f.session.configureAccountScope(null);
      f.session.authMethod = 'google';
      if (marker == null) {
        f.storage.data.remove(kMarkerKey);
      } else {
        f.storage.data[kMarkerKey] = marker;
      }
      f.session.value = SessionStatus.needsOnboarding;
      final before = f.storage.attempts.length;
      try {
        await f.session.finishOnboarding();
        expect(f.session.status, isNot(SessionStatus.authenticated));
        expect(f.storage.attempts.skip(before), isEmpty);
      } finally {
        // Restore only the deliberately corrupt fixture marker for existing
        // teardown; no application denial is cleared or permission granted.
        f.storage.data[kMarkerKey] = 'uid-a';
      }
    });
  }

  test('E4 authority legitimate explicit guest and signed-out onboarding remain safe', () async {
    await f.session.signOut();
    await f.session.finishOnboarding();
    expect(f.session.status, SessionStatus.needsOnboarding);
    await f.session.completeOnboarding(method: 'guest');
    expect(f.session.isGuest, isTrue);
    expect(f.session.status, SessionStatus.authenticated);
    expect(f.host.current?.uid, isNull);
  });

  for (final state in AccountFenceState.values) {
    test('E4 authority actual SDK refresh and resume cannot release ${state.name}', () async {
      final client = await f.clientFor('uid-a');
      try {
        await f.session.revalidateSupabaseSessionOnResume(client);
        expect(f.session.status, SessionStatus.authenticated);
        final handle = await capture();
        expect((await getAuthority().accept(handle, state, operationId: _op)).complete, isTrue);
        final encoded = f.storage.data[AccountFenceStore.storageKey];
        final before = f.storage.attempts.length;
        await client.auth.refreshSession();
        await f.session.revalidateSupabaseSessionOnResume(client);
        expect(await f.session.revalidateForShell(client), isFalse);
        await expectLater(f.session.maintenanceAuthority('uid-a'), throwsA(isA<AccountFenceDeniedException>()));
        expect(f.host.current?.uid, isNull);
        expect(f.session.status, isNot(SessionStatus.authenticated));
        expect(f.storage.data[AccountFenceStore.storageKey] == encoded, isTrue);
        expect(f.storage.attempts.skip(before), isEmpty);
      } finally {
        await client.dispose();
      }
    });
  }

  for (final successor in ['uid-a', 'uid-b']) {
    test('E4 authority actual old load migration write drains before $successor commit', () async {
      // A real missing legacy completion needs migration; an already recorded
      // account deliberately performs no write on load (offline local read).
      f.storage.data['onboarding_completed_accounts_v1'] = '[]';
      final hold = f.storage.holdOnce((op, key) => op == 'write' && key == 'onboarding_completed_accounts_v1');
      final loading = f.session.load().then<Object?>((_) => null,
          onError: (Object error) => error);
      Future<Object?>? committing;
      final transitionStarted = Completer<void>();
      void listener() {
        if (f.session.status == SessionStatus.needsOnboarding && !transitionStarted.isCompleted) {
          transitionStarted.complete();
        }
      }
      f.session.addListener(listener);
      try {
        await hold.reached.future.timeout(const Duration(seconds: 5));
        var committed = false;
        committing = f.signIn(successor).then<Object?>((_) {
          committed = true;
          return null;
        }, onError: (Object error) => error);
        await transitionStarted.future.timeout(const Duration(seconds: 5));
        expect(committed, isFalse);
        hold.release.complete();
        expect(await loading.timeout(const Duration(seconds: 10)), isNull);
        expect(await committing.timeout(const Duration(seconds: 10)), isNull);
        expect(f.session.status, SessionStatus.authenticated);
        expect(f.host.current?.uid, successor);
        expect(f.storage.data['onboarding_current_account_v1'], 'uid:$successor');
        final completed = jsonDecode(f.storage.data['onboarding_completed_accounts_v1']!) as List<dynamic>;
        expect(completed, contains('uid:uid-a'));
        expect(completed, contains('uid:$successor'),
            reason: 'the old held list write cannot overwrite the successor completion');
        expect(f.storage.data[kMarkerKey], successor);
        expect(f.session.captureLocalWorkAuthority()!.isCurrent, isTrue);
        expect(await getAuthority().capture(f.session, f.host), isNotNull);
      } finally {
        if (!hold.release.isCompleted) hold.release.complete();
        f.session.removeListener(listener);
        expect(await loading.timeout(const Duration(seconds: 10)), isNull);
        if (committing != null) {
          expect(await committing.timeout(const Duration(seconds: 10)), isNull);
        }
      }
    });
  }

  test('E4 authority identity wipe invalidates captured owner proof without clearing denial state', () async {
    final handle = await capture();
    await f.session.wipeAndReset();
    final before = f.storage.attempts.length;
    final result = await getAuthority().accept(handle, AccountFenceState.gone, operationId: _op);
    expect(result.accepted, isFalse);
    expect(f.storage.attempts.skip(before), isEmpty);
    expect(getAuthority().store.holdFor(AccountFenceStore.ownerDigest('uid-a')), isNull);
  });

  for(final writeFailure in [false,true]) {
    test('engagement closed intent exact fields reuse and completion writeFailure=$writeFailure',()async {
      final db=f.host.current!.database;final location=f.host.current!.location!;
      await db.customStatement("INSERT INTO engagement_events(event_id,event_type,occurred_at,business_key,event_version,status,attempt_count,created_at) VALUES ('event-short','goal_contribution','2026-01-01T00:00:00Z',NULL,1,'pending',0,'2026-01-01T00:00:00Z');");
      final authority=getAuthority();final handle=await capture();
      Future<AccountFenceEngagementIntent?> intent({String id='event-short',String type='goal_contribution',
          String occurred='2026-01-01T00:00:00Z',String? key,int version=1}) =>
          authority.captureEngagementIntent(handle,db,eventId:id,eventType:type,occurredAt:occurred,
              businessKey:key,eventVersion:version);
      expect(await intent(id:''),isNull);expect(await intent(id:'other'),isNull);
      expect(await intent(type:'bill_payment'),isNull);expect(await intent(occurred:'other'),isNull);
      expect(await intent(key:'unexpected'),isNull);expect(await intent(version:2),isNull);
      final captured=(await intent())!;final before=(await db.customSelect('SELECT * FROM engagement_events;').getSingle()).data;
      final xpBefore=(await db.customSelect('SELECT * FROM xp_levels LIMIT 1;').getSingle()).data;
      if(writeFailure)f.storage.gate=(op,key)async{if(op=='write'&&key==AccountFenceStore.storageKey)throw StateError('synthetic write unavailable');};
      final accepting=authority.acceptEngagementDenial(handle,db,captured,AccountFenceState.pending);
      expect(f.session.captureLocalWorkAuthority(),isNull);
      final result=await accepting;expect(result.accepted,isTrue);expect(result.complete,!writeFailure);
      expect(db.lifecycleState,DatabaseLifecycleState.closed);
      final retained=await LedgerAdmissionFixture.inspectClosed(db,location,(inspection)async=>(
          event:(await inspection.customSelect('SELECT * FROM engagement_events;').getSingle()).data,
          xp:(await inspection.customSelect('SELECT * FROM xp_levels LIMIT 1;').getSingle()).data));
      expect(retained.event,before);expect(retained.xp,xpBefore);
      expect((await authority.acceptEngagementDenial(handle,db,captured,AccountFenceState.gone)).accepted,isFalse);
      f.storage.gate=null;
    });
  }

  for (final failedWrite in [false,true]) {
    test('SmartInbox closed intent accepts during unready load writeFailure=$failedWrite',()async{
      final db=f.host.current!.database;final location=f.host.current!.location!;
      await db.customStatement("INSERT INTO smart_inbox_items(id,server_id,type,title,status,server_created_at,synced_at,created_at,updated_at,pending_sync) VALUES ('status-local','status-server','needs_review','Synthetic','dismissed','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z',1);");
      final authority=getAuthority();final handle=await capture();
      Future<AccountFenceSmartInboxIntent?> intent({String server='status-server',String status='dismissed'}) =>
          authority.captureSmartInboxIntent(handle,db,localId:'status-local',serverId:server,
              status:status,editStamp:'2026-01-01T00:00:00Z');
      expect(await intent(server:'local_capture:status'),isNull);
      expect(await intent(status:'resolved'),isNull);
      final actual=(await intent())!;
      final before=(await db.customSelect('SELECT * FROM smart_inbox_items;').getSingle()).data;
      final cap=f.session.captureLocalWorkAuthority()!;
      final hold=f.storage.holdOnce((op,key)=>op=='read'&&key==AccountFenceStore.storageKey);
      final loading=authority.initialize();await hold.reached.future;
      expect(cap.isCurrent,isFalse,reason:'ordinary dispatch stays denied while loading');
      if(failedWrite){final previous=f.storage.gate;f.storage.gate=(op,key)async{
        if(op=='write'&&key==AccountFenceStore.storageKey)throw StateError('synthetic persistence unavailable');
        await previous?.call(op,key);
      };}
      final accepting=authority.acceptSmartInboxDenial(handle,db,actual,AccountFenceState.pending);
      expect(cap.isCurrent,isFalse);hold.release.complete();await loading;
      final result=await accepting;expect(result.accepted,isTrue);expect(result.complete,!failedWrite);
      expect(db.lifecycleState,DatabaseLifecycleState.closed);
      final after=await LedgerAdmissionFixture.inspectClosed(db,location,(inspection)async=>
          (await inspection.customSelect('SELECT * FROM smart_inbox_items;').getSingle()).data);
      expect(after,before);expect(after['pending_sync'],1);expect(after['push_attempt_count'],0);
      expect((await authority.acceptSmartInboxDenial(handle,db,actual,AccountFenceState.gone)).accepted,isFalse);
      f.storage.gate=null;
    });
  }

  test('E4 authority synchronous local throw releases its reservation', () async {
    final handle = await capture(); final capability = f.session.captureLocalWorkAuthority()!;
    expect(() => f.session.runAdmittedLocalOperation<void>(capability, () {
      throw StateError('synchronous');
    }), throwsStateError);
    expect((await getAuthority().accept(handle, AccountFenceState.gone, operationId: _op)).complete, isTrue);
  });

  for (final mode in ['write', 'readback', 'preclose']) {
    test('E4 authority $mode failure reports incomplete and stays restrictive', () async {
      final handle = await capture();
      var written = false;
      f.storage.gate = (op, key) async {
        if (key != AccountFenceStore.storageKey) return;
        if (op == 'write') {
          written = true;
          if (mode == 'write') throw StateError('write unavailable');
        }
        if (op == 'read' && written && mode == 'readback') throw StateError('readback unavailable');
      };
      if (mode == 'preclose') {
        // Exercise a real serial host teardown hook, not a fake authority close.
        await f.host.lock();
        await f.dispose();
        f = await F2Fixture.create(afterWithdraw: () async => throw StateError('preclose'));
        f.session.configureAccountScope(f.host);
        await f.signIn('uid-a');
        final failing = await capture();
        final unclosed = f.host.current!.database;
        final result = await getAuthority().accept(failing, AccountFenceState.gone, operationId: _op);
        expect(result.accepted, isTrue); expect(result.complete, isFalse);
        expect(unclosed.lifecycleState, DatabaseLifecycleState.open);
        await unclosed.close();
      } else {
        final result = await getAuthority().accept(handle, AccountFenceState.gone, operationId: _op);
        expect(result.accepted, isTrue); expect(result.complete, isFalse);
      }
      expect(getAuthority().permits('uid-a'), isFalse);
      expect(getAuthority().permits('uid-b'), isFalse);
      await expectLater(f.signIn('uid-b'), throwsA(isA<AccountFenceDeniedException>()));
    });
  }

  test('E4 authority actual executor close failure remains incomplete and restrictive', () async {
    await f.dispose();
    late _CloseFailure executor;
    f = await F2Fixture.create(afterWithdraw: () async {}, opener: ({
      location, runMigrations = true,
      creation = const CreationPolicy.unrestricted(),
    }) async {
      // Real key custody remains in the existing secure key store even though
      // this particular close-failure executor uses a local SQLite test file.
      await SecureDatabaseKeyStore(storageKey: location!.keyName,
          databaseExists: () => File(location.dbPath).exists(),
          creation: creation).readOrCreateKey();
      executor = _CloseFailure(NativeDatabase(File(location.dbPath)));
      return AppDatabase.open(executor: executor, location: location,
          runMigrations: runMigrations, creation: creation);
    });
    f.session.configureAccountScope(f.host);
    await f.signIn('uid-a');
    final handle = await capture(); final scope = f.host.current!;
    executor.failClose = true;
    final result = await getAuthority().accept(handle, AccountFenceState.gone, operationId: _op);
    expect(result.accepted, isTrue); expect(result.complete, isFalse);
    expect(executor.closeAttempts, 1);
    expect(scope.database.lifecycleState, DatabaseLifecycleState.closing);
    expect(getAuthority().permits('uid-a'), isFalse);
    expect(getAuthority().permits('uid-b'), isFalse);
    expect(f.storage.data[kMarkerKey], 'uid-a');
    expect(await f.keyPresent('uid-a'), isTrue);
    // Only test resource cleanup can close the delegate after proving that the
    // real AppDatabase.close failed; this never changes the result to complete.
    await executor.delegate.close();
  });

  for (final mode in ['parking', 'write', 'readback', 'executor-close']) {
    test('E4 ledger raw SDK denial $mode failure is truthful and restrictive', () async {
      _CloseFailure? controlled;
      if (mode == 'parking' || mode == 'executor-close') {
        await f.dispose();
        f = await F2Fixture.create(afterWithdraw: () async {}, opener: ({
          location, runMigrations = true, creation = const CreationPolicy.unrestricted(),
        }) async {
          await SecureDatabaseKeyStore(storageKey: location!.keyName,
              databaseExists: () => File(location.dbPath).exists(), creation: creation).readOrCreateKey();
          controlled = _CloseFailure(NativeDatabase(File(location.dbPath)));
          return AppDatabase.open(executor: controlled, location: location,
              runMigrations: runMigrations, creation: creation);
        });
        f.session.configureAccountScope(f.host);
        await f.signIn('uid-a');
      }
      final db = f.host.current!.database;
      final cap = f.session.captureLocalWorkAuthority()!;
      const stamp = '2026-10-01T00:00:00.000Z';
      await db.customStatement("INSERT INTO transactions(id, amount, currency, type, source, direction, occurred_at, raw_message, parse_confidence, status, created_at, updated_at) VALUES ('ledger-denied', 100, 'SAR', 'payment', 'bank', 'debit', '$stamp', '', 1, 'confirmed', '$stamp', '$stamp');");
      await backfillNonPlanningMoneyV30(db);
      final queue = LedgerOutboxQueue(db: db, isPushEnabled: () => true,
          getAuthUserId: () async => 'uid-a', getOwnerUid: f.session.readLocalDataOwnerUid);
      await queue.enqueue(OutboxOperation.create, (await DriftTransactionRepository(db).getById('ledger-denied'))!);
      final before = (await db.customSelect('SELECT * FROM ledger_sync_outbox;').getSingle()).data;
      var calls = 0; var written = false;
      f.storage.gate = (op, key) async {
        if (key != AccountFenceStore.storageKey) return;
        if (op == 'write') {
          written = true;
          if (mode == 'write') throw StateError('controlled durable write unavailable');
        }
        if (op == 'read' && written && mode == 'readback') throw StateError('controlled readback unavailable');
      };
      controlled?.failClose = mode == 'executor-close';
      controlled?.failParking = mode == 'parking';
      final client = SupabaseClient('https://example.supabase.co', 'anon', accessToken: () async => 'synthetic',
          httpClient: MockClient((request) async {
        calls++;
        return http.Response(jsonEncode({'code': 'QD002', 'message': 'typed refusal'}), 400,
            headers: {'content-type': 'application/json'}, request: request);
      }));
      try {
        LedgerDeliveryStopped? outcome;
        try {
          await LedgerPushService(db: db, queue: queue, isPushEnabled: () => true,
              getAuthUserId: () async => 'uid-a', getClient: () => client,
              mayEgress: () async => true).push();
        } on LedgerDeliveryStopped catch (error) { outcome = error; }
        expect(outcome, isNotNull);
        expect(outcome!.accepted, isTrue);
        expect(outcome.parked, mode != 'parking');
        expect(outcome.complete, isFalse);
        expect(cap.isCurrent, isFalse); expect(calls, 1);
        expect(getAuthority().permits('uid-a'), isFalse);
        expect(f.storage.data[kMarkerKey], 'uid-a');
        expect(await f.keyPresent('uid-a'), isTrue);
        expect(getAuthority().store.holdFor(AccountFenceStore.ownerDigest('uid-a'))?.state, AccountFenceState.gone);
        if (mode == 'executor-close') {
          expect(db.lifecycleState, DatabaseLifecycleState.closing);
          expect(controlled!.closeAttempts, 1);
          final row = controlled!.lastParked!;
          expect(row['payload_json'], before['payload_json']);
          expect(row['operation_id'], before['operation_id']);
          expect(row['attempt_count'], 0);
          expect(row['status'], 'parked');
        } else { expect(db.lifecycleState, DatabaseLifecycleState.closed); }
        await expectLater(f.signIn('uid-a'), throwsA(isA<AccountFenceDeniedException>()));
      } finally {
        await client.dispose();
        if (mode == 'executor-close') await controlled!.delegate.close();
      }
    });
  }


  Future<(PlanningOutboxQueue, PlanningOutboxItem)> accountIntent() async {
    final db = f.host.current!.database;
    final repository = DriftAccountRepository(db);
    final account = AccountEntity(id: 'account-denied', name: 'Synthetic', currency: 'SAR',
        type: AccountType.bank, isDefault: false, sortOrder: 1,
        createdAt: DateTime.utc(2026, 10, 1), updatedAt: DateTime.utc(2026, 10, 1),
        initialBalanceMoney: Money(0, 'SAR'), currentBalanceMoney: Money(0, 'SAR'));
    await repository.create(account);
    final queue = PlanningOutboxQueue(db: db, isSyncEnabled: (_) => true,
        getAuthUserId: () async => 'uid-a', getOwnerUid: f.session.readLocalDataOwnerUid);
    await queue.enqueueAccount(PlanningSyncOperation.create, account);
    return (queue, (await queue.pendingItems(entityType: PlanningOutboxQueue.accountsEntityType)).single);
  }

  for (final state in AccountFenceState.values) {
    test('E4 account exact one-use ticket rejects mismatches and settled reuse state=${state.name}', () async {
      final (queue, item) = await accountIntent();
      final db = f.host.current!.database;
      final handle = await capture();
      final cap = f.session.captureLocalWorkAuthority()!;
      var invalidCalled = false;
      final invalid = await getAuthority().acceptAccountsDenial(handle, db, state,
          rowId: item.id, entityType: 'settings', entityId: item.entityId,
          ownerUid: item.ownerUid, opSeq: item.opSeq, operationId: item.operationId!,
          park: (_) async { invalidCalled = true; return true; });
      expect(invalid.accepted || invalid.parked || invalid.complete, isFalse);
      expect(invalidCalled, isFalse); expect(cap.isCurrent, isTrue);
      final wrongDb = await AppDatabase.open(executor: NativeDatabase.memory());
      AccountFenceAccountsParking? saved;
      try {
        final result = await getAuthority().acceptAccountsDenial(handle, db, state,
            rowId: item.id, entityType: item.entityType, entityId: item.entityId,
            ownerUid: item.ownerUid, opSeq: item.opSeq, operationId: item.operationId!,
            park: (ticket) async {
              saved = ticket;
              void exact({AppDatabase? database, String? row, String? type, String? entity,
                  String? uid, int? sequence, String? operation}) => ticket.requireExact(database ?? db,
                  rowId: row ?? item.id, entityType: type ?? item.entityType,
                  entityId: entity ?? item.entityId, ownerUid: uid ?? item.ownerUid,
                  opSeq: sequence ?? item.opSeq, operationId: operation ?? item.operationId, state: state);
              for (final mismatch in <void Function()>[
                () => exact(database: wrongDb), () => exact(row: 'other'),
                () => exact(type: 'settings'), () => exact(entity: 'other'),
                () => exact(uid: 'uid-b'), () => exact(sequence: item.opSeq + 1),
                () => exact(operation: '00000000-0000-0000-0000-000000000001'),
                () => ticket.requireExact(db, rowId: item.id, entityType: item.entityType,
                    entityId: item.entityId, ownerUid: item.ownerUid, opSeq: item.opSeq,
                    operationId: item.operationId, state: state == AccountFenceState.pending
                      ? AccountFenceState.gone : AccountFenceState.pending),
              ]) { expect(mismatch, throwsA(isA<StaleAdmissionException>())); }
              final parked = await queue.parkAccountDenial(item, state, ticket);
              expect(exact, throwsA(isA<StaleAdmissionException>()));
              return parked;
            });
        expect(result.accepted && result.parked && result.complete, isTrue);
        expect(() => saved!.requireExact(db, rowId: item.id, entityType: item.entityType,
            entityId: item.entityId, ownerUid: item.ownerUid, opSeq: item.opSeq,
            operationId: item.operationId, state: state), throwsA(isA<StaleAdmissionException>()));
      } finally { await wrongDb.close(); }
    });
  }

  for (final mode in ['parking', 'write', 'readback', 'executor-close']) {
    test('E4 accounts raw SDK denial $mode failure is truthful and restrictive', () async {
      _CloseFailure? controlled;
      if (mode == 'parking' || mode == 'executor-close') {
        await f.dispose();
        f = await F2Fixture.create(afterWithdraw: () async {}, opener: ({
          location, runMigrations = true, creation = const CreationPolicy.unrestricted(),
        }) async {
          await SecureDatabaseKeyStore(storageKey: location!.keyName,
              databaseExists: () => File(location.dbPath).exists(), creation: creation).readOrCreateKey();
          controlled = _CloseFailure(NativeDatabase(File(location.dbPath)), 'planning_sync_outbox');
          return AppDatabase.open(executor: controlled, location: location,
              runMigrations: runMigrations, creation: creation);
        });
        f.session.configureAccountScope(f.host); await f.signIn('uid-a');
      }
      final (queue, item) = await accountIntent();
      final db = f.host.current!.database;
      final location = f.host.current!.location!;
      final cap = f.session.captureLocalWorkAuthority()!;
      final before = (await db.customSelect('SELECT * FROM planning_sync_outbox;').getSingle()).data;
      var calls = 0; var written = false;
      f.storage.gate = (op, key) async {
        if (key != AccountFenceStore.storageKey) return;
        if (op == 'write') { written = true; if (mode == 'write') throw StateError('controlled write'); }
        if (op == 'read' && written && mode == 'readback') throw StateError('controlled readback');
      };
      controlled?.failClose = mode == 'executor-close'; controlled?.failParking = mode == 'parking';
      await Supabase.initialize(url: 'https://example.supabase.co', anonKey: 'anon',
          authOptions: const FlutterAuthClientOptions(autoRefreshToken: false,
              detectSessionInUri: false, localStorage: EmptyLocalStorage(),
              pkceAsyncStorage: _AccountSdkMemoryStorage()),
          httpClient: MockClient((request) async {
            calls++;
            return http.Response(jsonEncode({'code': 'QD002', 'message': 'raw refusal'}), 400,
                headers: {'content-type': 'application/json'}, request: request);
          }));
      try {
        AccountsDeliveryStopped? outcome;
        try {
          await AccountsPushService(db: db, queue: queue, isEnabled: () => true,
              getAuthUserId: () async => 'uid-a', mayEgress: () async => true).push();
        } on AccountsDeliveryStopped catch (error) { outcome = error; }
        expect(outcome, isNotNull); expect(outcome!.reason, AccountsDeliveryStopReason.denial);
        expect(outcome.accepted, isTrue); expect(outcome.parked, mode != 'parking');
        expect(outcome.complete, isFalse); expect(cap.isCurrent, isFalse); expect(calls, 1);
        expect(getAuthority().permits('uid-a'), isFalse);
        expect(f.storage.data[kMarkerKey], 'uid-a'); expect(await f.keyPresent('uid-a'), isTrue);
        expect(getAuthority().store.holdFor(AccountFenceStore.ownerDigest('uid-a'))?.state, AccountFenceState.gone);
        expect(item.operationId, before['operation_id']);
        if (mode == 'executor-close') {
          expect(db.lifecycleState, DatabaseLifecycleState.closing); expect(controlled!.closeAttempts, 1);
          final row = controlled!.lastParked!;
          expect(row['payload_json'], before['payload_json']); expect(row['operation_id'], before['operation_id']);
          expect(row['attempt_count'], 0); expect(row['status'], 'parked');
        } else {
          expect(db.lifecycleState, DatabaseLifecycleState.closed);
          final Map<String, Object?> row;
          if (mode == 'parking') {
            // The controlled opener uses plaintext SQLite, so inspection uses
            // that same executor after proving the captured file still exists.
            expect(File(location.dbPath).existsSync(), isTrue);
            expect(await f.keyPresent('uid-a'), isTrue);
            final inspection = await AppDatabase.open(location: location,
                executor: NativeDatabase(File(location.dbPath), enableMigrations: false),
                runMigrations: false, creation: const CreationPolicy.denied());
            try {
              row = (await inspection.customSelect('SELECT * FROM planning_sync_outbox;').getSingle()).data;
            } finally {
              await inspection.close();
              expect(inspection.lifecycleState, DatabaseLifecycleState.closed);
            }
          } else {
            row = await LedgerAdmissionFixture.inspectClosed(db, location,
                (inspection) async => (await inspection.customSelect('SELECT * FROM planning_sync_outbox;').getSingle()).data);
          }
          expect(row['payload_json'], before['payload_json']); expect(row['operation_id'], before['operation_id']);
          expect(row['attempt_count'], 0);
          expect(row['status'], mode == 'parking' ? 'pending' : 'parked');
          expect(row['in_flight_seq'], item.opSeq);
        }
        await expectLater(f.signIn('uid-a'), throwsA(isA<AccountFenceDeniedException>()));
      } finally {
        await Supabase.instance.dispose();
        if (mode == 'executor-close') await controlled!.delegate.close();
      }
    });
  }

  Future<(PlanningOutboxQueue, PlanningOutboxItem)> parentIntent({bool settings=false})async{
    final db=f.host.current!.database;
    final queue=PlanningOutboxQueue(db:db,isSyncEnabled:(_)=>true,getAuthUserId:()async=>'uid-a',getOwnerUid:f.session.readLocalDataOwnerUid);
    if(settings){
      final repository=DriftUserSettingsRepository(db);final previous=await repository.getSettings();
      await db.customStatement("UPDATE user_settings SET server_id='bound-settings' WHERE id='${previous.id}';");
      final off=await repository.saveSettings(previous.copyWith(cloudConsentState:ConsentState.declined,aiConsentState:ConsentState.declined));
      await PlanningOutboxQueue(db:db,isSyncEnabled:(_)=>true,getAuthUserId:()async=>'uid-a',getOwnerUid:()async=>null).enqueueSettings(PlanningSyncOperation.update,off,consentChanged:true,previous:previous);
    }else{
      await DriftCategoryRepository(db,outboxQueue:queue).createCategory(nameAr:'Parent exact',icon:'tag',color:'#000',isIncome:false);
    }
    return(queue,(await queue.pendingItems(entityType:settings?'settings':'category')).single);
  }

  test('E4 child closed nonNULL ticket exact fields reuse and settlement',()async{
    final db=f.host.current!.database;final a=getAuthority();final handle=await capture();
    final queue=PlanningOutboxQueue(db:db,isSyncEnabled:(_)=>true,getAuthUserId:()async=>'uid-a',getOwnerUid:f.session.readLocalDataOwnerUid);
    await queue.enqueuePlanLink(PlanningSyncOperation.create,planId:'local-plan',transactionId:'local-tx',createdAt:DateTime.utc(2026,10,1));
    final item=(await queue.pendingItems(entityType:'plan_transaction_link')).single;
    Future<AccountFenceChildIntent?> intent()=>a.captureChildIntent(handle,db,rowId:item.id,entityType:item.entityType,entityId:item.entityId,opSeq:item.opSeq,operationId:item.operationId!);
    for(final owner in <String?>[null,'foreign']){await db.customStatement('UPDATE planning_sync_outbox SET owner_uid=?;',[owner]);expect(await intent(),isNull);}
    await db.customStatement("UPDATE planning_sync_outbox SET owner_uid='uid-a';");
    final payload=Map<String,dynamic>.from(item.payloadJson);
    await db.customStatement('UPDATE planning_sync_outbox SET payload_json=?;',[jsonEncode({...payload,'local_transaction_id':'wrong'})]);expect(await intent(),isNull);
    await db.customStatement('UPDATE planning_sync_outbox SET payload_json=?;',[jsonEncode(payload)]);
    final captured=(await intent())!;
    final wrong=await AppDatabase.open(executor:NativeDatabase.memory());AccountFenceChildParking? saved;
    try{
      final result=await a.acceptChildDenial(handle,db,captured,AccountFenceState.pending,park:(ticket)async{
        saved=ticket;
        void exact({AppDatabase? database,String? row,String? type,String? entity,String? owner,int? seq,String? op,AccountFenceState? state})=>ticket.requireExact(database??db,rowId:row??item.id,entityType:type??item.entityType,entityId:entity??item.entityId,ownerUid:owner??item.ownerUid,opSeq:seq??item.opSeq,operationId:op??item.operationId,state:state??AccountFenceState.pending);
        for(final mismatch in <void Function()>[()=>exact(database:wrong),()=>exact(row:'other'),()=>exact(type:'settings'),()=>exact(entity:'other'),()=>exact(owner:'foreign'),()=>exact(seq:item.opSeq+1),()=>exact(op:'00000000-0000-0000-0000-000000000001'),()=>exact(state:AccountFenceState.gone)]){expect(mismatch,throwsA(isA<StaleAdmissionException>()));}
        final changed=await queue.parkChildDenial(item,AccountFenceState.pending,ticket);expect(exact,throwsA(isA<StaleAdmissionException>()));return changed;
      });
      expect(result.accepted&&result.parked&&result.complete,isTrue);expect(db.lifecycleState,DatabaseLifecycleState.closed);
      expect(()=>saved!.requireExact(db,rowId:item.id,entityType:item.entityType,entityId:item.entityId,ownerUid:item.ownerUid,opSeq:item.opSeq,operationId:item.operationId,state:AccountFenceState.pending),throwsA(isA<StaleAdmissionException>()));
      expect((await a.acceptChildDenial(handle,db,captured,AccountFenceState.pending,park:(_)async=>throw StateError('must not reuse'))).accepted,isFalse);
    }finally{await wrong.close();}
  });

  for(final settings in [false,true]){
    test('E4 parent closed ticket exact mismatch reuse NULL route=$settings',()async{
      final(queue,item)=await parentIntent(settings:settings);final db=f.host.current!.database;
      final handle=await capture();final a=getAuthority();
      Future<AccountFenceParentIntent?> ordinary()=>a.captureParentIntent(handle,db,rowId:item.id,entityType:item.entityType,entityId:item.entityId,opSeq:item.opSeq,operationId:item.operationId!);
      if(settings)expect(await ordinary(),isNull);
      await db.customStatement("UPDATE planning_sync_outbox SET owner_uid='foreign';");expect(await ordinary(),isNull);
      await db.customStatement('UPDATE planning_sync_outbox SET owner_uid=?;',[item.ownerUid]);
      final intent=(settings?await a.captureParentSettingsOffIntent(handle,db,rowId:item.id,entityId:item.entityId,opSeq:item.opSeq,operationId:item.operationId!):await ordinary())!;
      final wrong=await AppDatabase.open(executor:NativeDatabase.memory());AccountFenceParentParking? saved;
      try{
        final result=await a.acceptParentDenial(handle,db,intent,AccountFenceState.pending,park:(ticket)async{
          saved=ticket;
          void exact({AppDatabase? database,String? row,String? type,String? entity,String? owner,int? seq,String? op,AccountFenceState? state})=>ticket.requireExact(database??db,rowId:row??item.id,entityType:type??item.entityType,entityId:entity??item.entityId,ownerUid:owner??item.ownerUid,opSeq:seq??item.opSeq,operationId:op??item.operationId,state:state??AccountFenceState.pending);
          for(final mismatch in <void Function()>[()=>exact(database:wrong),()=>exact(row:'other'),()=>exact(type:'bill_payment'),()=>exact(entity:'other'),()=>exact(owner:'foreign'),()=>exact(seq:item.opSeq+1),()=>exact(op:'00000000-0000-0000-0000-000000000001'),()=>exact(state:AccountFenceState.gone)]){expect(mismatch,throwsA(isA<StaleAdmissionException>()));}
          final changed=await queue.parkParentDenial(item,AccountFenceState.pending,ticket);expect(exact,throwsA(isA<StaleAdmissionException>()));return changed;
        });
        expect(result.accepted&&result.parked&&result.complete,isTrue);
        expect(()=>saved!.requireExact(db,rowId:item.id,entityType:item.entityType,entityId:item.entityId,ownerUid:item.ownerUid,opSeq:item.opSeq,operationId:item.operationId,state:AccountFenceState.pending),throwsA(isA<StaleAdmissionException>()));
        expect((await a.acceptParentDenial(handle,db,intent,AccountFenceState.pending,park:(_)async=>throw StateError('reused callback'))).accepted,isFalse);
      }finally{await wrong.close();}
    });
  }

  for (final mode in ['parking', 'executor-close']) {
    test('E4 parent raw SDK denial $mode failure is truthful and restrictive', () async {
      _CloseFailure? controlled;
      if (mode == 'parking' || mode == 'executor-close') {
        await f.dispose();
        f = await F2Fixture.create(afterWithdraw: () async {}, opener: ({
          location, runMigrations = true, creation = const CreationPolicy.unrestricted(),
        }) async {
          await SecureDatabaseKeyStore(storageKey: location!.keyName,
              databaseExists: () => File(location.dbPath).exists(), creation: creation).readOrCreateKey();
          controlled = _CloseFailure(NativeDatabase(File(location.dbPath)), 'planning_sync_outbox');
          return AppDatabase.open(executor: controlled, location: location,
              runMigrations: runMigrations, creation: creation);
        });
        f.session.configureAccountScope(f.host); await f.signIn('uid-a');
      }
      final (queue, item) = await parentIntent();
      final db = f.host.current!.database;
      final location = f.host.current!.location!;
      final cap = f.session.captureLocalWorkAuthority()!;
      final before = (await db.customSelect('SELECT * FROM planning_sync_outbox;').getSingle()).data;
      var calls = 0; var written = false;
      f.storage.gate = (op, key) async {
        if (key != AccountFenceStore.storageKey) return;
        if (op == 'write') { written = true; if (mode == 'write') throw StateError('controlled write'); }
        if (op == 'read' && written && mode == 'readback') throw StateError('controlled readback');
      };
      controlled?.failClose = mode == 'executor-close'; controlled?.failParking = mode == 'parking';
      await Supabase.initialize(url: 'https://example.supabase.co', anonKey: 'anon',
          authOptions: const FlutterAuthClientOptions(autoRefreshToken: false,
              detectSessionInUri: false, localStorage: EmptyLocalStorage(),
              pkceAsyncStorage: _AccountSdkMemoryStorage()),
          httpClient: MockClient((request) async {
            calls++;
            return http.Response(jsonEncode({'code': 'QD002', 'message': 'raw refusal'}), 400,
                headers: {'content-type': 'application/json'}, request: request);
          }));
      try {
        PlanningDeliveryStopped? outcome;
        try {
          await PlanningPushService(db: db, queue: queue, isEnabled: (_) => true,
              getAuthUserId: () async => 'uid-a', mayEgress: () async => true, mayEgressProfile: () async => true).push();
        } on PlanningDeliveryStopped catch (error) { outcome = error; }
        expect(outcome, isNotNull); expect(outcome!.reason, PlanningDeliveryStopReason.denial);
        expect(outcome.accepted, isTrue); expect(outcome.parked, mode != 'parking');
        expect(outcome.complete, isFalse); expect(cap.isCurrent, isFalse); expect(calls, 1);
        expect(getAuthority().permits('uid-a'), isFalse);
        expect(f.storage.data[kMarkerKey], 'uid-a'); expect(await f.keyPresent('uid-a'), isTrue);
        expect(getAuthority().store.holdFor(AccountFenceStore.ownerDigest('uid-a'))?.state, AccountFenceState.gone);
        expect(item.operationId, before['operation_id']);
        if (mode == 'executor-close') {
          expect(db.lifecycleState, DatabaseLifecycleState.closing); expect(controlled!.closeAttempts, 1);
          final row = controlled!.lastParked!;
          expect(row['payload_json'], before['payload_json']); expect(row['operation_id'], before['operation_id']);
          expect(row['attempt_count'], 0); expect(row['status'], 'parked');
        } else {
          expect(db.lifecycleState, DatabaseLifecycleState.closed);
          final Map<String, Object?> row;
          if (mode == 'parking') {
            // The controlled opener uses plaintext SQLite, so inspection uses
            // that same executor after proving the captured file still exists.
            expect(File(location.dbPath).existsSync(), isTrue);
            expect(await f.keyPresent('uid-a'), isTrue);
            final inspection = await AppDatabase.open(location: location,
                executor: NativeDatabase(File(location.dbPath), enableMigrations: false),
                runMigrations: false, creation: const CreationPolicy.denied());
            try {
              row = (await inspection.customSelect('SELECT * FROM planning_sync_outbox;').getSingle()).data;
            } finally {
              await inspection.close();
              expect(inspection.lifecycleState, DatabaseLifecycleState.closed);
            }
          } else {
            row = await LedgerAdmissionFixture.inspectClosed(db, location,
                (inspection) async => (await inspection.customSelect('SELECT * FROM planning_sync_outbox;').getSingle()).data);
          }
          expect(row['payload_json'], before['payload_json']); expect(row['operation_id'], before['operation_id']);
          expect(row['attempt_count'], 0);
          expect(row['status'], mode == 'parking' ? 'pending' : 'parked');
          expect(row['in_flight_seq'], item.opSeq);
        }
        await expectLater(f.signIn('uid-a'), throwsA(isA<AccountFenceDeniedException>()));
      } finally {
        await Supabase.instance.dispose();
        if (mode == 'executor-close') await controlled!.delegate.close();
      }
    });
  }

  test('E4 authority replacement requires detach and never revives a prior handle', () async {
    final handle = await capture();
    expect(AccountFenceAuthority.replacePersistenceForTest, throwsStateError);
    await f.host.lock(); f.session.configureAccountScope(null);
    final restoreNested = AccountFenceAuthority.replacePersistenceForTest();
    restoreNested();
    f.session.configureAccountScope(f.host);
    await f.signIn('uid-a');
    expect((await getAuthority().accept(handle, AccountFenceState.gone, operationId: _op)).accepted, isFalse);
  });
}


class _CloseFailure extends QueryExecutor {
  _CloseFailure(this.delegate, [this.parkingTable = 'ledger_sync_outbox']);
  final String parkingTable;
  final QueryExecutor delegate;
  bool failClose = false;
  bool failParking = false;
  Map<String, Object?>? lastParked;
  int closeAttempts = 0;
  @override
  SqlDialect get dialect => delegate.dialect;
  @override
  Future<bool> ensureOpen(QueryExecutorUser user) => delegate.ensureOpen(user);
  @override
  Future<List<Map<String, Object?>>> runSelect(String statement, List<Object?> args) => delegate.runSelect(statement, args);
  @override
  Future<int> runInsert(String statement, List<Object?> args) => delegate.runInsert(statement, args);
  @override
  Future<int> runUpdate(String statement, List<Object?> args) async {
    if (failParking && statement.contains('account_deletion_')) throw StateError('controlled parking failure');
    final changed = await delegate.runUpdate(statement, args);
    if (statement.contains('account_deletion_')) {
      lastParked = (await delegate.runSelect('SELECT * FROM $parkingTable;', [])).single;
    }
    return changed;
  }
  @override
  Future<int> runDelete(String statement, List<Object?> args) => delegate.runDelete(statement, args);
  @override
  Future<void> runCustom(String statement, [List<Object?>? args]) => delegate.runCustom(statement, args);
  @override
  Future<void> runBatched(BatchedStatements statements) => delegate.runBatched(statements);
  @override
  TransactionExecutor beginTransaction() => delegate.beginTransaction();
  @override
  QueryExecutor beginExclusive() => delegate.beginExclusive();
  @override
  Future<void> close() async {
    closeAttempts++;
    if (failClose) throw StateError('executor close failure');
    await delegate.close();
  }
}

class _AccountSdkMemoryStorage extends GotrueAsyncStorage {
  const _AccountSdkMemoryStorage();
  @override
  Future<String?> getItem({required String key}) async => null;
  @override
  Future<void> setItem({required String key, required String value}) async {}
  @override
  Future<void> removeItem({required String key}) async {}
}
