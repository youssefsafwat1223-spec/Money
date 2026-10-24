import 'package:money_companion/data/db/creation_policy.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/data/db/financial_cache_health.dart';
import 'package:money_companion/data/db/legacy_financial_cache_reconciler.dart';
import 'package:money_companion/data/db/replica_location.dart';
import 'dart:async';
import 'dart:io';

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/session/account_fence_authority.dart';
import 'package:money_companion/core/session/account_fence_store.dart';
import 'package:money_companion/core/sync/conflict_resolver.dart';
import 'package:money_companion/core/sync/outbox_failure.dart';
import 'package:money_companion/core/sync/account_fence_retry.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/data/sync/revision_cas.dart';
import 'package:money_companion/data/sync/server_capabilities.dart';
import 'package:money_companion/data/sync/seq_pull.dart';
import 'package:money_companion/core/sync/sync_health.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
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

const _uid = 'user-accounts';
const _accountId = 'account-delivery';
const _commandId = '11111111-2222-3333-4444-555555555555';

Future<List<Map<String, Object?>>> _outbox(AppDatabase db) async => [
  for (final row in await db.customSelect(
      'SELECT * FROM planning_sync_outbox ORDER BY created_at, id;').get()) row.data,
];

Future<Map<String, Object?>> _account(AppDatabase db) async =>
    (await db.customSelect("SELECT server_id, server_updated_at, server_revision, "
        "sync_status, synced_at, is_default FROM accounts WHERE id = '$_accountId';").getSingle()).data;

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

  Future<void> withAccount(Future<void> Function(_AccountHarness) body,
      {bool command = false, LedgerDatabaseProbe? probe}) async {
    final admission = await LedgerAdmissionFixture.open(_uid, probe);
    final harness = _AccountHarness(admission, command);
    try {
      await harness.seed();
      respond = (request) async {
        harness.requests.add(request);
        return harness.respond(request);
      };
      await body(harness);
    } finally {
      for (final release in harness.releases) {
        if (!release.isCompleted) release.complete();
      }
      try {
        await Future.wait(harness.producers);
      } finally {
        await admission.finish();
      }
    }
  }

  for (final command in [false, true]) {
    for (final outcome in ['QD001', 'QD002', 'success']) {
      test('E4 accounts ${command ? 'default command' : 'field'} $outcome through real engine', () async {
        final admission = await LedgerAdmissionFixture.open(_uid);
        final db = admission.database;
        final location = admission.location;
        final downstream = _Downstream();
        final requests = <http.Request>[];
        try {
          final queue = PlanningOutboxQueue(db: db, isSyncEnabled: (_) => true,
              getAuthUserId: () async => _uid,
              getOwnerUid: admission.fixture.session.readLocalDataOwnerUid);
          final repository = DriftAccountRepository(db);
          await repository.create(AccountEntity(id: _accountId, name: 'Synthetic account',
              currency: 'SAR', type: AccountType.bank, isDefault: false, sortOrder: 9,
              createdAt: DateTime.utc(2026, 10, 1), updatedAt: DateTime.utc(2026, 10, 1),
              initialBalanceMoney: Money.fromLegacyReal(10, 'SAR'),
              currentBalanceMoney: Money.fromLegacyReal(10, 'SAR')));
          if (command) {
            // The command resolves this real local target; it does not upload fields.
            await db.customStatement("UPDATE accounts SET server_id = 'server-account' "
                "WHERE id = '$_accountId';");
            await queue.enqueueAccountDefault(_accountId, _commandId);
          } else {
            await queue.enqueueAccount(PlanningSyncOperation.create,
                (await repository.getById(_accountId))!);
          }
          final before = (await _outbox(db)).single;
          final entityBefore = await _account(db);
          final capability = admission.fixture.session.captureLocalWorkAuthority()!;
          expect(capability.isCurrent, isTrue);
          expect(before['owner_uid'], _uid);
          expect(before['operation_id'], isA<String>());
          expect(before['attempt_count'], 0);
          if (command) {
            expect((jsonDecode(before['payload_json'] as String) as Map)['operation_id'], _commandId);
            expect(entityBefore['server_id'], 'server-account');
          }
          respond = (request) async {
            requests.add(request);
            expect(request.method, 'POST');
            expect(request.url.path, command ? '/rest/v1/rpc/set_default_account'
                : '/rest/v1/user_accounts');
            if (command) {
              expect(jsonDecode(request.body), {'p_account_id': 'server-account'});
            } else {
              expect((jsonDecode(request.body) as Map)['user_id'], _uid);
              expect((jsonDecode(request.body) as Map)['local_id'], _accountId);
            }
            final body = outcome == 'success'
                ? command ? null : {'id': 'server-account', 'updated_at': '2026-10-02T00:00:00.000Z'}
                : {'code': outcome, 'message': 'structured account refusal', 'details': null, 'hint': null};
            return http.Response(jsonEncode(body), outcome == 'success' ? 200 : 400,
                headers: {'content-type': 'application/json'}, request: request);
          };
          final engine = PlanningSyncEngine(
            accountsPushService: AccountsPushService(db: db, queue: queue,
                isEnabled: () => true, getAuthUserId: () async => _uid,
                mayEgress: () async => true,
                remoteSink: const SupabaseAccountsRemoteSink()),
            accountsPullService: _AccountsPull(downstream),
            planningPushService: _PlanningPush(downstream),
            planningPullService: _PlanningPull(downstream),
            planningChildSyncService: _Children(downstream),
            startupRegistrationService: _Registration(downstream),
            conflictResolver: _Conflicts(downstream),
          );
          await engine.sync();
          expect(requests, hasLength(1), reason: 'actual SDK mutation reached exactly once');
          if (outcome == 'success') {
            expect(capability.isCurrent, isTrue);
            expect(await _outbox(db), isEmpty, reason: 'the actual mutation ACK consumed its intent');
            expect(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(_uid)), isNull);
            expect(downstream.calls, {
              'account-pull': 1, 'planning-push': 2, 'planning-pull': 1,
              'conflict': 1, 'registration': 1, 'children': 1,
            });
            expect(downstream.settingsCompleted, [true]);
            if (!command) {
              final entity = await _account(db);
              expect(entity['server_id'], 'server-account');
              expect(entity['sync_status'], 'synced');
              expect(entity['synced_at'], isNotNull);
            }
          } else {
            // No future interface/exception is needed: require the public
            // capability, real durable intent and engine effects to be safe.
            expect(capability.isCurrent, isFalse, reason: 'current raw denial must retire original authority');
            expect(AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(_uid))?.state,
                outcome == 'QD001' ? AccountFenceState.pending : AccountFenceState.gone);
            final after = db.lifecycleState == DatabaseLifecycleState.closed
                ? await LedgerAdmissionFixture.inspectClosed(db, location, _outbox)
                : await _outbox(db);
            expect(after, hasLength(1));
            expect(_intent(after.single), _intent(before));
            expect(after.single['attempt_count'], 0);
            expect(after.single['status'], 'parked');
            expect(after.single['failure_class'], outcome == 'QD001'
                ? 'account_deletion_pending' : 'account_deletion_gone');
            expect(after.single['in_flight_seq'], before['op_seq']);
            expect(db.lifecycleState == DatabaseLifecycleState.closed
                ? await LedgerAdmissionFixture.inspectClosed(db, location, _account)
                : await _account(db), entityBefore, reason: 'denial cannot attach or ACK the account');
            expect(downstream.calls, isEmpty, reason: 'denial stops every later engine boundary');
          }
        } finally {
          await admission.finish();
        }
      });
    }
  }

  for (final scenario in [
    (command: false, successor: _uid, response: 'success'),
    (command: false, successor: 'user-B', response: 'QD002'),
    (command: true, successor: _uid, response: 'QD001'),
    (command: true, successor: 'user-B', response: '409'),
    (command: false, successor: _uid, response: 'ordinary'),
  ]) {
    test('E4 accounts stale ${scenario.response} command=${scenario.command} successor=${scenario.successor}', () async {
      await withAccount((h) async {
        final reached = Completer<void>(); final release = h.release();
        h.respond = (request) async {
          reached.complete(); await release.future;
          if (scenario.response == 'ordinary') throw const SocketException('synthetic');
          return h.reply(request, scenario.response);
        };
        final original = h.db; final location = h.admission.location;
        final running = h.track(_stopped(h.service().push()));
        expect(await Future.any([reached.future.then((_) => true), running.then((_) => false)]), isTrue);
        final outbox = await _outbox(original); final account = await _account(original);
        final conflicts = await _conflictsIn(original);
        await h.admission.fixture.signIn(scenario.successor);
        final scope = h.admission.fixture.host.current;
        final cap = h.admission.fixture.session.captureLocalWorkAuthority()!;
        release.complete(); final result = await running;
        expect(result.reason, scenario.response.startsWith('QD')
            ? AccountsDeliveryStopReason.denial : AccountsDeliveryStopReason.stale);
        expect(result.accepted || result.parked || result.complete, isFalse);
        expect(identical(h.admission.fixture.host.current, scope), isTrue);
        expect(cap.isCurrent, isTrue);
        expect(await h.inspect(_outbox, original, location), outbox);
        expect(await h.inspect(_account, original, location), account);
        expect(await h.inspect(_conflictsIn, original, location), conflicts);
        expect(h.requests, hasLength(1));
      }, command: scenario.command);
    });
  }

  for (final code in ['QD001', 'QD002']) {
    test('E4 accounts $code remains authoritative during positive unreadiness', () async {
      await withAccount((h) async {
        final reached = Completer<void>(); final release = h.release();
        h.respond = (request) async { reached.complete(); await release.future; return h.reply(request, code); };
        final cap = h.admission.fixture.session.captureLocalWorkAuthority()!;
        final running = h.track(_stopped(h.service().push()));
        await reached.future;
        final hold = h.admission.fixture.storage.holdOnce((op, key) =>
            op == 'read' && key == AccountFenceStore.storageKey);
        h.releases.add(hold.release);
        final loading = h.track(AccountFenceAuthority.shared.initialize());
        await hold.reached.future;
        expect(cap.isCurrent, isFalse);
        final retired = Completer<void>();
        void listener() {
          if (AccountFenceAuthority.shared.store.holdFor(AccountFenceStore.ownerDigest(_uid)) != null &&
              !retired.isCompleted) { retired.complete(); }
        }
        h.admission.fixture.session.addListener(listener);
        try {
          release.complete();
          expect(await Future.any([retired.future.then((_) => true), running.then((_) => false)]), isTrue);
          expect(cap.isCurrent, isFalse);
        } finally {
          h.admission.fixture.session.removeListener(listener);
          hold.release.complete();
        }
        final result = await running; await loading;
        expect(result.accepted && result.parked && result.complete, isTrue);
        expect(h.db.lifecycleState, DatabaseLifecycleState.closed);
      });
    });
  }

  test('E4 accounts parking and persistence separately drain before close', () async {
    final probe = LedgerDatabaseProbe();
    await withAccount((h) async {
      final parked = Completer<void>(); final release = h.release();
      probe.before = (sql) async {
        if (sql.contains('UPDATE planning_sync_outbox SET status') &&
            sql.contains('account_deletion_') && !parked.isCompleted) {
          parked.complete(); await release.future;
        }
      };
      final readback = Completer<void>();
      final prior = h.admission.fixture.storage.gate;
      h.admission.fixture.storage.gate = (op, key) async {
        await prior?.call(op, key);
        if (op == 'read' && key == AccountFenceStore.storageKey &&
            h.admission.fixture.storage.writesTo(key).isNotEmpty && !readback.isCompleted) { readback.complete(); }
      };
      final writeHold = h.admission.fixture.storage.holdOnce((op, key) =>
          op == 'write' && key == AccountFenceStore.storageKey);
      h.releases.add(writeHold.release);
      h.respond = (request) async => h.reply(request, 'QD002');
      final running = h.track(_stopped(h.service().push()));
      expect(await Future.any([parked.future.then((_) => true), running.then((_) => false)]), isTrue);
      await writeHold.reached.future;
      var committed = false;
      final next = h.track(h.admission.fixture.signIn('user-B').then((_) => committed = true));
      writeHold.release.complete(); await readback.future;
      expect(probe.closeAttempts, 0); expect(committed, isFalse);
      expect(release.isCompleted, isFalse);
      release.complete(); final result = await running; await next;
      expect(result.accepted && result.parked && result.complete, isTrue);
      expect(h.db.lifecycleState, DatabaseLifecycleState.closed);
      expect(h.admission.fixture.host.current?.uid, 'user-B');
    }, probe: probe);
  });

  for (final operation in ['update', 'delete', 'default']) {
    test('E4 accounts concrete $operation busy retry preserves atomic identity', () async {
      await withAccount((h) async {
        await h.changeOperation(operation);
        var mutations = 0;
        h.respond = (request) async {
          if (request.method == 'GET') return h.reply(request, 'lookup');
          mutations++;
          return h.reply(request, mutations == 1 ? '55P03' : 'success', list: operation != 'default');
        };
        final result = await h.service(fenceRetry: AccountFenceRetry(delay: (_) async {})).push();
        expect(result.pushed, 1); expect(mutations, 2);
        final mutationsSent = h.requests.where((r) => r.method != 'GET').toList();
        expect(mutationsSent.first.body, mutationsSent.last.body);
        expect(identical(mutationsSent.first, mutationsSent.last), isFalse);
        if (operation == 'default') expect(jsonDecode(mutationsSent.first.body), {'p_account_id': 'server-account'});
        expect(await _outbox(h.db), isEmpty);
      }, command: operation == 'default');
    });
    test('E4 accounts concrete $operation retry does not dispatch after retirement', () async {
      await withAccount((h) async {
        await h.changeOperation(operation);
        final delayed = Completer<void>(); final release = h.release();
        h.respond = (request) async => h.reply(request, request.method == 'GET' ? 'lookup' : '55P03');
        final handle = (await AccountFenceAuthority.shared.capture(h.admission.fixture.session, h.admission.fixture.host))!;
        final running = h.track(_stopped(h.service(fenceRetry: AccountFenceRetry(delay: (_) async {
          delayed.complete(); await release.future;
        })).push()));
        await delayed.future;
        final denied = h.track(AccountFenceAuthority.shared.accept(handle, AccountFenceState.pending,
            operationId: '00000000-0000-0000-0000-000000000001'));
        release.complete(); await running; await denied;
        expect(h.requests.where((r) => r.method != 'GET'), hasLength(1));
      }, command: operation == 'default');
    });
  }

  for (final id in [null, 'invalid']) {
    test('E4 accounts handout ID ${id == null ? 'legacy null minted' : 'malformed denied'}', () async {
      await withAccount((h) async {
        await h.db.customStatement("UPDATE planning_sync_outbox SET operation_id = ${id == null ? 'NULL' : "'invalid'"};");
        h.respond = (request) async {
          final row = (await _outbox(h.db)).single;
          expect(row['operation_id'], matches(RegExp(r'^[0-9a-fA-F-]{36}$')));
          return h.reply(request, 'success');
        };
        if (id == null) {
          expect((await h.service().push()).pushed, 1); expect(h.requests, hasLength(1));
        } else {
          expect((await _stopped(h.service().push())).reason, AccountsDeliveryStopReason.provenance);
          expect(h.requests, isEmpty);
          expect((await _outbox(h.db)).single['attempt_count'], 0);
        }
      });
    });
  }

  test('E4 accounts one service overlap refuses without disrupting original', () async {
    await withAccount((h) async {
      final reached = Completer<void>(); final release = h.release();
      h.respond = (request) async { reached.complete(); await release.future; return h.reply(request, 'success'); };
      final service = h.service(); final first = h.track(service.push());
      await reached.future;
      expect((await _stopped(service.push())).reason, AccountsDeliveryStopReason.overlap);
      release.complete(); expect((await first).pushed, 1); expect(h.requests, hasLength(1));
    });
  });

  for (final boundary in ['capability', 'head']) {
    test('E4 accounts Gate propagates shared cancellation from $boundary', () async {
      await withAccount((h) async {
        const cancellation = LedgerDeliveryStopped(LedgerDeliveryStopReason.stale);
        final handle = (await AccountFenceAuthority.shared.capture(h.admission.fixture.session, h.admission.fixture.host))!;
        final head = _AccountHead(() async { throw cancellation; });
        final gate = RevisionCasGate(db: h.db, capability: () async {
          if (boundary == 'capability') throw cancellation;
          return ServerCapabilityState.verified;
        }, remote: head);
        await expectLater(gate.planForAccounts(_uid, authority: AccountFenceAuthority.shared,
            handle: handle, database: h.db), throwsA(same(cancellation)));
        expect(head.calls, boundary == 'head' ? 1 : 0);
        expect(h.requests, isEmpty);
      });
    });
  }


  for (final operation in ['update', 'delete', 'default', 'cas']) {
    test('E4 accounts $operation final awaited currency read retires before dispatch', () async {
      final probe = LedgerDatabaseProbe();
      await withAccount((h) async {
        if (operation != 'cas') await h.changeOperation(operation);
        final handle = (await AccountFenceAuthority.shared.capture(h.admission.fixture.session, h.admission.fixture.host))!;
        final reached = Completer<void>(); final cleaned = Completer<void>();
        h.releases.add(cleaned);
        probe.afterSelect = (sql) async {
          if (sql.contains('SELECT 1 FROM planning_sync_outbox') && sql.contains('in_flight_seq') &&
              !reached.isCompleted) {
            reached.complete();
            h.track(AccountFenceAuthority.shared.accept(handle, AccountFenceState.pending,
                operationId: '00000000-0000-0000-0000-000000000001').then((value) {
                  if (!cleaned.isCompleted) cleaned.complete(); return value;
                }));
          }
        };
        final running = h.track(_stopped(h.service(casGate: operation != 'cas' ? null
            : RevisionCasGate(db: h.db, capability: () async => ServerCapabilityState.verified,
                remote: _AccountHead(() async => const SyncHead(lastSeq: 1, epoch: 'e1')))).push()));
        expect(await Future.any([reached.future.then((_) => true), running.then((_) => false)]), isTrue);
        expect((await running).accepted, isFalse); await cleaned.future;
        expect(h.requests, isEmpty, reason: 'no underlying SDK builder after final awaited proof');
      }, command: operation == 'default', probe: probe);
    });
  }

  test('E4 accounts retry auth suspension cannot read successor consent', () async {
    final probe = LedgerDatabaseProbe();
    await withAccount((h) async {
      var auth = 0; var consent = 0; var currentReads = 0;
      final reached = Completer<void>(); final release = h.release();
      probe.afterSelect = (sql) async {
        if (sql.contains('SELECT 1 FROM planning_sync_outbox')) currentReads++;
      };
      final running = h.track(_stopped(h.service(getAuthUserId: () async {
        if (++auth == 2) { reached.complete(); await release.future; }
        return _uid;
      }, mayEgress: () async { consent++; return true; }).push()));
      await reached.future;
      expect(consent, 1); expect(currentReads, 0);
      await h.admission.fixture.signIn(_uid);
      release.complete(); await running;
      expect(consent, 1); expect(currentReads, 0); expect(h.requests, isEmpty);
    }, probe: probe);
  });

  for (final scenario in [
    (operation: 'create', response: 'success'),
    (operation: 'update', response: 'success'),
    (operation: 'delete', response: 'success'),
    (operation: 'create', response: 'QD001'),
    (operation: 'update', response: 'QD002'),
    (operation: 'delete', response: 'QD001'),
    (operation: 'update', response: 'busy-QD002'),
  ]) {
    test('E4 accounts actual CAS ${scenario.operation} ${scenario.response}', () async {
      await withAccount((h) async {
        if (scenario.operation != 'create') await h.changeOperation(scenario.operation);
        await h.db.customStatement("UPDATE accounts SET server_revision = 5 WHERE id = '$_accountId';");
        await h.db.customStatement("UPDATE planning_sync_outbox SET base_revision = 5;");
        final before = (await _outbox(h.db)).single;
        final db = h.db; final location = h.admission.location;
        h.respond = (request) async {
          expect(request.method, 'POST');
          final endpoint = switch (scenario.operation) { 'create' => 'sync_insert_if_absent',
              'update' => 'sync_cas_update', _ => 'sync_cas_tombstone' };
          expect(request.url.path, '/rest/v1/rpc/$endpoint');
          final body = jsonDecode(request.body) as Map;
          expect(body['p_op_id'], before['operation_id']); expect(body['p_expected_epoch'], 'e1');
          if (scenario.operation != 'create') expect(body['p_expected_revision'], 5);
          if (scenario.response.startsWith('busy') && h.requests.length == 1) return h.reply(request, '55P03');
          if (scenario.response.contains('QD')) return h.reply(request, scenario.response.endsWith('QD001') ? 'QD001' : 'QD002');
          return http.Response(jsonEncode({'outcome': scenario.operation == 'create' ? 'inserted' : 'applied',
            'row': {'id': 'server-account', 'updated_at': '2026-10-02T00:00:00Z', 'revision': 6,
              if (scenario.operation == 'delete') 'deleted_at': '2026-10-02T00:00:00Z'}}), 200,
              headers: {'content-type': 'application/json'}, request: request);
        };
        final service = h.service(casGate: RevisionCasGate(db: db,
            capability: () async => ServerCapabilityState.verified,
            remote: _AccountHead(() async => const SyncHead(lastSeq: 1, epoch: 'e1'))),
            fenceRetry: AccountFenceRetry(delay: (_) async {}));
        if (scenario.response == 'success') {
          expect((await service.push()).pushed, 1); expect(await _outbox(db), isEmpty);
        } else {
          final result = await _stopped(service.push());
          expect(result.accepted && result.parked && result.complete, isTrue);
          final row = (await h.inspect(_outbox, db, location)).single;
          expect(_intent(row), _intent(before)); expect(row['attempt_count'], 0);
        }
        expect(h.requests, hasLength(scenario.response.startsWith('busy') ? 2 : 1));
        if (h.requests.length == 2) {
          expect(h.requests.first.body, h.requests.last.body);
          expect(identical(h.requests.first, h.requests.last), isFalse);
        }
      });
    });
  }

  for (final boundary in ['capability', 'recorded', 'head']) {
    test('E4 accounts Gate held $boundary rejects original after replacement', () async {
      final probe = LedgerDatabaseProbe();
      await withAccount((h) async {
        final reached = Completer<void>(); final release = h.release();
        final original = h.db;
        final handle = (await AccountFenceAuthority.shared.capture(h.admission.fixture.session, h.admission.fixture.host))!;
        probe.before = (sql) async {
          if (boundary == 'recorded' && sql.contains('SELECT last_updated_at, last_id') &&
              sql.contains('seq_epoch:') && !reached.isCompleted) { reached.complete(); await release.future; }
        };
        final head = _AccountHead(() async {
          if (boundary == 'head') { reached.complete(); await release.future; }
          return const SyncHead(lastSeq: 1, epoch: 'e1');
        });
        final gate = RevisionCasGate(db: original, capability: () async {
          if (boundary == 'capability') { reached.complete(); await release.future; }
          return ServerCapabilityState.verified;
        }, remote: head);
        final running = h.track(gate.planForAccounts(_uid, authority: AccountFenceAuthority.shared,
            handle: handle, database: original).then<Object?>((value) => value, onError: (Object error) => error));
        expect(await Future.any([reached.future.then((_) => true), running.then((_) => false)]), isTrue);
        var committed = false;
        final successor = h.track(h.admission.fixture.signIn(boundary == 'head' ? _uid : 'user-B').then((_) => committed = true));
        if (boundary == 'recorded') { expect(committed, isFalse); expect(original.lifecycleState, DatabaseLifecycleState.open); }
        release.complete();
        expect(await running, anyOf(isA<AccountsDeliveryStopped>(), isA<StaleAdmissionException>()));
        await successor;
        expect(h.admission.fixture.session.captureLocalWorkAuthority()!.isCurrent, isTrue);
        expect(head.calls, boundary == 'head' ? 1 : 0); expect(h.requests, isEmpty);
      }, probe: probe);
    });
  }

  for (final recorded in [false, true]) {
    test('E4 accounts Gate positive recorded=$recorded', () async {
      await withAccount((h) async {
        if (recorded) await writeRecordedSyncEpoch(h.db, _uid, 'recorded', null);
        final handle = (await AccountFenceAuthority.shared.capture(h.admission.fixture.session, h.admission.fixture.host))!;
        final head = _AccountHead(() async => const SyncHead(lastSeq: 1, epoch: 'head'));
        final result = await RevisionCasGate(db: h.db, capability: () async => ServerCapabilityState.verified,
            remote: head).planForAccounts(_uid, authority: AccountFenceAuthority.shared, handle: handle, database: h.db);
        expect(result.epoch, recorded ? 'recorded' : 'head'); expect(head.calls, recorded ? 0 : 1);
        expect(h.requests, isEmpty);
      });
    });
  }

  test('E4 accounts nullable generic parked reason remains rearmable', () async {
    await withAccount((h) async {
      await h.db.customStatement("UPDATE planning_sync_outbox SET status = 'parked', failure_class = NULL;");
      expect(await h.queue.reArmParked(), 1);
      expect((await _outbox(h.db)).single['status'], 'pending');
    });
  });


  for (final command in [false, true]) {
    test('E4 accounts newer current holder survives old ordinary response command=$command', () async {
      await withAccount((h) async {
        final reached = Completer<void>(); final release = h.release();
        h.respond = (request) async { reached.complete(); await release.future; throw const SocketException('old request'); };
        final running = h.track(h.service().push()); await reached.future;
        if (command) {
          await h.queue.enqueueAccountDefault(_accountId, 'new-payload-command');
        } else {
          final current = (await DriftAccountRepository(h.db).getById(_accountId))!;
          await h.queue.enqueueAccount(PlanningSyncOperation.update, current);
        }
        await h.queue.pendingItems(entityType: command ? PlanningOutboxQueue.accountDefaultCommandType
            : PlanningOutboxQueue.accountsEntityType);
        final row = (await _outbox(h.db)).single; final account = await _account(h.db);
        release.complete(); expect((await running).failed, 1);
        expect((await _outbox(h.db)).single, row);
        expect(await _account(h.db), account);
      }, command: command);
    });
  }

  test('E4 accounts missing returned handout ID is refused before HTTP', () async {
    await withAccount((h) async {
      final service = h.service(outbox: _MissingAccountReceiptQueue(h.db));
      final result = await _stopped(service.push());
      expect(result.reason, AccountsDeliveryStopReason.provenance);
      expect(h.requests, isEmpty);
      final row = (await _outbox(h.db)).single;
      expect(row['operation_id'], isNotNull); expect(row['attempt_count'], 0);
    });
  });

  test('E4 accounts canonical non-v4 durable ID remains valid', () async {
    await withAccount((h) async {
      await h.db.customStatement("UPDATE planning_sync_outbox SET operation_id = 'ffffffff-0000-0000-0000-000000000000';");
      expect((await h.service().push()).pushed, 1); expect(h.requests, hasLength(1));
    });
  });

  test('E4 accounts actual provider construction refuses detached binding', () async {
    await withAccount((h) async {
      final before = await _outbox(h.db);
      final container = ProviderContainer(overrides: [appDatabaseProvider.overrideWithValue(h.db)]);
      h.admission.fixture.session.configureAccountScope(null);
      try {
        final service = container.read(accountsPushServiceProvider);
        expect((await _stopped(service.push())).reason, AccountsDeliveryStopReason.unbound);
        expect(await _outbox(h.db), before);
        expect(await h.db.customSelect("SELECT * FROM sync_cursors WHERE entity = 'sync_health:accounts';").get(), isEmpty);
        // Refusal occurs before SDK lookup; this is construction/refusal only,
        // not configured default-provider transport qualification.
      } finally {
        container.dispose(); h.admission.fixture.session.configureAccountScope(h.admission.fixture.host);
      }
    });
  });

  test('E4 accounts ordinary pre-result health is bound and engine still pulls', () async {
    await withAccount((h) async {
      final health = SyncHealth(db: h.db); final effects = _Downstream();
      final before = await _outbox(h.db);
      final pull = _AccountsPull(effects, run: (from, admitted) async {
        expect(health.of(SyncDomain.accounts).lastErrorClass, SyncErrorClass.offline);
        expect((await h.db.customSelect("SELECT last_id FROM sync_cursors WHERE entity = 'sync_health:accounts';").getSingle()).read<String>('last_id'), contains('offline'));
        return const AccountsPullResult(status: SyncPullStatus.completed);
      });
      await _accountEngine(h.service(getAuthUserId: () async => throw const SocketException('before result'), health: health),
          effects, health: health, pull: pull).sync();
      expect(effects.calls['account-pull'], 1); expect(effects.calls['children'], 1);
      expect(await _outbox(h.db), before); expect(h.requests, isEmpty);
    });
  });

  test('E4 accounts phase identity prevents old error replacing new notes', () async {
    await withAccount((h) async {
      final health = SyncHealth(db: h.db); final reached = Completer<void>(); final release = h.release();
      final old = h.service(health: health, getAuthUserId: () async {
        reached.complete(); await release.future; throw const SocketException('old phase');
      });
      final next = h.service(health: health, mayEgress: () async => false);
      final oldBinding = SyncPhaseBinding(); final nextBinding = SyncPhaseBinding();
      final running = h.track(health.runPhase(SyncDomain.accounts, SyncDirection.push,
          () => old.pushWithPhase(oldBinding), binding: oldBinding));
      await reached.future;
      await health.runPhase(SyncDomain.accounts, SyncDirection.push,
          () => next.pushWithPhase(nextBinding), binding: nextBinding);
      expect(health.of(SyncDomain.accounts).lastErrorClass, SyncErrorClass.consentBlocked);
      final row = (await h.db.customSelect("SELECT * FROM sync_cursors WHERE entity = 'sync_health:accounts';").getSingle()).data;
      release.complete(); await running;
      expect(health.of(SyncDomain.accounts).lastErrorClass, SyncErrorClass.consentBlocked);
      expect(health.of(SyncDomain.accounts).consecutiveFailures, 0);
      expect((await h.db.customSelect("SELECT * FROM sync_cursors WHERE entity = 'sync_health:accounts';").getSingle()).data, row);
    });
  });

  for (final dirty in [false, true]) {
    test('E4 accounts held health save drains before dirty=$dirty pull', () async {
      final probe = LedgerDatabaseProbe();
      await withAccount((h) async {
        final db = h.db; final location = h.admission.location;
        if (dirty) await db.customStatement("INSERT INTO financial_cache_health(entity_type, dirty) VALUES ('accounts', 1);");
        final saving = Completer<void>(); final release = h.release();
        probe.before = (sql) async {
          if (sql.contains('INSERT INTO sync_cursors') && sql.contains('sync_health:accounts') && !saving.isCompleted) {
            saving.complete(); await release.future;
          }
        };
        final handle = (await AccountFenceAuthority.shared.capture(h.admission.fixture.session, h.admission.fixture.host))!;
        final health = SyncHealth(db: db); final effects = _Downstream();
        final running = h.track(_accountEngine(h.service(health: health), effects, health: health).sync(
            reconciler: dirty ? LegacyFinancialCacheReconciler(db: db, generation: 0, isAdmitted: (_) => true) : null));
        expect(await Future.any([saving.future.then((_) => true), running.then((_) => false)]), isTrue);
        final denied = h.track(AccountFenceAuthority.shared.accept(handle, AccountFenceState.pending,
            operationId: '00000000-0000-0000-0000-000000000001'));
        expect(probe.closeAttempts, 0); expect(effects.calls, isEmpty);
        release.complete(); await running; expect((await denied).complete, isTrue);
        expect(effects.calls, isEmpty);
        if (dirty) expect(await h.inspect((db) => isFinancialCacheDirty(db, 'accounts'), db, location), isTrue);
      }, probe: probe);
    });
  }

  for (final dirty in [false, true]) {
    test('E4 accounts current engine reaches normal-or-epoch dirty=$dirty', () async {
      await withAccount((h) async {
        if (dirty) await h.db.customStatement("INSERT INTO financial_cache_health(entity_type, dirty) VALUES ('accounts', 1);");
        final effects = _Downstream(); final froms = <SyncCursor?>[];
        final pull = _AccountsPull(effects, run: (from, admitted) async {
          expect(admitted?.call(), isTrue); froms.add(from);
          return const AccountsPullResult(status: SyncPullStatus.completed);
        });
        final result = await _accountEngine(h.service(), effects, pull: pull).syncParents(
            reconciler: LegacyFinancialCacheReconciler(db: h.db, generation: 0, isAdmitted: (_) => true));
        expect(result.cancelled, isFalse); expect(froms, hasLength(1));
        expect(froms.single?.updatedAt, dirty ? syncCursorEpoch : null);
        expect(await isFinancialCacheDirty(h.db, 'accounts'), isFalse);
      });
    });
  }

  test('E4 accounts retirement after epoch result prevents internal clear', () async {
    await withAccount((h) async {
      final db = h.db; final location = h.admission.location;
      await db.customStatement("INSERT INTO financial_cache_health(entity_type, dirty) VALUES ('accounts', 1);");
      final handle = (await AccountFenceAuthority.shared.capture(h.admission.fixture.session, h.admission.fixture.host))!;
      final effects = _Downstream();
      final pull = _AccountsPull(effects, run: (from, admitted) async {
        expect(from?.updatedAt, syncCursorEpoch);
        h.track(AccountFenceAuthority.shared.accept(handle, AccountFenceState.pending,
            operationId: '00000000-0000-0000-0000-000000000001'));
        return const AccountsPullResult(status: SyncPullStatus.completed);
      });
      final result = await _accountEngine(h.service(), effects, pull: pull).syncParents(
          reconciler: LegacyFinancialCacheReconciler(db: db, generation: 0, isAdmitted: (_) => true));
      expect(result.cancelled, isTrue); await Future.wait(h.producers);
      expect(await h.inspect((db) => isFinancialCacheDirty(db, 'accounts'), db, location), isTrue);
      expect(effects.calls, {'account-pull': 1});
    });
  });

  test('E4 accounts started atomic clear terminal event precedes physical close', () async {
    final probe = LedgerDatabaseProbe();
    await withAccount((h) async {
      final db = h.db;
      await db.customStatement("INSERT INTO financial_cache_health(entity_type, dirty) VALUES ('accounts', 1);");
      final clear = Completer<void>(); final release = h.release();
      final readback = Completer<void>(); final closeStarted = Completer<void>();
      var terminal = false; var closeBeforeTerminal = false;
      final handle = (await AccountFenceAuthority.shared.capture(h.admission.fixture.session, h.admission.fixture.host))!;
      probe.before = (sql) async {
        if (sql.contains('INSERT INTO financial_cache_health') && sql.contains('repaired_at') && !clear.isCompleted) {
          clear.complete(); await release.future;
        }
      };
      probe.onClose = () { if (!terminal) closeBeforeTerminal = true; if (!closeStarted.isCompleted) closeStarted.complete(); };
      final effects = _Downstream();
      final running = h.track(_accountEngine(h.service(), effects).syncParents(
          reconciler: LegacyFinancialCacheReconciler(db: db, generation: 0, isAdmitted: (_) => true)));
      expect(await Future.any([clear.future.then((_) => true), running.then((_) => false)]), isTrue);
      final previous = h.admission.fixture.storage.gate;
      h.admission.fixture.storage.gate = (op, key) async {
        await previous?.call(op, key);
        if (op == 'read' && key == AccountFenceStore.storageKey &&
            h.admission.fixture.storage.writesTo(key).isNotEmpty && !readback.isCompleted) { readback.complete(); }
      };
      final denied = h.track(AccountFenceAuthority.shared.accept(handle, AccountFenceState.pending,
          operationId: '00000000-0000-0000-0000-000000000001'));
      expect(await Future.any([readback.future.then((_) => true), closeStarted.future.then((_) => false)]), isTrue);
      expect(probe.closeAttempts, 0);
      probe.afterTransactionSettled = () => terminal = true;
      release.complete(); expect((await running).cancelled, isTrue); expect((await denied).complete, isTrue);
      expect(terminal, isTrue); expect(closeBeforeTerminal, isFalse);
      expect(effects.calls, {'account-pull': 1});
    }, probe: probe);
  });


  for (final code in ['QD001', 'QD002']) {
    test('E4 accounts privileged lower-layer $code hold survives rearm coalesce create-delete', () async {
      await withAccount((h) async {
        final original = h.db; final location = h.admission.location;
        final capability = h.admission.fixture.session.captureLocalWorkAuthority()!;
        final before = (await _outbox(original)).single;
        h.respond = (request) async => h.reply(request, code);
        final result = await _stopped(h.service().push());
        expect(result.accepted && result.parked && result.complete, isTrue);
        expect(original.lifecycleState, DatabaseLifecycleState.closed);
        expect(File(location.dbPath).existsSync(), isTrue);
        expect(await SecureDatabaseKeyStore(storageKey: location.keyName,
            databaseExists: () => File(location.dbPath).exists()).readStoredKey(), isNotNull);
        final durable = h.admission.fixture.storage.data[AccountFenceStore.storageKey];
        // Privileged queue mechanism qualification only: this existing replica
        // is never attached, published, admitted or used for delivery.
        final mechanism = await AppDatabase.open(location: location, runMigrations: false,
            creation: const CreationPolicy.denied());
        try {
          final queue = PlanningOutboxQueue(db: mechanism, isSyncEnabled: (_) => true,
              getAuthUserId: () async => _uid,
              getOwnerUid: h.admission.fixture.session.readLocalDataOwnerUid);
          await queue.reArmParked(); await queue.reArmAuthParked();
          await queue.reArmDeadLetter(); await queue.reArmRetryableDeadLetters();
          await queue.reconcileOwnership(_uid);
          final account = (await DriftAccountRepository(mechanism).getById(_accountId))!;
          await queue.enqueueAccount(PlanningSyncOperation.update, account.copyWith(name: 'new intent'));
          final edited = (await _outbox(mechanism)).single;
          expect(edited['id'], before['id']); expect(edited['op_seq'], (before['op_seq'] as int) + 1);
          expect(edited['status'], 'parked'); expect(edited['failure_class'], code == 'QD001'
              ? kParkAccountDeletionPending : kParkAccountDeletionGone);
          expect(edited['attempt_count'], 0); expect(edited['operation_id'], isNot(before['operation_id']));
          expect((jsonDecode(edited['payload_json'] as String) as Map)['name'], 'new intent');
          expect((jsonDecode(edited['payload_json'] as String) as Map)['prior_op_ids'], contains(before['operation_id']));
          await queue.enqueueAccount(PlanningSyncOperation.delete, account);
          final deleted = (await _outbox(mechanism)).single;
          expect(deleted['id'], before['id']); expect(deleted['operation'], 'delete');
          expect(deleted['status'], 'parked'); expect(deleted['failure_class'], edited['failure_class']);
          expect(deleted['attempt_count'], 0);
          expect(await queue.pendingItems(), isEmpty);
        } finally { await mechanism.close(); expect(mechanism.lifecycleState, DatabaseLifecycleState.closed); }
        expect(capability.isCurrent, isFalse);
        expect(h.admission.fixture.storage.data[AccountFenceStore.storageKey], durable);
        final rebuilt = AccountFenceStore(); expect(await rebuilt.load(), isTrue);
        expect(rebuilt.holdFor(AccountFenceStore.ownerDigest(_uid))?.state,
            code == 'QD001' ? AccountFenceState.pending : AccountFenceState.gone);
        await expectLater(h.admission.fixture.signIn(_uid), throwsA(isA<AccountFenceDeniedException>()));
        expect(h.requests, hasLength(1));
      });
    });
  }

  for (final holder in ['original', 'newer', 'null']) {
    test('E4 accounts late denial conditional parking holder=$holder', () async {
      await withAccount((h) async {
        final db = h.db; final location = h.admission.location;
        final reached = Completer<void>(); final release = h.release();
        h.respond = (request) async { reached.complete(); await release.future; return h.reply(request, 'QD001'); };
        final running = h.track(_stopped(h.service().push())); await reached.future;
        final account = (await DriftAccountRepository(db).getById(_accountId))!;
        await h.queue.enqueueAccount(PlanningSyncOperation.update, account.copyWith(name: 'second'));
        if (holder != 'original') {
          final second = (await h.queue.pendingItems(entityType: PlanningOutboxQueue.accountsEntityType)).single;
          if (holder == 'null') {
            await h.queue.enqueueAccount(PlanningSyncOperation.update, account.copyWith(name: 'third'));
            await h.queue.acknowledge(second);
            expect((await _outbox(db)).single['in_flight_seq'], isNull);
          }
        }
        final before = (await _outbox(db)).single;
        release.complete(); final result = await running;
        expect(result.accepted, isTrue); expect(result.parked, holder == 'original');
        expect(result.complete, holder == 'original');
        final after = (await h.inspect(_outbox, db, location)).single;
        expect(_intent(after), _intent(before)); expect(after['attempt_count'], before['attempt_count']);
        expect(after['in_flight_seq'], before['in_flight_seq']);
        if (holder == 'original') {
          expect(after['status'], 'parked'); expect(after['failure_class'], kParkAccountDeletionPending);
        } else { expect(after, before); }
      });
    });
  }

  test('E4 accounts late ordinary failure cannot clobber NULL holder after successor ACK', () async {
    await withAccount((h) async {
      final reached = Completer<void>(); final release = h.release();
      h.respond = (request) async { reached.complete(); await release.future; throw const SocketException('late'); };
      final running = h.track(h.service().push()); await reached.future;
      final account = (await DriftAccountRepository(h.db).getById(_accountId))!;
      await h.queue.enqueueAccount(PlanningSyncOperation.update, account.copyWith(name: 'second'));
      final second = (await h.queue.pendingItems(entityType: PlanningOutboxQueue.accountsEntityType)).single;
      await h.queue.enqueueAccount(PlanningSyncOperation.update, account.copyWith(name: 'third'));
      await h.queue.acknowledge(second);
      final before = (await _outbox(h.db)).single;
      expect(before['in_flight_seq'], isNull);
      release.complete(); expect((await running).failed, 1);
      expect((await _outbox(h.db)).single, before);
    });
  });


  test('E4 accounts held owner proof cannot start reconciliation after retirement', () async {
    final probe = LedgerDatabaseProbe();
    await withAccount((h) async {
      final handle = (await AccountFenceAuthority.shared.capture(h.admission.fixture.session, h.admission.fixture.host))!;
      final reached = Completer<void>(); final release = h.release();
      final ownerQueue = PlanningOutboxQueue(db: h.db, isSyncEnabled: (_) => true,
          getAuthUserId: () async => _uid, getOwnerUid: () async {
            final owner = await h.admission.fixture.session.readLocalDataOwnerUid();
            reached.complete(); await release.future; return owner;
          });
      var reconciliationWrites = 0;
      probe.before = (sql) async {
        if (sql.contains('UPDATE planning_sync_outbox') && sql.contains('owner_mismatch')) reconciliationWrites++;
      };
      final running = h.track(_stopped(h.service(outbox: ownerQueue).push()));
      await reached.future;
      final denied = h.track(AccountFenceAuthority.shared.accept(handle, AccountFenceState.pending,
          operationId: '00000000-0000-0000-0000-000000000001'));
      release.complete(); await running; await denied;
      expect(reconciliationWrites, 0); expect(h.requests, isEmpty);
    }, probe: probe);
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
  _AccountsPull(this.effects, {this.run});
  final Future<AccountsPullResult> Function(SyncCursor?, bool Function()?)? run;
  final _Downstream effects;
  @override
  Future<AccountsPullResult> pull({SyncCursor? from, bool Function()? isAdmitted}) async {
    effects.called('account-pull');
    if (run != null) return run!(from, isAdmitted);
    return const AccountsPullResult(status: SyncPullStatus.completed);
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('unexpected account pull method');
}

class _PlanningPush implements PlanningPushService {
  _PlanningPush(this.effects);
  final _Downstream effects;
  @override
  Future<PlanningPushResult> push() async {
    effects.called('planning-push'); return const PlanningPushResult();
  }
  @override
  Future<PlanningPushResult> pushWithPhase(SyncPhaseBinding phase) => push();
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('unexpected planning push method');
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


Future<List<Map<String, Object?>>> _conflictsIn(AppDatabase db) async =>
    (await db.customSelect('SELECT * FROM sync_conflicts;').get()).map((r) => r.data).toList();

Future<AccountsDeliveryStopped> _stopped(Future<Object?> work) async {
  try { await work; throw StateError('expected exact account stop'); }
  on AccountsDeliveryStopped catch (error) { return error; }
}

class _AccountHead implements SeqRemote {
  _AccountHead(this.read);
  final Future<SyncHead?> Function() read;
  int calls = 0;
  @override
  Future<SyncHead?> fetchHead(String uid) { calls++; return read(); }
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('unexpected sequence call');
}

class _AccountHarness {
  _AccountHarness(this.admission, this.command);
  final LedgerAdmissionFixture admission;
  final bool command;
  AppDatabase get db => admission.database;
  final requests = <http.Request>[];
  final releases = <Completer<void>>[];
  final producers = <Future<Object?>>[];
  late Future<http.Response> Function(http.Request) respond;
  Completer<void> release() { final c = Completer<void>(); releases.add(c); return c; }
  Future<T> track<T>(Future<T> future) { producers.add(future); return future; }

  Future<void> seed() async {
    final repository = DriftAccountRepository(db);
    final account = AccountEntity(id: _accountId, name: 'Synthetic account', currency: 'SAR',
      type: AccountType.bank, isDefault: false, sortOrder: 9,
      createdAt: DateTime.utc(2026, 10, 1), updatedAt: DateTime.utc(2026, 10, 1),
      initialBalanceMoney: Money(10, 'SAR'), currentBalanceMoney: Money(10, 'SAR'));
    await repository.create(account);
    if (command) {
      await db.customStatement("UPDATE accounts SET server_id = 'server-account' WHERE id = '$_accountId';");
      await queue.enqueueAccountDefault(_accountId, _commandId);
    } else {
      await queue.enqueueAccount(PlanningSyncOperation.create, account);
    }
    respond = (request) async => reply(request, 'success');
  }

  PlanningOutboxQueue get queue => PlanningOutboxQueue(db: db, isSyncEnabled: (_) => true,
      getAuthUserId: () async => _uid, getOwnerUid: admission.fixture.session.readLocalDataOwnerUid);

  AccountsPushService service({AccountFenceRetry? fenceRetry, RevisionCasGate? casGate,
      Future<bool> Function()? mayEgress, Future<String?> Function()? getAuthUserId,
      SyncHealth? health, PlanningOutboxQueue? outbox}) => AccountsPushService(db: db, queue: outbox ?? queue,
      isEnabled: () => true, getAuthUserId: getAuthUserId ?? () async => _uid,
      remoteSink: const SupabaseAccountsRemoteSink(), mayEgress: mayEgress ?? () async => true,
      health: health, fenceRetry: fenceRetry, casGate: casGate);

  Future<void> changeOperation(String operation) async {
    if (operation == 'default') return;
    await db.customStatement("UPDATE accounts SET server_id = 'server-account', server_updated_at = 'base' WHERE id = '$_accountId';");
    await db.customStatement("UPDATE planning_sync_outbox SET operation = '$operation', "
      "payload_json = json_set(payload_json, '\$.server_updated_at', 'base');");
  }

  http.Response reply(http.Request request, String outcome, {bool list = false}) {
    if (outcome != 'success' && outcome != 'lookup') {
      return http.Response(jsonEncode({'code': outcome, 'message': 'synthetic refusal'}), 400,
          headers: {'content-type': 'application/json'}, request: request);
    }
    final row = {'id': 'server-account', 'updated_at': '2026-10-02T00:00:00Z',
      'revision': 2, if (request.method == 'PATCH') 'deleted_at': '2026-10-02T00:00:00Z'};
    return http.Response(jsonEncode(request.url.path.endsWith('set_default_account') ? null
        : (list || request.method == 'PATCH') ? [row] : row), 200,
        headers: {'content-type': 'application/json'}, request: request);
  }

  Future<T> inspect<T>(Future<T> Function(AppDatabase) read, AppDatabase original,
      ReplicaLocation location) => original.lifecycleState == DatabaseLifecycleState.closed
          ? LedgerAdmissionFixture.inspectClosed(original, location, read) : read(original);
}


PlanningSyncEngine _accountEngine(AccountsPushService push, _Downstream effects,
    {SyncHealth? health, AccountsPullService? pull}) => PlanningSyncEngine(
  accountsPushService: push, accountsPullService: pull ?? _AccountsPull(effects),
  planningPushService: _PlanningPush(effects), planningPullService: _PlanningPull(effects),
  planningChildSyncService: _Children(effects), startupRegistrationService: _Registration(effects),
  conflictResolver: _Conflicts(effects), health: health);

class _MissingAccountReceiptQueue extends PlanningOutboxQueue {
  _MissingAccountReceiptQueue(AppDatabase db) : super(db: db, isSyncEnabled: (_) => true,
      getAuthUserId: () async => _uid);
  @override
  Future<List<PlanningOutboxItem>> pendingItems({String? entityType, int limit = 50}) async => [
    for (final item in await super.pendingItems(entityType: entityType, limit: limit))
      PlanningOutboxItem(id: item.id, entityType: item.entityType, entityId: item.entityId,
        operation: item.operation, payloadJson: item.payloadJson, attemptCount: item.attemptCount,
        opSeq: item.opSeq, operationId: null, baseRevision: item.baseRevision,
        ownerUid: item.ownerUid, lastError: item.lastError, nextRetryAt: item.nextRetryAt),
  ];
}
