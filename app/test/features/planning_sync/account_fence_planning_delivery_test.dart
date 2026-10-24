import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/domain/entities/category_entity.dart';
import 'package:money_companion/data/db/creation_policy.dart';
import 'package:money_companion/data/db/planning_cutover.dart';
import 'package:money_companion/data/sync/exact_transport_capability.dart';
import 'package:money_companion/data/repositories/drift_goal_repository.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:drift/drift.dart' show TransactionExecutor, QueryExecutor, QueryExecutorUser, SqlDialect, BatchedStatements;
import 'package:money_companion/core/privacy/consent_authority.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import '../../harness/egress_test_support.dart';
import 'dart:async';
import 'dart:io';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/core/sync/outbox_failure.dart';
import 'package:money_companion/core/sync/account_fence_retry.dart';
import 'package:money_companion/data/sync/revision_cas.dart';
import 'package:money_companion/data/sync/server_capabilities.dart';
import 'package:money_companion/data/sync/seq_pull.dart';
import 'package:money_companion/core/sync/sync_health.dart';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/session/account_fence_authority.dart';
import 'package:money_companion/core/session/account_fence_store.dart';
import 'package:money_companion/core/sync/conflict_resolver.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/repositories/drift_category_repository.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/planning_sync/services/accounts_pull_service.dart';
import 'package:money_companion/features/planning_sync/services/accounts_push_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_child_sync_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';
import 'package:money_companion/features/planning_sync/services/planning_pull_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_push_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_startup_registration_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_sync_engine.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../capture/ledger_admission_fixture.dart';

const _uid = 'user-planning';

Future<List<Map<String, Object?>>> _outbox(AppDatabase db) async => [
  for (final row in await db.customSelect('SELECT * FROM planning_sync_outbox ORDER BY id;').get()) row.data,
];

Future<Map<String, Object?>> _entity(AppDatabase db, bool settings, String id) async =>
    (await db.customSelect("SELECT server_id, server_updated_at, server_revision, "
        "sync_status, synced_at FROM ${settings ? 'user_settings' : 'categories'} WHERE id = '$id';").getSingle()).data;

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
            pkceAsyncStorage: _SdkMemoryStorage()),
        httpClient: MockClient((request) => respond(request)));
  });
  tearDownAll(() => Supabase.instance.dispose());

  Future<void> withParent(Future<void> Function(_ParentHarness) body,
      {bool settings = false, bool prebind = false, bool fullCreate = false,
       LedgerDatabaseProbe? probe}) async {
    final admission = await LedgerAdmissionFixture.open(_uid, probe);
    final h = _ParentHarness(admission, settings, probe);
    try {
      await h.seed(prebind: prebind, fullCreate: fullCreate);
      respond = (request) async { h.requests.add(request); return h.respond(request); };
      await body(h);
    } finally {
      for (final release in h.releases) { if (!release.isCompleted) release.complete(); }
      try { await Future.wait(h.producers); } finally { await admission.finish(); }
    }
  }

  for (final settings in [false, true]) {
    for (final outcome in ['QD001', 'QD002', 'success']) {
      test('E4 planning ${settings ? 'bound OFF NULL-owner settings' : 'category create'} $outcome real engine', () async {
        final admission = await LedgerAdmissionFixture.open(_uid);
        final db = admission.database;
        final location = admission.location;
        final requests = <http.Request>[];
        final downstream = _Downstream();
        try {
          PlanningOutboxQueue queue({bool legacyNull = false}) => PlanningOutboxQueue(
              db: db, isSyncEnabled: (_) => true, getAuthUserId: () async => _uid,
              getOwnerUid: legacyNull ? () async => null
                  : admission.fixture.session.readLocalDataOwnerUid);
          late String localId;
          if (settings) {
            final repository = DriftUserSettingsRepository(db);
            final current = await repository.getSettings();
            localId = current.id;
            await db.customStatement("UPDATE user_settings SET server_id = 'server-settings' WHERE id = '$localId';");
            final off = await repository.saveSettings(current.copyWith(displayName: 'Synthetic private profile',
                cloudConsentState: ConsentState.declined, aiConsentState: ConsentState.declined));
            expect(await queue(legacyNull: true).enqueueSettings(PlanningSyncOperation.update, off,
                consentChanged: true, previous: current), isTrue);
          } else {
            final category = await DriftCategoryRepository(db, outboxQueue: queue()).createCategory(
                nameAr: 'Synthetic category', icon: 'tag', color: '#123456', isIncome: false);
            localId = category.id;
          }
          final before = (await _outbox(db)).single;
          final entityBefore = await _entity(db, settings, localId);
          final cap = admission.fixture.session.captureLocalWorkAuthority()!;
          expect(cap.isCurrent, isTrue);
          expect(await admission.fixture.session.readLocalDataOwnerUid(), _uid);
          expect(admission.fixture.host.current?.uid, _uid);
          expect(before['owner_uid'], settings ? isNull : equals(_uid));
          expect(before['operation_id'], isA<String>()); expect(before['attempt_count'], 0);
          if (settings) {
            final payload = jsonDecode(before['payload_json'] as String) as Map;
            expect(payload['display_name'], 'Synthetic private profile');
            expect(payload['consent_only'], isNot(true));
          }
          respond = (request) async {
            requests.add(request);
            expect(request.method, settings ? 'PATCH' : 'POST');
            expect(request.url.path, settings ? '/rest/v1/user_settings' : '/rest/v1/user_categories');
            final body = jsonDecode(request.body) as Map;
            if (settings) {
              expect(body, {'ai_consent_granted': false, 'cloud_processing_enabled': false});
              expect(request.url.queryParameters['id'], 'eq.server-settings');
              expect((await _outbox(db)).single['owner_uid'], isNull,
                  reason: 'legacy row provenance is not the request admission owner');
            } else {
              expect(body['user_id'], _uid); expect(body['local_id'], localId);
              expect(body['name_ar'], 'Synthetic category');
            }
            if (outcome != 'success') {
              return http.Response(jsonEncode({'code': outcome, 'message': 'typed refusal'}), 400,
                  headers: {'content-type': 'application/json'}, request: request);
            }
            final row = {'id': settings ? 'server-settings' : 'server-category',
                'updated_at': '2026-10-01T00:00:00Z'};
            return http.Response(jsonEncode(settings ? [row] : row), 200,
                headers: {'content-type': 'application/json'}, request: request);
          };
          final deliveryQueue = queue();
          final planning = PlanningPushService(db: db, queue: deliveryQueue,
              isEnabled: (_) => true, getAuthUserId: () async => _uid,
              remoteSink: const SupabasePlanningRemoteSink(),
              mayEgress: () async => !settings, mayEgressProfile: () async => !settings);
          final engine = PlanningSyncEngine(
              // This real account service binds the engine but never reaches
              // its shared-queue ownership reconciliation preflight.
              accountsPushService: AccountsPushService(db: db, queue: deliveryQueue,
                  isEnabled: () => false, getAuthUserId: () async => _uid,
                  mayEgress: () async => true),
              accountsPullService: _AccountsPull(downstream), planningPushService: planning,
              planningPullService: _PlanningPull(downstream),
              planningChildSyncService: _Children(downstream),
              startupRegistrationService: _Registration(downstream),
              conflictResolver: _Conflicts(downstream));
          await engine.sync();
          if (outcome == 'success') {
            expect(requests, hasLength(1)); expect(cap.isCurrent, isTrue);
            expect(downstream.calls, {'account-pull': 1, 'conflict': 1,
                'planning-pull': 1, 'registration': 1, 'children': 1});
            expect(downstream.settingsCompleted, [true]);
            if (settings) {
              final retained = (await _outbox(db)).single;
              expect(_intent(retained), _intent(before)); expect(retained['owner_uid'], isNull);
              expect(retained['status'], 'pending'); expect(retained['attempt_count'], 0);
              expect(retained['in_flight_seq'], before['op_seq']);
              expect(await _entity(db, settings, localId), entityBefore,
                  reason: 'narrow OFF acknowledgement cannot consume or bind full profile intent');
            } else {
              expect(await _outbox(db), isEmpty);
              final entity = await _entity(db, settings, localId);
              expect(entity['server_id'], 'server-category'); expect(entity['sync_status'], 'synced');
              expect(entity['synced_at'], isNotNull);
            }
          } else {
            expect(cap.isCurrent, isFalse, reason: 'raw current planning denial must retire original authority');
            expect(requests, hasLength(1));
            expect(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(_uid))?.state,
                outcome == 'QD001' ? AccountFenceState.pending : AccountFenceState.gone);
            expect(db.lifecycleState, DatabaseLifecycleState.closed);
            final retained = (await LedgerAdmissionFixture.inspectClosed(db, location, _outbox)).single;
            expect(_intent(retained), _intent(before)); expect(retained['attempt_count'], 0);
            expect(retained['status'], 'parked');
            expect(retained['failure_class'], outcome == 'QD001'
                ? 'account_deletion_pending' : 'account_deletion_gone');
            expect(retained['owner_uid'], settings ? isNull : equals(_uid));
            expect(await LedgerAdmissionFixture.inspectClosed(db, location,
                (inspection) => _entity(inspection, settings, localId)), entityBefore);
            expect(downstream.calls, {'account-pull': 1},
                reason: 'no conflict/pull/registration/children after planning refusal');
          }
        } finally { await admission.finish(); }
      });
    }
  }

  for (final prebind in [false, true]) {
    test('E4 parent ${prebind ? 'prebind consent-only no-bind' : 'bound full CREATE OFF retain'} positive', () async {
      await withParent((h) async {
        final before = (await _outbox(h.db)).single;
        final entity = await _entity(h.db, true, h.id);
        h.respond = (request) async {
          final payload = jsonDecode(request.body) as Map;
          expect((await _outbox(h.db)).single['owner_uid'], isNull);
          if (prebind) {
            expect(payload.keys.toSet(), {'user_id','local_id','ai_consent_granted',
                'cloud_processing_enabled','consent_version'});
            expect(payload['user_id'], _uid); expect(payload['local_id'], 'user_settings');
            expect(payload['ai_consent_granted'], isFalse); expect(payload['cloud_processing_enabled'], isFalse);
          } else {
            expect(payload, {'ai_consent_granted': false, 'cloud_processing_enabled': false});
          }
          return h.reply(request, 'success');
        };
        await h.service().push();
        expect(h.requests, hasLength(1));
        expect(await _entity(h.db, true, h.id), entity);
        if (prebind) { expect(await _outbox(h.db), isEmpty); expect(entity['server_id'], isNull); }
        else {
          final row = (await _outbox(h.db)).single;
          expect(_intent(row), _intent(before)); expect(row['operation'], 'create');
          expect(row['owner_uid'], isNull); expect(row['status'], 'pending');
        }
      }, settings: true, prebind: prebind, fullCreate: !prebind);
    });
  }

  test('E4 parent prebind raw denial retires and retains NULL provenance', () async {
    await withParent((h) async {
      final db = h.db; final location = h.admission.location;
      final before = (await _outbox(db)).single;
      h.respond = (r) async => h.reply(r, 'QD002');
      final result = await _parentStop(h.service().push());
      expect(result.accepted && result.parked && result.complete, isTrue);
      final row = (await LedgerAdmissionFixture.inspectClosed(db, location, _outbox)).single;
      expect(_intent(row), _intent(before)); expect(row['owner_uid'], isNull);
    }, settings: true, prebind: true);
  });

  for (final scenario in [
    (settings: false, successor: _uid, response: 'success'),
    (settings: false, successor: 'user-B', response: '409'),
    (settings: true, successor: _uid, response: 'QD001'),
    (settings: true, successor: 'user-B', response: 'success'),
  ]) {
    test('E4 parent stale ${scenario.response} OFF=${scenario.settings} successor=${scenario.successor}', () async {
      await withParent((h) async {
        final reached = Completer<void>(); final release = h.release();
        h.respond = (request) async { reached.complete(); await release.future; return h.reply(request, scenario.response); };
        final db = h.db; final location = h.admission.location;
        final running = h.track(_parentStop(h.service().push())); await reached.future;
        final rows = await _outbox(db); final entity = await _entity(db, h.settings, h.id);
        final conflicts = await _parentConflicts(db);
        await h.admission.fixture.signIn(scenario.successor);
        final scope = h.admission.fixture.host.current;
        final cap = h.admission.fixture.session.captureLocalWorkAuthority()!;
        release.complete(); final result = await running;
        expect(result.accepted || result.parked || result.complete, isFalse);
        expect(identical(h.admission.fixture.host.current, scope), isTrue); expect(cap.isCurrent, isTrue);
        Future<T> read<T>(Future<T> Function(AppDatabase) f) => db.lifecycleState == DatabaseLifecycleState.closed
            ? LedgerAdmissionFixture.inspectClosed(db, location, f) : f(db);
        expect(await read(_outbox), rows);
        expect(await read((db) => _entity(db, h.settings, h.id)), entity);
        expect(await read(_parentConflicts), conflicts); expect(h.requests, hasLength(1));
      }, settings: scenario.settings);
    });
  }

  test('E4 parent already-bound account phase unreadiness still accepts raw denial', () async {
    await withParent((h) async {
      final reached = Completer<void>(); final release = h.release();
      h.respond = (r) async { reached.complete(); await release.future; return h.reply(r, 'QD001'); };
      final phase = SyncPhaseBinding();
      await AccountsPushService(db: h.db, queue: h.queue, isEnabled: () => false,
          getAuthUserId: () async => _uid, mayEgress: () async => true).pushWithPhase(phase);
      final running = h.track(_parentStop(h.service().pushWithPhase(phase.forNextPhase())));
      await reached.future;
      final hold = h.admission.fixture.storage.holdOnce((op, key) => op == 'read' && key == AccountFenceStore.storageKey);
      h.releases.add(hold.release);
      final loading = h.track(AccountFenceAuthority.shared.initialize()); await hold.reached.future;
      expect(phase.isCurrent, isFalse);
      final retired = Completer<void>();
      void listener() {
        if (AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(_uid)) != null &&
            !retired.isCompleted) { retired.complete(); }
      }
      h.admission.fixture.session.addListener(listener);
      try {
        release.complete();
        expect(await Future.any([retired.future.then((_) => true), running.then((_) => false)]), isTrue);
      } finally { h.admission.fixture.session.removeListener(listener); hold.release.complete(); }
      final result = await running; await loading;
      expect(result.accepted && result.parked && result.complete, isTrue);
    });
  });

  for (final settings in [false, true]) {
    test('E4 parent concrete busy retry stable body OFF=$settings', () async {
      await withParent((h) async {
        h.respond = (r) async => h.reply(r, h.requests.length == 1 ? '55P03' : 'success');
        await h.service(retry: AccountFenceRetry(delay: (_) async {})).push();
        expect(h.requests, hasLength(2)); expect(h.requests.first.body, h.requests.last.body);
        expect(identical(h.requests.first, h.requests.last), isFalse);
      }, settings: settings);
    });
  }

  for (final settings in [false, true]) {
    test('E4 parent final actual queue-read currency prevents mutation OFF=$settings', () async {
      final probe = LedgerDatabaseProbe();
      await withParent((h) async {
        final handle = (await AccountFenceAuthority.shared.capture(h.admission.fixture.session, h.admission.fixture.host))!;
        final reached = Completer<void>(); final done = Completer<void>(); h.releases.add(done);
        probe.afterSelect = (sql) async {
          if (sql.startsWith('SELECT 1 FROM planning_sync_outbox') && sql.contains('in_flight_seq') && !reached.isCompleted) {
            reached.complete(); h.track(AccountFenceAuthority.shared.accept(handle, AccountFenceState.pending,
                operationId: '00000000-0000-0000-0000-000000000001').then((result) {
                  if (!done.isCompleted) done.complete(); return result;
                }));
          }
        };
        final running = h.track(_parentStop(h.service().push()));
        expect(await Future.any([reached.future.then((_) => true), running.then((_) => false)]), isTrue);
        await running; await done.future; expect(h.requests, isEmpty);
      }, settings: settings, probe: probe);
    });
  }

  for (final operation in ['create', 'delete']) {
    test('E4 parent actual CAS category $operation', () async {
      await withParent((h) async {
        if (operation == 'delete') {
          await h.db.customStatement("UPDATE categories SET server_id = 'server-parent', server_revision = 5 WHERE id = '${h.id}';");
          await h.db.customStatement("UPDATE planning_sync_outbox SET operation = 'delete', base_revision = 5;");
        }
        final before = (await _outbox(h.db)).single;
        h.respond = (request) async {
          expect(request.url.path, operation == 'create' ? '/rest/v1/rpc/sync_insert_if_absent'
              : '/rest/v1/rpc/sync_cas_tombstone_category');
          final body = jsonDecode(request.body) as Map;
          expect(body['p_op_id'], before['operation_id']); expect(body['p_expected_epoch'], 'e1');
          return http.Response(jsonEncode({'outcome': operation == 'create' ? 'inserted' : 'applied',
              'row': {'id': 'server-parent','updated_at':'2026-10-01T00:00:00Z','revision':6}}),200,
              headers: {'content-type':'application/json'},request:request);
        };
        final result = await h.service(gate: RevisionCasGate(db:h.db,
            capability:() async => ServerCapabilityState.verified, remote:_ParentHead())).push();
        expect(result.pushed,1); expect(await _outbox(h.db),isEmpty); expect(h.requests,hasLength(1));
      });
    });
  }

  test('E4 parent service overlap refuses without replacing first lifetime', () async {
    await withParent((h) async {
      final reached=Completer<void>(); final release=h.release();
      h.respond=(r)async{reached.complete();await release.future;return h.reply(r,'success');};
      final service=h.service();final first=h.track(service.push());await reached.future;
      expect((await _parentStop(service.push())).reason,PlanningDeliveryStopReason.overlap);
      release.complete();expect((await first).pushed,1);expect(h.requests,hasLength(1));
    });
  });


  test('E4 parent real persisted consent refusal cannot authorize ordinary full settings retry', () async {
    final oldGate=CloudEgressGate.instance;
    final egress=TestEgress().install()..owner=_uid;
    try {
      await egress.gate.enable(owner:_uid,reservedVersion:1);
      await withParent((h)async{
        final repository=DriftUserSettingsRepository(h.db);
        await repository.saveSettings((await repository.getSettings()).copyWith(
            cloudConsentState:ConsentState.accepted,aiConsentState:ConsentState.accepted));
        final consent=ConsentAuthority(repository.getSettings);
        expect(await consent.allows(EgressClass.profileAndSettings),isTrue);
        final cap=h.admission.fixture.session.captureLocalWorkAuthority()!;
        final reached=Completer<void>();final release=h.release();var auth=0;
        final service=PlanningPushService(db:h.db,queue:h.queue,isEnabled:(_)=>true,
            getAuthUserId:()async{if(++auth==2){reached.complete();await release.future;}return _uid;},
            mayEgress:()=>consent.allows(EgressClass.financialSync),
            mayEgressProfile:()=>consent.allows(EgressClass.profileAndSettings));
        final running=h.track(service.push());
        expect(await Future.any([reached.future.then((_)=>true),running.then((_)=>false)]),isTrue);
        final beforeDecline=List<http.Request>.of(h.requests);
        expect(beforeDecline,hasLength(1));
        expect(beforeDecline.single.method,'GET');
        expect(beforeDecline.single.url.path,'/rest/v1/user_settings');
        expect(beforeDecline.single.url.queryParameters,{'select':'updated_at','id':'eq.server-settings'});
        final handed=(await _outbox(h.db)).single;
        expect(handed['owner_uid'],_uid);expect(handed['in_flight_seq'],handed['op_seq']);
        await repository.saveSettings((await repository.getSettings()).copyWith(
            cloudConsentState:ConsentState.declined,aiConsentState:ConsentState.declined));
        expect(cap.isCurrent,isTrue);
        expect((await _outbox(h.db)).single,handed);
        final entityAfterDecline=await _entity(h.db,true,h.id);
        expect(await consent.allows(EgressClass.profileAndSettings),isFalse);
        release.complete();await running;
        expect(h.requests,beforeDecline,reason:'Fresh refusal permits no additional HTTP after the prior base read');
        expect((await _outbox(h.db)).single,handed);
        expect(await _entity(h.db,true,h.id),entityAfterDecline);
        expect(cap.isCurrent,isTrue);
        expect(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(_uid)),isNull);
      },settings:true);
    } finally {CloudEgressGate.instance=oldGate;}
  });


  test('E4 parent registration rebuilds payload after held candidate read',()async{
    final probe=LedgerDatabaseProbe();
    await withParent((h)async{
      await h.db.customStatement('DELETE FROM planning_sync_outbox;');
      final eligible=await DriftCategoryRepository(h.db).createCategory(nameAr:'eligible registration',icon:'tag',color:'#000',isIncome:false);
      final reached=Completer<void>();final release=h.release();
      probe.afterSelect=(sql)async{if(sql.startsWith('SELECT id FROM categories')&&!reached.isCompleted){reached.complete();await release.future;}};
      final running=h.track(PlanningStartupRegistrationService(db:h.db,queue:h.queue,isEnabled:(_)=>true).registerMissingRows(settingsPullCompleted:false));
      expect(await Future.any([reached.future.then((_)=>true),running.then((_)=>false)]),isTrue);
      await h.db.customStatement("UPDATE categories SET name_ar='current payload' WHERE id='${eligible.id}';");
      release.complete();await running;
      final row=(await _outbox(h.db)).single;
      expect((jsonDecode(row['payload_json'] as String)as Map)['name_ar'],'current payload');expect(row['owner_uid'],_uid);
    },probe:probe);
  });

  test('E4 parent registration first enqueue drains and prevents next row',()async{
    await withParent((h)async{
      await h.db.customStatement('DELETE FROM planning_sync_outbox;');
      await DriftCategoryRepository(h.db).createCategory(nameAr:'second',icon:'tag',color:'#000',isIncome:false);
      final handle=(await AccountFenceAuthority.shared.capture(h.admission.fixture.session,h.admission.fixture.host))!;
      var callbacks=0;Future<AccountFenceResult>? denied;
      final queue=PlanningOutboxQueue(db:h.db,isSyncEnabled:(_)=>true,getAuthUserId:()async=>_uid,
          getOwnerUid:h.admission.fixture.session.readLocalDataOwnerUid,onQueued:(){
        if(++callbacks==1) { denied=h.track(AccountFenceAuthority.shared.accept(handle,AccountFenceState.pending,
            operationId:'00000000-0000-0000-0000-000000000001')); }
      });
      final db=h.db;final location=h.admission.location;
      final result=await _parentStop(PlanningStartupRegistrationService(db:db,queue:queue,isEnabled:(_)=>true).registerMissingRows(settingsPullCompleted:false));
      expect(result.reason,PlanningDeliveryStopReason.stale);expect((await denied!).complete,isTrue);expect(callbacks,1);
      expect(await LedgerAdmissionFixture.inspectClosed(db,location,_outbox),hasLength(1));
    });
  });

  test('E4 parent dependency atomic read drains before close without next dispatch',()async{
    final probe=LedgerDatabaseProbe();
    await withParent((h)async{
      await h.db.customStatement("UPDATE planning_sync_outbox SET status='parked',failure_class='dependency_wait';");
      final reached=Completer<void>();final release=h.release();var terminal=false;var early=false;
      probe.before=(sql)async{if(sql.startsWith('SELECT entity_type, entity_id, payload_json')&&!reached.isCompleted){reached.complete();await release.future;}};
      final handle=(await AccountFenceAuthority.shared.capture(h.admission.fixture.session,h.admission.fixture.host))!;
      final running=h.track(_parentStop(h.service().push()));
      expect(await Future.any([reached.future.then((_)=>true),running.then((_)=>false)]),isTrue);
      expect(probe.transactionStatements.any((sql)=>sql.startsWith('SELECT entity_type, entity_id, payload_json')),isTrue);
      probe.afterTransactionSettled=()=>terminal=true;probe.onClose=(){if(!terminal)early=true;};
      final denied=h.track(AccountFenceAuthority.shared.accept(handle,AccountFenceState.pending,operationId:'00000000-0000-0000-0000-000000000001'));
      expect(probe.closeAttempts,0);release.complete();await running;await denied;
      expect(terminal,isTrue);expect(early,isFalse);expect(h.requests,isEmpty);
    },probe:probe);
  });

  test('E4 parent tracked health save drains before close',()async{
    final probe=LedgerDatabaseProbe();
    await withParent((h)async{
      final phase=SyncPhaseBinding();
      await AccountsPushService(db:h.db,queue:h.queue,isEnabled:()=>false,getAuthUserId:()async=>_uid,mayEgress:()async=>true).pushWithPhase(phase);
      final handle=(await AccountFenceAuthority.shared.capture(h.admission.fixture.session,h.admission.fixture.host))!;
      final health=SyncHealth(db:h.db);final reached=Completer<void>();final release=h.release();
      probe.before=(sql)async{if(sql.contains('INSERT INTO sync_cursors')&&sql.contains('sync_health:planning')&&!reached.isCompleted){reached.complete();await release.future;}};
      final own=phase.forNextPhase();
      final running=h.track(health.runPhase(SyncDomain.planning,SyncDirection.push,()=>h.service(health:health).pushWithPhase(own),binding:own));
      expect(await Future.any([reached.future.then((_)=>true),running.then((_)=>false)]),isTrue);
      final denied=h.track(AccountFenceAuthority.shared.accept(handle,AccountFenceState.pending,operationId:'00000000-0000-0000-0000-000000000001'));
      expect(probe.closeAttempts,0);release.complete();await running;expect((await denied).complete,isTrue);expect(phase.isCurrent,isFalse);
    },probe:probe);
  });

  for(final boundary in ['capability','recorded','head']){
    test('E4 parent Gate held $boundary refuses replacement',()async{
      final probe=LedgerDatabaseProbe();
      await withParent((h)async{
        final reached=Completer<void>();final release=h.release();
        final handle=(await AccountFenceAuthority.shared.capture(h.admission.fixture.session,h.admission.fixture.host))!;
        probe.before=(sql)async{if(boundary=='recorded'&&sql.startsWith('SELECT last_updated_at')&&sql.contains('seq_epoch:')&&!reached.isCompleted){reached.complete();await release.future;}};
        final gate=RevisionCasGate(db:h.db,capability:()async{if(boundary=='capability'){reached.complete();await release.future;}return ServerCapabilityState.verified;},remote:_ControlledParentHead(()async{if(boundary=='head'){reached.complete();await release.future;}return const SyncHead(lastSeq:1,epoch:'e1');}));
        final running=h.track(gate.planForPlanningParent(_uid,authority:AccountFenceAuthority.shared,handle:handle,database:h.db).then<Object?>((v)=>v,onError:(Object e)=>e));
        expect(await Future.any([reached.future.then((_)=>true),running.then((_)=>false)]),isTrue);
        final successor=h.track(h.admission.fixture.signIn(boundary=='head'?_uid:'user-B'));
        release.complete();expect(await running,anyOf(isA<PlanningDeliveryStopped>(),isA<StaleAdmissionException>()));await successor;
        expect(h.admission.fixture.session.captureLocalWorkAuthority()!.isCurrent,isTrue);expect(h.requests,isEmpty);
      },probe:probe);
    });
  }

  for(final replacedHolder in [false,true]) {
    test('E4 parent zero-row tombstone state conflict exact holder replaced=$replacedHolder',()async{
      await withParent((h)async{
        await h.db.customStatement("UPDATE categories SET server_id='server-parent', server_updated_at='2026-09-01T00:00:00Z', deleted_at='2026-09-02T00:00:00Z' WHERE id='${h.id}';");
        final original=(await _outbox(h.db)).single;
        final payload=jsonDecode(original['payload_json'] as String) as Map<String,dynamic>;
        payload['server_updated_at']='2026-09-01T00:00:00Z';
        await h.db.customStatement("UPDATE planning_sync_outbox SET operation='delete',payload_json=?;",[jsonEncode(payload)]);
        Map<String,Object?>? retained;Map<String,Object?>? entity;
        h.respond=(r)async{
          if(r.method=='PATCH')return http.Response('[]',200,headers:{'content-type':'application/json'},request:r);
          expect(r.method,'GET');expect(r.url.queryParameters['select'],contains('deleted_at'));
          if(replacedHolder){
            await h.db.customStatement('UPDATE planning_sync_outbox SET in_flight_seq=NULL;');
            retained=(await _outbox(h.db)).single;entity=await _entity(h.db,false,h.id);
          }
          return http.Response(jsonEncode({'id':'server-parent','updated_at':'2026-10-01T00:00:00Z','deleted_at':null}),200,headers:{'content-type':'application/json'},request:r);
        };
        final result=await h.service().push();
        expect(h.requests.map((r)=>r.method),['PATCH','GET']);
        if(replacedHolder){
          expect((await _outbox(h.db)).single,retained);
          expect(await _entity(h.db,false,h.id),entity);
          expect(await _parentConflicts(h.db),isEmpty);
        }else{
          expect(result.conflicts,1);expect(await _outbox(h.db),isEmpty);
          expect((await _entity(h.db,false,h.id))['sync_status'],'conflict');
        }
      });
    });
  }

  test('E4 parent captured prebind route refuses later local binding',()async{
    final probe=LedgerDatabaseProbe();
    await withParent((h)async{
      final reached=Completer<void>();final release=h.release();
      probe.before=(sql)async{if(sql.startsWith('SELECT server_id FROM user_settings')&&!reached.isCompleted){reached.complete();await release.future;}};
      final running=h.track(h.service().push().then<Object?>((v)=>v,onError:(Object e)=>e));
      expect(await Future.any([reached.future.then((_)=>true),running.then((_)=>false)]),isTrue);
      final handed=(await _outbox(h.db)).single;
      await h.db.customStatement("UPDATE user_settings SET server_id='newly-bound' WHERE id='${h.id}';");
      final entity=await _entity(h.db,true,h.id);
      release.complete();
      expect(await running,isA<PlanningDeliveryStopped>().having((e)=>e.reason,'reason',PlanningDeliveryStopReason.provenance));
      expect(h.requests,isEmpty);expect((await _outbox(h.db)).single,handed);
      expect(await _entity(h.db,true,h.id),entity);
    },settings:true,prebind:true,probe:probe);
  });

  for(final failCommit in [false,true]){
    test('E4 parent registration notifies only committed current enqueue failure=$failCommit',()async{
      final probe=_ParentCommitProbe();
      await withParent((h)async{
        await h.db.customStatement('DELETE FROM planning_sync_outbox;');
        await DriftCategoryRepository(h.db).createCategory(nameAr:'notify eligible',icon:'tag',color:'#000',isIncome:false);
        var committed=false;var calls=0;var early=false;var inserts=0;
        probe.onOuterCommit=()=>committed=true;
        probe.before=(sql)async{if(sql.contains('INSERT INTO planning_sync_outbox')){inserts++;committed=false;}
          if(failCommit&&sql.startsWith('UPDATE categories SET sync_status'))throw StateError('controlled enqueue rollback');};
        final queue=PlanningOutboxQueue(db:h.db,isSyncEnabled:(_)=>true,getAuthUserId:()async=>_uid,
          getOwnerUid:h.admission.fixture.session.readLocalDataOwnerUid,onQueued:(){calls++;if(!committed)early=true;});
        final work=PlanningStartupRegistrationService(db:h.db,queue:queue,isEnabled:(_)=>true).registerMissingRows(settingsPullCompleted:false);
        if(failCommit){await expectLater(work,throwsStateError);expect(calls,0);expect(await _outbox(h.db),isEmpty);}
        else{await work;expect(calls,1);expect(early,isFalse);expect(committed,isTrue);expect(await _outbox(h.db),hasLength(1));}
        expect(inserts,greaterThan(0),reason:'the actual target outbox INSERT reset the commit oracle');
      },probe:probe);
    });
  }

  test('E4 parent busy then denial stops later queued parent intent and restart',()async{
    await withParent((h)async{
      await DriftCategoryRepository(h.db,outboxQueue:h.queue).createCategory(nameAr:'later parent',icon:'tag',color:'#000',isIncome:false);
      final db=h.db;final location=h.admission.location;final before=await _outbox(db);
      h.respond=(r)async=>h.reply(r,h.requests.length==1?'55P03':'QD001');
      final result=await _parentStop(h.service(retry:AccountFenceRetry(delay:(_)async{})).push());
      expect(result.accepted&&result.parked&&result.complete,isTrue);expect(h.requests,hasLength(2));
      expect(h.requests.first.body,h.requests.last.body);
      final rows=await LedgerAdmissionFixture.inspectClosed(db,location,_outbox);
      final sent=jsonDecode(h.requests.first.body)as Map;
      final refused=rows.firstWhere((r)=>r['entity_id']==sent['local_id']);
      final later=rows.firstWhere((r)=>r['entity_id']!=sent['local_id']);
      expect(refused['status'],'parked');expect(refused['attempt_count'],0);
      expect(_intent(refused),_intent(before.firstWhere((r)=>r['id']==refused['id'])));
      expect(later['status'],'pending');expect(later['attempt_count'],0);expect(later['in_flight_seq'],later['op_seq']);
      await expectLater(h.admission.fixture.signIn(_uid),throwsA(isA<AccountFenceDeniedException>()));
      expect(h.requests,hasLength(2));
    });
  });

  for(final cut in [false,true]){
    test('E4 parent SDK partial-index replay next guarded mutation cut=$cut',()async{
      await withParent((h)async{
        await h.seedGoal();
        final reached=Completer<void>();final release=h.release();
        h.respond=(r)async{
          if(r.method=='POST')return h.reply(r,'23505');
          if(r.method=='GET'){
            reached.complete();if(cut)await release.future;
            return http.Response(jsonEncode({'id':'server-replay','updated_at':'2026-09-01T00:00:00Z'}),200,headers:{'content-type':'application/json'},request:r);
          }
          expect(r.method,'PATCH');return h.reply(r,'success');
        };
        final running=h.track(h.service().push().then<Object?>((v)=>v,onError:(Object e)=>e));
        expect(await Future.any([reached.future.then((_)=>true),running.then((_)=>false)]),isTrue);
        if(cut){
          final rows=await _outbox(h.db);final entity=await h.goalState();
          await h.admission.fixture.signIn(_uid);release.complete();
          expect(await running,isA<PlanningDeliveryStopped>());expect(h.requests.map((r)=>r.method),['POST','GET']);
          expect(await _outbox(h.db),rows);expect(await h.goalState(),entity);
        }else{
          expect(await running,isA<PlanningPushResult>().having((v)=>v.pushed,'pushed',1));
          expect(h.requests.map((r)=>r.method),['POST','GET','PATCH']);expect(await _outbox(h.db),isEmpty);
        }
      });
    });
  }

  test('E4 parent engine original channel stops after held successful health save',()async{
    final probe=LedgerDatabaseProbe();
    await withParent((h)async{
      final reached=Completer<void>();final release=h.release();final effects=_Downstream();
      final handle=(await AccountFenceAuthority.shared.capture(h.admission.fixture.session,h.admission.fixture.host))!;
      probe.before=(sql)async{if(sql.contains('INSERT INTO sync_cursors')&&sql.contains('sync_health:planning')&&!reached.isCompleted){reached.complete();await release.future;}};
      final health=SyncHealth(db:h.db);
      final engine=PlanningSyncEngine(accountsPushService:AccountsPushService(db:h.db,queue:h.queue,isEnabled:()=>false,getAuthUserId:()async=>_uid,mayEgress:()async=>true),
        accountsPullService:_AccountsPull(effects),planningPushService:h.service(health:health),planningPullService:_PlanningPull(effects),planningChildSyncService:_Children(effects),startupRegistrationService:_Registration(effects),conflictResolver:_Conflicts(effects),health:health);
      final running=h.track(engine.sync());
      expect(await Future.any([reached.future.then((_)=>true),running.then((_)=>false)]),isTrue);
      final denied=h.track(AccountFenceAuthority.shared.accept(handle,AccountFenceState.pending,operationId:'00000000-0000-0000-0000-000000000001'));
      expect(probe.closeAttempts,0);release.complete();await running;expect((await denied).complete,isTrue);
      expect(effects.calls,{'account-pull':1});expect(h.requests,hasLength(1));
    },probe:probe);
  });

  for(final replace in [false,true]){
    test('E4 parent capability parking retains exact NULL holder replace=$replace',()async{
      final probe=LedgerDatabaseProbe();
      await withParent((h)async{
        await h.seedGoal();final before=(await _outbox(h.db)).single;final reached=Completer<void>();Future<void>? replaced;
        var checks=0;
        final service=PlanningPushService(db:h.db,queue:h.queue,isEnabled:(_)=>true,getAuthUserId:()async=>_uid,
          mayEgress:()async=>true,mayEgressProfile:()async=>true,
          coordinator:const FixedPlanningCutoverCoordinator(PlanningCutoverState.canonical),
          pushCapability:(){if(++checks==2&&replace){replaced=h.track(h.db.customStatement('UPDATE planning_sync_outbox SET in_flight_seq=NULL;').then((_){reached.complete();}));}return ExactTransportCapability.unknown;});
        probe.before=(sql)async{
          if(sql.contains('exact_money_transport_unverified')&&sql.trimLeft().startsWith('UPDATE planning_sync_outbox')){
            await replaced;if(!reached.isCompleted)reached.complete();
          }
        };
        final result=await service.push();await replaced;expect(reached.isCompleted,isTrue);expect(checks,greaterThan(0));
        final row=(await _outbox(h.db)).single;
        if(replace){expect(row,{...before,'in_flight_seq':null});expect(result.parked,0);}
        else{expect(result.parked,1);expect(row['status'],'parked');}
        expect(h.requests,isEmpty);
      },probe:probe);
    });
  }

  test('E4 parent started registration writer drains atomic enqueue before physical close',()async{
    final probe=_ParentCommitProbe();
    await withParent((h)async{
      await h.db.customStatement('DELETE FROM planning_sync_outbox;');
      await DriftCategoryRepository(h.db).createCategory(nameAr:'started eligible',icon:'tag',color:'#000',isIncome:false);
      final handle=(await AccountFenceAuthority.shared.capture(h.admission.fixture.session,h.admission.fixture.host))!;
      final reached=Completer<void>();final release=h.release();var terminal=false;var early=false;var notified=0;
      probe.before=(sql)async{if(sql.contains('INSERT INTO planning_sync_outbox')&&!reached.isCompleted){reached.complete();await release.future;}};
      probe.onOuterCommit=()=>terminal=true;probe.onClose=(){if(!terminal)early=true;};
      final q=PlanningOutboxQueue(db:h.db,isSyncEnabled:(_)=>true,getAuthUserId:()async=>_uid,getOwnerUid:h.admission.fixture.session.readLocalDataOwnerUid,onQueued:()=>notified++);
      final running=h.track(_parentStop(PlanningStartupRegistrationService(db:h.db,queue:q,isEnabled:(_)=>true).registerMissingRows(settingsPullCompleted:false)));
      expect(await Future.any([reached.future.then((_)=>true),running.then((_)=>false)]),isTrue);
      terminal=false;
      final denied=h.track(AccountFenceAuthority.shared.accept(handle,AccountFenceState.pending,operationId:'00000000-0000-0000-0000-000000000001'));
      expect(probe.closeAttempts,0);release.complete();await running;expect((await denied).complete,isTrue);
      expect(terminal,isTrue);expect(early,isFalse);expect(notified,0);expect(h.requests,isEmpty);
    },probe:probe);
  });

  for(final cut in [false,true]){
    test('E4 parent actual CAS missing-base lookup next mutation cut=$cut',()async{
      await withParent((h)async{
        await h.db.customStatement("UPDATE categories SET server_id='server-parent',server_updated_at='2026-09-01T00:00:00Z' WHERE id='${h.id}';");
        final original=(await _outbox(h.db)).single;final payload=(jsonDecode(original['payload_json']as String)as Map<String,dynamic>)..['server_updated_at']='2026-09-01T00:00:00Z';
        await h.db.customStatement("UPDATE planning_sync_outbox SET operation='update',payload_json=?;",[jsonEncode(payload)]);
        final reached=Completer<void>();final release=h.release();
        h.respond=(r)async{
          if(r.method=='GET'){reached.complete();if(cut)await release.future;return http.Response(jsonEncode({'id':'server-parent','updated_at':'2026-09-01T00:00:00Z','revision':4,'deleted_at':null}),200,headers:{'content-type':'application/json'},request:r);}
          expect(r.url.path,'/rest/v1/rpc/sync_cas_update');return http.Response(jsonEncode({'outcome':'applied','row':{'id':'server-parent','updated_at':'2026-10-01T00:00:00Z','revision':5}}),200,headers:{'content-type':'application/json'},request:r);
        };
        final running=h.track(h.service(gate:RevisionCasGate(db:h.db,capability:()async=>ServerCapabilityState.verified,remote:_ParentHead())).push().then<Object?>((v)=>v,onError:(Object e)=>e));
        expect(await Future.any([reached.future.then((_)=>true),running.then((_)=>false)]),isTrue);
        if(cut){await h.admission.fixture.signIn(_uid);release.complete();expect(await running,isA<PlanningDeliveryStopped>());expect(h.requests,hasLength(1));}
        else{expect(await running,isA<PlanningPushResult>().having((r)=>r.pushed,'pushed',1));expect(h.requests,hasLength(2));}
      });
    });
  }

  for(final newHolder in [false,true]){
    test('E4 parent actual denial preserves coalesced intent holder newer=$newHolder',()async{
      await withParent((h)async{
        final db=h.db;final location=h.admission.location;final reached=Completer<void>();final release=h.release();
        final original=(await _outbox(db)).single;
        h.respond=(r)async{reached.complete();await release.future;return h.reply(r,'QD001');};
        final running=h.track(_parentStop(h.service().push()));await reached.future;
        final category=(await DriftCategoryRepository(db).getAll()).firstWhere((c)=>c.id==h.id);
        await h.queue.enqueueCategory(PlanningSyncOperation.update,CategoryEntity(id:category.id,key:category.key,nameAr:'coalesced intent',icon:category.icon,color:category.color,isIncome:category.isIncome,sort:category.sort));
        if(newHolder)await h.queue.pendingItems(entityType:'category');
        final edited=(await _outbox(db)).single;release.complete();final result=await running;
        expect(result.accepted,isTrue);expect(result.parked,!newHolder);expect(result.complete,!newHolder);
        final row=(await LedgerAdmissionFixture.inspectClosed(db,location,_outbox)).single;
        expect(_intent(row),_intent(edited));expect(row['attempt_count'],0);expect(row['in_flight_seq'],edited['in_flight_seq']);
        expect((jsonDecode(row['payload_json']as String)as Map)['prior_op_ids'],contains(original['operation_id']));
        if(newHolder){expect(row,edited);}else{expect(row['status'],'parked');expect(row['failure_class'],'account_deletion_pending');}
      });
    });
  }

  test('E4 parent late ordinary failure cannot alter NULL holder',()async{
    await withParent((h)async{
      Map<String,Object?>? snapshot;Map<String,Object?>? entity;
      h.respond=(r)async{
        await h.db.customStatement('UPDATE planning_sync_outbox SET in_flight_seq=NULL;');
        snapshot=(await _outbox(h.db)).single;entity=await _entity(h.db,false,h.id);
        return h.reply(r,'42501');
      };
      final result=await h.service().push();expect(result.failed,1);
      expect((await _outbox(h.db)).single,snapshot);expect(await _entity(h.db,false,h.id),entity);
      expect(await _parentConflicts(h.db),isEmpty);expect(h.requests,hasLength(1));
    });
  });

  test('E4 parent privileged gone hold survives queue rearm coalesce create-delete',()async{
    await withParent((h)async{
      final db=h.db;final location=h.admission.location;final before=(await _outbox(db)).single;
      final cap=h.admission.fixture.session.captureLocalWorkAuthority()!;
      h.respond=(r)async=>h.reply(r,'QD002');final stopped=await _parentStop(h.service().push());
      expect(stopped.complete,isTrue);expect(db.lifecycleState,DatabaseLifecycleState.closed);expect(File(location.dbPath).existsSync(),isTrue);
      final hold=AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(_uid));
      final inspection=await AppDatabase.open(location:location,runMigrations:false,creation:const CreationPolicy.denied());
      try{
        final queue=PlanningOutboxQueue(db:inspection,isSyncEnabled:(_)=>true,getAuthUserId:()async=>_uid,getOwnerUid:()async=>_uid);
        await queue.reArmParked();await queue.clearRetryBackoff();await queue.reArmAuthParked();
        final c=(await DriftCategoryRepository(inspection).getAll()).firstWhere((c)=>c.id==h.id);
        await queue.enqueueCategory(PlanningSyncOperation.update,CategoryEntity(id:c.id,key:c.key,nameAr:'retained gone intent',icon:c.icon,color:c.color,isIncome:c.isIncome,sort:c.sort));
        await queue.enqueueCategory(PlanningSyncOperation.delete,c);
        final row=(await _outbox(inspection)).single;
        expect(row['id'],before['id']);expect(row['status'],'parked');expect(row['failure_class'],'account_deletion_gone');expect(row['attempt_count'],0);
        expect((jsonDecode(row['payload_json']as String)as Map)['prior_op_ids'],contains(before['operation_id']));
      }finally{await inspection.close();expect(inspection.lifecycleState,DatabaseLifecycleState.closed);}
      expect(cap.isCurrent,isFalse);expect(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(_uid)),same(hold));expect(h.requests,hasLength(1));
    });
  });

  test('E4 parent raw QD from CAS semantic mutation is provenance not denial',()async{
    await withParent((h)async{
      final remote=_RawQdCasRemote();
      await _expectRawOriginUnproven(h,()=>h.service(gate:RevisionCasGate(db:h.db,
          capability:()async=>ServerCapabilityState.verified,remote:_ParentHead()),casRemote:remote).push(),
          reachedOrigin:()async=>expect(remote.inserts,1,reason:'the custom CAS mutation must be reached exactly once'));
    });
  });

  test('E4 parent raw QD from in-item read is provenance not denial',()async{
    await withParent((h)async{
      await h.db.customStatement("UPDATE categories SET server_id='server-parent' WHERE id='${h.id}';");
      final original=(await _outbox(h.db)).single;
      final payload=(jsonDecode(original['payload_json']as String)as Map<String,dynamic>)
        ..remove('server_updated_at')..remove('server_revision');
      await h.db.customStatement("UPDATE planning_sync_outbox SET operation='update',payload_json=?;",[jsonEncode(payload)]);
      final sink=_RawQdReadSink();
      await _expectRawOriginUnproven(h,()=>h.service(sink:sink).push(),
          reachedOrigin:()async=>expect(sink.reads,1,reason:'the in-item read must be reached exactly once'));
    });
  });

  for (final code in ['QD001', 'QD002']) {
    test('E4 parent concrete CAS mutation $code is accepted on the original host',()async{
      await withParent((h)async{
        final db=h.db;final location=h.admission.location;
        final before=(await _outbox(db)).single;final entityBefore=await _entity(db,false,h.id);
        final cap=h.admission.fixture.session.captureLocalWorkAuthority()!;
        h.respond=(r)async{
          expect(r.url.path,'/rest/v1/rpc/sync_insert_if_absent');
          return h.reply(r,code);
        };
        final stopped=await _parentStop(h.service(gate:RevisionCasGate(db:db,
            capability:()async=>ServerCapabilityState.verified,remote:_ParentHead())).push());
        expect(stopped.reason,PlanningDeliveryStopReason.denial);
        expect(stopped.accepted&&stopped.parked&&stopped.complete,isTrue);
        expect(h.requests,hasLength(1));expect(cap.isCurrent,isFalse);
        expect(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(_uid))?.state,
            code=='QD001'?AccountFenceState.pending:AccountFenceState.gone);
        final row=(await LedgerAdmissionFixture.inspectClosed(db,location,_outbox)).single;
        expect(_intent(row),_intent(before));expect(row['status'],'parked');expect(row['attempt_count'],0);
        expect(await LedgerAdmissionFixture.inspectClosed(db,location,
            (inspection)=>_entity(inspection,false,h.id)),entityBefore);
      });
    });
  }

  test('E4 parent raw QD from an in-item read after an earlier ACK does not borrow proof',()async{
    await withParent((h)async{
      final db=h.db;
      final second=await DriftCategoryRepository(db,outboxQueue:h.queue).createCategory(
          nameAr:'Synthetic second',icon:'tag',color:'#654321',isIncome:false);
      await db.customStatement("UPDATE categories SET server_id='server-second' WHERE id='${second.id}';");
      final secondRow=(await db.customSelect("SELECT payload_json FROM planning_sync_outbox WHERE entity_id='${second.id}';").getSingle()).data;
      final payload=(jsonDecode(secondRow['payload_json']as String)as Map<String,dynamic>)
        ..remove('server_updated_at')..remove('server_revision');
      await db.customStatement("UPDATE planning_sync_outbox SET operation='update',payload_json=?,created_at='2026-10-01T00:00:01.000Z' WHERE entity_id='${second.id}';",[jsonEncode(payload)]);
      await db.customStatement("UPDATE planning_sync_outbox SET created_at='2026-10-01T00:00:00.000Z' WHERE entity_id='${h.id}';");
      final secondBefore=(await db.customSelect("SELECT * FROM planning_sync_outbox WHERE entity_id='${second.id}';").getSingle()).data;
      final cap=h.admission.fixture.session.captureLocalWorkAuthority()!;
      final sink=_RawQdReadSink();
      final outcome=await h.service(sink:sink).push().then<Object?>((v)=>v,onError:(Object e)=>e);
      expect(sink.reads,1,reason:'the later item reached its in-item read exactly once');
      expect(h.requests,hasLength(1),reason:'only the earlier create was dispatched');
      expect(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(_uid)),isNull);
      expect(cap.isCurrent,isTrue);expect(db.lifecycleState,isNot(DatabaseLifecycleState.closed));
      final remaining=await db.customSelect('SELECT * FROM planning_sync_outbox;').get();
      expect(remaining,hasLength(1),reason:'the earlier ACK is preserved, only the later intent remains');
      expect(_intent(remaining.single.data),_intent(secondBefore));
      expect(remaining.single.data['status'],'pending');
      expect(remaining.single.data['attempt_count'],secondBefore['attempt_count']);
      final first=await _entity(db,false,h.id);
      expect(first['server_id'],'server-parent');expect(first['sync_status'],'synced');
      expect(outcome,isA<PlanningDeliveryStopped>()
          .having((e)=>e.reason,'reason',PlanningDeliveryStopReason.provenance)
          .having((e)=>e.accepted||e.parked||e.complete,'accepted/parked/complete',isFalse));
    });
  });

  test('E4 parent actual SDK QD on a legacy read stays ordinary and is never accepted',()async{
    await withParent((h)async{
      await h.db.customStatement("UPDATE categories SET server_id='server-parent' WHERE id='${h.id}';");
      final original=(await _outbox(h.db)).single;
      final payload=(jsonDecode(original['payload_json']as String)as Map<String,dynamic>)
        ..remove('server_updated_at')..remove('server_revision');
      await h.db.customStatement("UPDATE planning_sync_outbox SET operation='update',payload_json=?;",[jsonEncode(payload)]);
      final cap=h.admission.fixture.session.captureLocalWorkAuthority()!;
      h.respond=(r)async{
        expect(r.method,'GET');
        return h.reply(r,'QD001');
      };
      final outcome=await h.service().push().then<Object?>((v)=>v,onError:(Object e)=>e);
      expect(h.requests,isNotEmpty);expect(h.requests.every((r)=>r.method=='GET'),isTrue,reason:'no mutation transport');
      expect(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(_uid)),isNull);
      expect(cap.isCurrent,isTrue);expect(h.db.lifecycleState,isNot(DatabaseLifecycleState.closed));
      expect(outcome,isNot(isA<PlanningDeliveryStopped>().having((e)=>e.reason,'reason',PlanningDeliveryStopReason.denial)),
          reason:'the SDK normalization/read origin is never an accepted mutation refusal');
    });
  });

  test('E4 CAS observation scope: run-once, sole dispatch, take-once, expiry, mismatch, frozen input',()async{
    final reqs=<http.Request>[];
    respond=(r)async{
      reqs.add(r);
      return http.Response(jsonEncode({'code':'QD001','message':'synthetic','details':null,'hint':null}),400,
          headers:{'content-type':'application/json'},request:r);
    };
    const remote=SupabaseCasRemote();
    final row=<String,dynamic>{'user_id':'u','n':1,'nested':{'a':[1,2.5]}};
    CasMutationObservation make(Map<String,dynamic> r)=>CasMutationObservation.insertIfAbsent(
        table:'user_categories',epoch:'e1',opId:'op-1',row:r);
    Future<CasResult> send(Map<String,dynamic> r)=>remote.insertIfAbsent(
        table:'user_categories',epoch:'e1',opId:'op-1',row:r);
    Future<Object?> outcome(Future<Object?> f)=>f.then<Object?>((v)=>v,onError:(Object e)=>e);
    void noop(){}

    final first=make(row);
    final proof=await outcome(first.run(()=>send(row),requireCurrent:noop));
    expect(proof,isA<CasMutationAwaitDenial>());expect(reqs,hasLength(1));
    expect(make(row).takeDenial(proof!),isNull,reason:'a foreign observation cannot consume the proof');
    expect(first.takeDenial(Object()),isNull);
    final taken=first.takeDenial(proof);
    expect(taken,isA<PostgrestException>().having((e)=>e.code,'code','QD001'));
    expect(first.takeDenial(proof),isNull,reason:'take-once');
    expect(await outcome(first.run(()=>send(row),requireCurrent:noop)),isA<CasMutationObservationRejected>(),
        reason:'run-once');
    final replay=make(row);
    final replayed=await outcome(replay.run(()async=>throw proof,requireCurrent:noop));
    expect(replay.takeDenial(replayed!),isNull,reason:'a replayed public proof is rejected');

    final twice=make(row);
    final sole=await outcome(twice.run(()async{
      await outcome(send(row));
      return send(row);
    },requireCurrent:noop));
    expect(sole,isA<CasMutationObservationRejected>(),reason:'sole concrete dispatch');
    expect(reqs,hasLength(2));

    Zone? inherited;
    await outcome(make(row).run(()async{inherited=Zone.current;return const CasResult(CasOutcome.ack,null);},requireCurrent:noop));
    expect(await outcome(inherited!.run(()=>send(row))),isA<CasMutationObservationRejected>(),
        reason:'an expired inherited scope never reaches the network');
    expect(reqs,hasLength(2));

    Future<Object?> dispatchWith(CasMutationObservation o,Map<String,dynamic> actual)=>
        outcome(o.run(()=>send(actual),requireCurrent:noop));
    expect(await dispatchWith(make(row),{...row,'n':2}),isA<CasMutationObservationRejected>(),reason:'nested mismatch');
    final mutable=<String,dynamic>{'list':[1]};
    final snapshot=make(mutable);(mutable['list']as List).add(2);
    expect(await dispatchWith(snapshot,mutable),isA<CasMutationObservationRejected>(),reason:'input mutated after expectation');
    expect(await dispatchWith(make({'n':1}),{'n':1.0}),isA<CasMutationObservationRejected>(),reason:'int is not double');
    expect(await dispatchWith(make({'a':null}),<String,dynamic>{}),isA<CasMutationObservationRejected>(),reason:'null is not missing');
    expect(()=>make({'n':double.nan}),throwsArgumentError);
    expect(reqs,hasLength(2));
    final ordered=make({'a':1,'b':2});
    expect(await dispatchWith(ordered,{'b':2,'a':1}),isA<CasMutationAwaitDenial>(),reason:'key order is irrelevant');
    expect(reqs,hasLength(3));
  });

  for (final operation in ['update', 'delete']) {
    test('E4 parent real guarded $operation retries 55P03 inside one item with the same request',()async{
      await withParent((h)async{
        await h.db.customStatement("UPDATE categories SET server_id='server-parent',server_updated_at='2026-09-01T00:00:00Z' WHERE id='${h.id}';");
        final original=(await _outbox(h.db)).single;
        final payload=(jsonDecode(original['payload_json']as String)as Map<String,dynamic>)..['server_updated_at']='2026-09-01T00:00:00Z';
        await h.db.customStatement("UPDATE planning_sync_outbox SET operation='$operation',payload_json=?;",[jsonEncode(payload)]);
        final before=(await _outbox(h.db)).single;
        final cap=h.admission.fixture.session.captureLocalWorkAuthority()!;
        var patches=0;
        h.respond=(r)async{
          if(r.method!='PATCH')return h.reply(r,'success');
          patches++;
          if(patches==1){
            return http.Response(jsonEncode({'code':'55P03','message':'synthetic contention','details':null,'hint':null}),400,
                headers:{'content-type':'application/json'},request:r);
          }
          return h.reply(r,'success');
        };
        final outcome=await h.service(retry:AccountFenceRetry(delay:(_)async{})).push()
            .then<Object?>((v)=>v,onError:(Object e)=>e);
        final sent=h.requests.where((r)=>r.method=='PATCH').toList();
        expect(sent,hasLength(2),reason:'one contended attempt then the same request again');
        expect(sent[1].url,sent[0].url);expect(sent[1].body,sent[0].body);
        expect(sent[0].url.queryParameters['id'],'eq.server-parent');
        expect(sent[0].url.queryParameters['updated_at'],'eq.2026-09-01T00:00:00Z');
        expect(before['operation_id'],isA<String>());
        expect(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(_uid)),isNull);
        expect(cap.isCurrent,isTrue);expect(h.db.lifecycleState,isNot(DatabaseLifecycleState.closed));
        expect(outcome,isA<PlanningPushResult>().having((r)=>r.pushed,'pushed',1));
        expect(await _outbox(h.db),isEmpty,reason:'the genuine ACK consumed the queued intent');
      });
    });
  }

  test('E4 parent read override delegating to a different real mutation dispatches nothing',()async{
    await withParent((h)async{
      await h.db.customStatement("UPDATE categories SET server_id='server-parent' WHERE id='${h.id}';");
      final original=(await _outbox(h.db)).single;
      final payload=(jsonDecode(original['payload_json']as String)as Map<String,dynamic>)
        ..remove('server_updated_at')..remove('server_revision');
      await h.db.customStatement("UPDATE planning_sync_outbox SET operation='update',payload_json=?;",[jsonEncode(payload)]);
      h.respond=(r)async=>h.reply(r,'QD001');
      final sink=_ReadDelegatesMutationSink();
      await _expectRawOriginUnproven(h,()=>h.service(sink:sink).push(),
          reachedOrigin:()async=>expect(sink.reads,1,reason:'the read override must be reached exactly once'));
    });
  });

  test('E4 parent concrete CAS refusal is accepted although the positive phase became unready',()async{
    await withParent((h)async{
      final reached=Completer<void>();final release=h.release();
      h.respond=(r)async{reached.complete();await release.future;return h.reply(r,'QD001');};
      final phase=SyncPhaseBinding();
      await AccountsPushService(db:h.db,queue:h.queue,isEnabled:()=>false,
          getAuthUserId:()async=>_uid,mayEgress:()async=>true).pushWithPhase(phase);
      final running=h.track(_parentStop(h.service(gate:RevisionCasGate(db:h.db,
          capability:()async=>ServerCapabilityState.verified,remote:_ParentHead())).pushWithPhase(phase.forNextPhase())));
      await reached.future;
      final hold=h.admission.fixture.storage.holdOnce((op,key)=>op=='read'&&key==AccountFenceStore.storageKey);
      h.releases.add(hold.release);
      final loading=h.track(AccountFenceAuthority.shared.initialize());await hold.reached.future;
      expect(phase.isCurrent,isFalse);
      final retired=Completer<void>();
      void listener(){
        if(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(_uid))!=null&&!retired.isCompleted){retired.complete();}
      }
      h.admission.fixture.session.addListener(listener);
      try {
        release.complete();
        expect(await Future.any([retired.future.then((_)=>true),running.then((_)=>false)]),isTrue);
      } finally { h.admission.fixture.session.removeListener(listener);hold.release.complete(); }
      final result=await running;await loading;
      expect(h.requests.single.url.path,'/rest/v1/rpc/sync_insert_if_absent');
      expect(result.accepted&&result.parked&&result.complete,isTrue);
    });
  });

  test('E4 parent mutation delegate rewriting the expected target dispatches nothing',()async{
    await withParent((h)async{
      await h.db.customStatement("UPDATE categories SET server_id='server-parent',server_updated_at='2026-09-01T00:00:00Z' WHERE id='${h.id}';");
      final original=(await _outbox(h.db)).single;
      final payload=(jsonDecode(original['payload_json']as String)as Map<String,dynamic>)..['server_updated_at']='2026-09-01T00:00:00Z';
      await h.db.customStatement("UPDATE planning_sync_outbox SET operation='update',payload_json=?;",[jsonEncode(payload)]);
      h.respond=(r)async=>h.reply(r,'QD001');
      final sink=_RewritingMutationSink();
      await _expectRawOriginUnproven(h,()=>h.service(sink:sink).push(),
          reachedOrigin:()async=>expect(sink.rewrites,1,reason:'the mutation delegate must be reached exactly once'));
    });
  });

  for (final replayIn in ['read', 'mutation']) {
    test('E4 parent genuine bridge proof replayed through a custom CAS $replayIn is provenance',()async{
      respond=(r)async=>http.Response(jsonEncode({'code':'QD001','message':'synthetic','details':null,'hint':null}),400,
          headers:{'content-type':'application/json'},request:r);
      const real=SupabaseCasRemote();
      final observation=CasMutationObservation.insertIfAbsent(
          table:'user_categories',epoch:'e1',opId:'op-proof',row:{'user_id':'u'});
      final proof=await observation.run(()=>real.insertIfAbsent(
          table:'user_categories',epoch:'e1',opId:'op-proof',row:{'user_id':'u'}),requireCurrent:(){})
          .then<Object?>((v)=>v,onError:(Object e)=>e);
      expect(proof,isA<CasMutationAwaitDenial>());
      await withParent((h)async{
        await h.db.customStatement("UPDATE categories SET server_id='server-parent' WHERE id='${h.id}';");
        final original=(await _outbox(h.db)).single;
        final payload=(jsonDecode(original['payload_json']as String)as Map<String,dynamic>)
          ..remove('server_updated_at')..remove('server_revision');
        await h.db.customStatement(
            "UPDATE planning_sync_outbox SET operation='update',payload_json=?,base_revision=${replayIn=='mutation'?'5':'NULL'};",
            [jsonEncode(payload)]);
        final remote=_ProofReplayCasRemote(proof!,read:replayIn=='read');
        await _expectRawOriginUnproven(h,()=>h.service(gate:RevisionCasGate(db:h.db,
            capability:()async=>ServerCapabilityState.verified,remote:_ParentHead()),casRemote:remote).push(),
            reachedOrigin:()async=>expect(remote.calls,1,reason:'the custom $replayIn must be reached exactly once'));
      });
    });
  }

  test('E4 parent actual SDK maybeSingle read boundary reports code 400 and fails ordinarily',()async{
    await withParent((h)async{
      await h.db.customStatement("UPDATE categories SET server_id='server-parent' WHERE id='${h.id}';");
      final original=(await _outbox(h.db)).single;
      final payload=(jsonDecode(original['payload_json']as String)as Map<String,dynamic>)
        ..remove('server_updated_at')..remove('server_revision');
      await h.db.customStatement("UPDATE planning_sync_outbox SET operation='update',payload_json=?;",[jsonEncode(payload)]);
      final cap=h.admission.fixture.session.captureLocalWorkAuthority()!;
      h.respond=(r)async{
        expect(r.method,'GET');
        return h.reply(r,'QD001');
      };
      final sink=_CaptureReadSink();
      final outcome=await h.service(sink:sink).push().then<Object?>((v)=>v,onError:(Object e)=>e);
      expect(sink.reads,1);
      expect(sink.code,'400',reason:'the SDK normalizes the maybeSingle error; it is not parsed from the message');
      expect(h.requests.every((r)=>r.method=='GET'),isTrue,reason:'no mutation transport');
      expect(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(_uid)),isNull);
      expect(cap.isCurrent,isTrue);expect(h.db.lifecycleState,isNot(DatabaseLifecycleState.closed));
      expect(outcome,isA<PlanningPushResult>().having((r)=>r.failed,'failed',1));
    });
  });

  test('E4 parent malformed operation identity prevents dispatch',()async{
    await withParent((h)async{
      await h.db.customStatement("UPDATE planning_sync_outbox SET operation_id='malformed';");
      final before=(await _outbox(h.db)).single;
      expect((await _parentStop(h.service().push())).reason,PlanningDeliveryStopReason.provenance);
      expect(h.requests,isEmpty);expect(_intent((await _outbox(h.db)).single),_intent(before));expect((await _outbox(h.db)).single['attempt_count'],0);
    });
  });

  test('E4 parent actual provider construction refuses detached binding',()async{
    await withParent((h)async{
      final before=await _outbox(h.db);final entity=await _entity(h.db,false,h.id);
      h.admission.fixture.session.configureAccountScope(null);
      final container=ProviderContainer(overrides:[appDatabaseProvider.overrideWithValue(h.db)]);
      try{
        expect((await _parentStop(container.read(planningPushServiceProvider).push())).reason,PlanningDeliveryStopReason.unbound);
        expect(await _outbox(h.db),before);expect(await _entity(h.db,false,h.id),entity);
      }finally{container.dispose();h.admission.fixture.session.configureAccountScope(h.admission.fixture.host);}
    });
  });

  test('E4 parent Gate propagates exact shared cancellation',()async{
    await withParent((h)async{
      const stop=AccountsDeliveryStopped(AccountsDeliveryStopReason.stale);
      final handle=(await AccountFenceAuthority.shared.capture(h.admission.fixture.session,h.admission.fixture.host))!;
      await expectLater(RevisionCasGate(db:h.db,capability:()async=>throw stop).planForPlanningParent(_uid,
          authority:AccountFenceAuthority.shared,handle:handle,database:h.db),throwsA(same(stop)));
    });
  });

}

/// Downstream effect doubles only. The account pusher, queue, authority, host,
/// database and SDK transport above are real.
class _Downstream {
  final calls = <String, int>{};
  final settingsCompleted = <bool>[];
  void called(String name) => calls.update(name, (value) => value + 1, ifAbsent: () => 1);
}

class _AccountsPull implements AccountsPullService {
  _AccountsPull(this.effects);
  final _Downstream effects;
  @override
  Future<AccountsPullResult> pull({SyncCursor? from, bool Function()? isAdmitted}) async {
    effects.called('account-pull');
    return const AccountsPullResult(status: SyncPullStatus.completed);
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('unexpected account pull method');
}

class _PlanningPull implements PlanningPullService {
  _PlanningPull(this.effects);
  final _Downstream effects;
  @override
  Future<PlanningPullResult> pull({Set<String>? fromEpochEntities, bool Function()? isAdmitted}) async {
    effects.called('planning-pull');
    return const PlanningPullResult(completedEntities: {PlanningOutboxQueue.settingsEntityType});
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('unexpected planning pull method');
}

class _Children implements PlanningChildSyncService {
  _Children(this.effects);
  final _Downstream effects;
  @override
  Future<void> sync() async => effects.called('children');
  @override
  Future<void> syncWithPhase(SyncPhaseBinding phase)=>sync();
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('unexpected child method');
}

class _Registration implements PlanningStartupRegistrationService {
  _Registration(this.effects);
  final _Downstream effects;
  @override
  Future<void> registerMissingRows({required bool settingsPullCompleted}) async {
    effects.called('registration'); effects.settingsCompleted.add(settingsPullCompleted);
  }
  @override
  Future<void> registerMissingRowsWithPhase({required bool settingsPullCompleted,
      required SyncPhaseBinding phase}) => registerMissingRows(settingsPullCompleted: settingsPullCompleted);
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('unexpected registration method');
}

class _Conflicts implements UniversalConflictResolver {
  _Conflicts(this.effects);
  final _Downstream effects;
  @override
  Future<int> autoResolveDeterministic() async { effects.called('conflict'); return 0; }
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('unexpected conflict method');
}

/// Only synthetic SDK PKCE state; app auth persistence is outside this test.
class _SdkMemoryStorage extends GotrueAsyncStorage {
  const _SdkMemoryStorage();
  @override
  Future<String?> getItem({required String key}) async => null;
  @override
  Future<void> setItem({required String key, required String value}) async {}
  @override
  Future<void> removeItem({required String key}) async {}
}



Future<List<Map<String,Object?>>> _parentConflicts(AppDatabase db) async =>
    (await db.customSelect('SELECT * FROM sync_conflicts;').get()).map((r)=>r.data).toList();
Future<PlanningDeliveryStopped> _parentStop(Future<Object?> work) async {
  try {await work;throw StateError('expected exact parent stop');}
  on PlanningDeliveryStopped catch(error){return error;}
}
/// Raw QD from an arbitrary semantic CAS mutation that never reaches the SDK:
/// a thrown error is not by itself proof of an authoritative mutation refusal.
class _RawQdCasRemote implements CasRemote {
  int inserts=0;
  @override
  Future<CasResult> insertIfAbsent({required String table,required String epoch,
      required String opId,required Map<String,dynamic> row}) async {
    inserts++;
    throw const PostgrestException(message:'synthetic semantic mutation',code:'QD001');
  }
  @override
  dynamic noSuchMethod(Invocation i)=>throw StateError('unexpected CAS method');
}
/// Real mutations; ONLY the in-item server read throws a raw QD001 (not via the
/// SDK, which may normalize a read error to a different code).
class _RawQdReadSink implements PlanningRemoteSink {
  int reads=0;
  static const _real=SupabasePlanningRemoteSink();
  @override
  Future<String?> fetchServerUpdatedAt(String table,String serverId) async {
    reads++;
    throw const PostgrestException(message:'synthetic in-item read',code:'QD001');
  }
  @override
  Future<Map<String,dynamic>> upsert(String table,Map<String,dynamic> row)=>_real.upsert(table,row);
  @override
  Future<Map<String,dynamic>?> findByLocalId(String table,String userId,String localId)=>
      _real.findByLocalId(table,userId,localId);
  @override
  Future<Map<String,dynamic>?> guardedTombstone(String table,String serverId,String? expectedUpdatedAt)=>
      _real.guardedTombstone(table,serverId,expectedUpdatedAt);
  @override
  Future<Map<String,dynamic>?> fetchRowState(String table,String serverId)=>_real.fetchRowState(table,serverId);
  @override
  Future<Map<String,dynamic>?> updateByServerId(String table,String serverId,Map<String,dynamic> row)=>
      _real.updateByServerId(table,serverId,row);
  @override
  Future<Map<String,dynamic>?> guardedUpdateByServerId(String table,String serverId,
      String expectedUpdatedAt,Map<String,dynamic> row)=>
      _real.guardedUpdateByServerId(table,serverId,expectedUpdatedAt,row);
}
/// A READ override that delegates to a DIFFERENT real concrete mutation under the
/// original read context: no mutation was expected there, so nothing may be sent.
class _ReadDelegatesMutationSink extends _RawQdReadSink {
  @override
  Future<String?> fetchServerUpdatedAt(String table,String serverId) async {
    reads++;
    await _RawQdReadSink._real.upsert('user_budgets',{'user_id':_uid,'local_id':'unrelated-row'});
    return null;
  }
}
/// A MUTATION delegate that changes the expected target before calling the REAL
/// sink: the actual command no longer equals the parent's, so nothing is sent.
class _RewritingMutationSink extends _RawQdReadSink {
  int rewrites=0;
  @override
  Future<Map<String,dynamic>?> guardedUpdateByServerId(String table,String serverId,
      String expectedUpdatedAt,Map<String,dynamic> row){
    rewrites++;
    return _RawQdReadSink._real.guardedUpdateByServerId(table,'server-other',expectedUpdatedAt,row);
  }
}
/// Delegates the in-item read to the real sink and records the SDK's actual code.
class _CaptureReadSink extends _RawQdReadSink {
  String? code;
  @override
  Future<String?> fetchServerUpdatedAt(String table,String serverId) async {
    reads++;
    try { return await _RawQdReadSink._real.fetchServerUpdatedAt(table,serverId); }
    on PostgrestException catch(error){ code=error.code; rethrow; }
  }
}
/// Throws a previously captured genuine bridge proof from a read or a mutation.
class _ProofReplayCasRemote implements CasRemote {
  _ProofReplayCasRemote(this.proof,{required this.read});
  final Object proof;
  final bool read;
  int calls=0;
  @override
  Future<Map<String,dynamic>?> fetchRow(String table,String serverId) async {
    if(!read) throw StateError('unexpected read');
    calls++;
    throw proof;
  }
  @override
  Future<CasResult> casUpdate({required String table,required String epoch,required String opId,
      required String serverId,required int expectedRevision,required Map<String,dynamic> patch}) async {
    if(read) throw StateError('unexpected mutation');
    calls++;
    throw proof;
  }
  @override
  dynamic noSuchMethod(Invocation i)=>throw StateError('unexpected CAS method');
}
/// Runs [start], records the outcome, and judges retained state BEFORE the
/// primary provenance assertion so an earlier fixture/behavior difference cannot
/// mask the oracle. A raw QD from a non-mutation origin must neither retire the
/// original lifetime, hold the owner, park/ACK the item nor dispatch further.
Future<void> _expectRawOriginUnproven(_ParentHarness h,Future<Object?> Function() start,
    {required Future<void> Function() reachedOrigin})async{
  final db=h.db;final location=h.admission.location;
  final cap=h.admission.fixture.session.captureLocalWorkAuthority()!;
  expect(cap.isCurrent,isTrue);
  final outboxBefore=(await _outbox(db)).single;final entityBefore=await _entity(db,false,h.id);
  final outcome=await start().then<Object?>((v)=>v,onError:(Object e)=>e);
  await reachedOrigin();
  Future<T> read<T>(Future<T> Function(AppDatabase) f)=>db.lifecycleState==DatabaseLifecycleState.closed
      ?LedgerAdmissionFixture.inspectClosed(db,location,f):f(db);
  expect(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(_uid)),isNull,
      reason:'no durable owner hold from a non-mutation origin');
  expect(cap.isCurrent,isTrue,reason:'original lifetime must remain');
  expect(db.lifecycleState,isNot(DatabaseLifecycleState.closed));
  final retained=(await read(_outbox)).single;
  expect(_intent(retained),_intent(outboxBefore));
  expect(retained['status'],'pending');expect(retained['attempt_count'],outboxBefore['attempt_count']);
  expect(retained['in_flight_seq'],anyOf(equals(outboxBefore['in_flight_seq']),equals(outboxBefore['op_seq'])));
  expect(await read((db)=>_entity(db,false,h.id)),entityBefore,reason:'no ACK or sync marker');
  expect(h.requests,isEmpty,reason:'no transport/mutation dispatch');
  expect(outcome,isA<PlanningDeliveryStopped>()
      .having((e)=>e.reason,'reason',PlanningDeliveryStopReason.provenance)
      .having((e)=>e.accepted,'accepted',isFalse)
      .having((e)=>e.parked,'parked',isFalse)
      .having((e)=>e.complete,'complete',isFalse));
}
class _ParentHead implements SeqRemote {
  @override
  Future<SyncHead?> fetchHead(String uid) async => const SyncHead(lastSeq:1,epoch:'e1');
  @override
  dynamic noSuchMethod(Invocation i)=>throw StateError('unexpected sequence method');
}
class _ParentHarness {
  _ParentHarness(this.admission,this.settings,this.probe);
  final LedgerDatabaseProbe? probe;
  final LedgerAdmissionFixture admission;
  final bool settings;
  AppDatabase get db=>admission.database;
  late String id;
  final requests=<http.Request>[];
  final releases=<Completer<void>>[];
  final producers=<Future<Object?>>[];
  late Future<http.Response> Function(http.Request) respond;
  Completer<void> release(){final c=Completer<void>();releases.add(c);return c;}
  Future<T> track<T>(Future<T> f){producers.add(f);return f;}
  PlanningOutboxQueue get queue=>PlanningOutboxQueue(db:db,isSyncEnabled:(_)=>true,
      getAuthUserId:()async=>_uid,getOwnerUid:admission.fixture.session.readLocalDataOwnerUid);
  Future<void> seed({required bool prebind,required bool fullCreate})async{
    if(settings){
      final repository=DriftUserSettingsRepository(db);final current=await repository.getSettings();id=current.id;
      if(!prebind)await db.customStatement("UPDATE user_settings SET server_id = 'server-settings' WHERE id = '$id';");
      final off=await repository.saveSettings(current.copyWith(displayName:'Synthetic private profile',
          cloudConsentState:ConsentState.declined,aiConsentState:ConsentState.declined));
      final legacy=PlanningOutboxQueue(db:db,isSyncEnabled:(_)=>true,getAuthUserId:()async=>_uid,getOwnerUid:()async=>null);
      await legacy.enqueueSettings(fullCreate?PlanningSyncOperation.create:PlanningSyncOperation.update,off,
          consentChanged:true,previous:current);
    }else{
      final category=await DriftCategoryRepository(db,outboxQueue:queue).createCategory(
          nameAr:'Synthetic category',icon:'tag',color:'#123456',isIncome:false);id=category.id;
    }
    respond=(r)async=>reply(r,'success');
  }
  Future<void> seedGoal()async{
    await db.customStatement('DELETE FROM planning_sync_outbox;');
    final goal=GoalEntity(id:'goal-parent',name:'Synthetic goal',currency:'SAR',targetMoney:Money(10000,'SAR'),savedMoney:Money(0,'SAR'),lastNotifiedSavedMoney:Money(0,'SAR'),vaultSkin:'classic',status:'active',createdAt:DateTime.utc(2026,10,1));
    await DriftGoalRepository(db,outboxQueue:queue).save(goal);id=goal.id;
  }
  Future<Map<String,Object?>> goalState()async=>(await db.customSelect("SELECT server_id,sync_status,synced_at FROM goals WHERE id='$id';").getSingle()).data;
  PlanningPushService service({AccountFenceRetry? retry,RevisionCasGate? gate,SyncHealth? health,
      Future<String?> Function()? auth,CasRemote? casRemote,PlanningRemoteSink? sink})=>PlanningPushService(db:db,queue:queue,isEnabled:(_)=>true,
      getAuthUserId:auth??()async=>_uid,remoteSink:sink??const SupabasePlanningRemoteSink(),
      mayEgress:()async=>!settings,mayEgressProfile:()async=>!settings,health:health,fenceRetry:retry,casGate:gate,casRemote:casRemote);
  http.Response reply(http.Request r,String outcome){
    if(outcome!='success') { return http.Response(jsonEncode({'code':outcome,'message':'typed refusal'}),400,
        headers:{'content-type':'application/json'},request:r); }
    final row={'id':settings?'server-settings':'server-parent','updated_at':'2026-10-01T00:00:00Z'};
    return http.Response(jsonEncode(r.method=='PATCH'?[row]:row),200,
        headers:{'content-type':'application/json'},request:r);
  }
}

class _ControlledParentHead implements SeqRemote {
  _ControlledParentHead(this.read);
  final Future<SyncHead?> Function() read;
  @override
  Future<SyncHead?> fetchHead(String uid)=>read();
  @override
  dynamic noSuchMethod(Invocation i)=>throw StateError('unexpected seq');
}

/// Only OUTERMOST successful send proves the registration transaction committed.
class _ParentCommitProbe extends LedgerDatabaseProbe {
  void Function()? onOuterCommit;
  @override
  TransactionExecutor beginTransaction()=>_ParentCommitTransaction(super.beginTransaction(),()=>onOuterCommit?.call(),true);
}
class _ParentCommitTransaction extends TransactionExecutor {
  _ParentCommitTransaction(this.delegate,this.committed,this.outer);
  final TransactionExecutor delegate;
  final void Function() committed;
  final bool outer;
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
  TransactionExecutor beginTransaction()=>_ParentCommitTransaction(delegate.beginTransaction(),committed,false);
  @override
  QueryExecutor beginExclusive()=>delegate.beginExclusive();
  @override
  Future<void> send()async{await delegate.send();if(outer)committed();}
  @override
  Future<void> rollback()=>delegate.rollback();
  @override
  Future<void> close()=>delegate.close();
}
