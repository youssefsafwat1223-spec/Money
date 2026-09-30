import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/sync/conflict_resolver.dart';
import 'package:money_companion/core/sync/sync_health.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/features/capture/services/ledger_push_service.dart';
import 'package:money_companion/features/capture/services/ledger_sync_engine.dart';
import 'package:money_companion/features/capture/services/ledger_sync_service.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/features/planning_sync/services/accounts_pull_service.dart';
import 'package:money_companion/features/planning_sync/services/accounts_push_service.dart';
import 'package:money_companion/features/planning_sync/services/outbox_queue_factory.dart';
import 'package:money_companion/features/planning_sync/services/planning_child_sync_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_pull_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_push_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_startup_registration_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_sync_engine.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

const _sentinel = 'SENTINEL-4242 amount=99.95 user@example.com Carrefour';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

class _Push implements LedgerPushAdapter {
  _Push(this.body);
  final Future<LedgerPushResult> Function() body;
  @override
  Future<LedgerPushResult> push() => body();
}

class _Pull implements LedgerPullAdapter {
  _Pull(this.body);
  final Future<LedgerSyncResult> Function() body;
  @override
  Future<LedgerSyncResult> pull({SyncCursor? from, bool Function()? isAdmitted}) =>
      body();
}

class _ThrowingAccountsSource implements AccountsRemoteSource {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw const SocketException(_sentinel); // a transport failure with user data
}

class _ThrowingPlanningSource implements PlanningRemoteSource {
  @override
  dynamic noSuchMethod(Invocation i) => throw const SocketException(_sentinel);
}

void main() {
  late AppDatabase db;
  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
  });
  tearDown(() async => db.close());

  group('SyncHealth core', () {
    test('success records the direction and resets the failure streak',
        () async {
      var t = DateTime.utc(2026, 1, 1);
      final h = SyncHealth(clock: () => t);
      await h.runPhase(SyncDomain.ledger, SyncDirection.push,
          () async => throw const SocketException('x'));
      await h.runPhase(SyncDomain.ledger, SyncDirection.push,
          () async => throw const SocketException('x'));
      expect(h.of(SyncDomain.ledger).consecutiveFailures, 2);

      t = DateTime.utc(2026, 1, 2);
      await h.runPhase(SyncDomain.ledger, SyncDirection.push, () async {});
      final s = h.of(SyncDomain.ledger);
      expect(s.lastPushSuccessAt, DateTime.utc(2026, 1, 2));
      expect(s.lastPullSuccessAt, isNull);
      expect(s.consecutiveFailures, 0);
      // A real error stays as history.
      expect(s.lastErrorClass, SyncErrorClass.offline);
    });

    test('failure classes are coarse and never carry the message', () async {
      final h = SyncHealth(db: db);
      final cases = <Object, SyncErrorClass>{
        const SocketException(_sentinel): SyncErrorClass.offline,
        TimeoutException(_sentinel): SyncErrorClass.offline,
        const PostgrestException(message: _sentinel, code: '23505'):
            SyncErrorClass.conflict,
        const PostgrestException(message: _sentinel, code: '401'):
            SyncErrorClass.auth,
        const PostgrestException(message: _sentinel, code: '23502'):
            SyncErrorClass.serverRejected,
        StateError(_sentinel): SyncErrorClass.unknown,
        Exception(_sentinel): SyncErrorClass.unknown,
      };
      for (final e in cases.entries) {
        await h.runPhase(
            SyncDomain.planning, SyncDirection.push, () async => throw e.key);
        expect(h.of(SyncDomain.planning).lastErrorClass, e.value,
            reason: '${e.key.runtimeType}');
      }
      // Sentinel: nothing in memory or on disk may contain any error text.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final blob = h.all.values.map((v) => v.toJson()).toString();
      expect(blob, isNot(contains('SENTINEL')));
      expect(blob, isNot(contains('user@example.com')));
      final persisted =
          await db.customSelect('SELECT * FROM sync_cursors').get();
      expect(persisted, isNotEmpty);
      expect(persisted.map((r) => r.data).toString(),
          isNot(contains('SENTINEL')));
      expect(persisted.map((r) => r.data).toString(),
          isNot(contains('Carrefour')));
    });

    test('a swallowed failure noted by a service still fails the phase',
        () async {
      final h = SyncHealth();
      await h.runPhase(SyncDomain.accounts, SyncDirection.pull, () async {
        h.noteFailure(SyncDomain.accounts, const SocketException(_sentinel));
      });
      final s = h.of(SyncDomain.accounts);
      expect(s.lastErrorClass, SyncErrorClass.offline);
      expect(s.consecutiveFailures, 1);
      expect(s.lastPullSuccessAt, isNull);
    });

    test('consentBlocked is ONE state: no spam, no failure streak, clears on '
        'success', () async {
      var t = DateTime.utc(2026, 1, 1);
      final h = SyncHealth(clock: () => t);
      for (var i = 0; i < 5; i++) {
        t = t.add(const Duration(minutes: 1));
        await h.runPhase(SyncDomain.smartInbox, SyncDirection.pull,
            () async => h.noteConsentBlocked(SyncDomain.smartInbox));
      }
      var s = h.of(SyncDomain.smartInbox);
      expect(s.lastErrorClass, SyncErrorClass.consentBlocked);
      expect(s.consecutiveFailures, 0);
      expect(s.lastErrorAt, DateTime.utc(2026, 1, 1, 0, 1),
          reason: 'entered once; re-entering does not rewrite the timestamp');
      expect(s.lastPullSuccessAt, isNull);

      await h.runPhase(SyncDomain.smartInbox, SyncDirection.pull, () async {});
      s = h.of(SyncDomain.smartInbox);
      expect(s.lastErrorClass, isNull);
      expect(s.lastPullSuccessAt, isNotNull);
    });

    test('capabilityParked is a state, not a failure', () async {
      final h = SyncHealth();
      await h.runPhase(SyncDomain.ledger, SyncDirection.push,
          () async => h.noteCapabilityParked(SyncDomain.ledger));
      final s = h.of(SyncDomain.ledger);
      expect(s.lastErrorClass, SyncErrorClass.capabilityParked);
      expect(s.consecutiveFailures, 0);
    });

    test('state survives a restart (persisted in sync_cursors)', () async {
      final a = SyncHealth(db: db);
      await a.runPhase(SyncDomain.engagement, SyncDirection.push, () async {});
      await a.runPhase(SyncDomain.ledger, SyncDirection.pull,
          () async => throw const SocketException(_sentinel));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final b = SyncHealth();
      await b.attach(db);
      expect(b.of(SyncDomain.engagement).lastPushSuccessAt, isNotNull);
      expect(b.of(SyncDomain.ledger).lastErrorClass, SyncErrorClass.offline);
      expect(b.of(SyncDomain.ledger).consecutiveFailures, 1);
    });

    test('queue counts come from the outboxes', () async {
      Future<void> ledger(String id, String status) => db.customStatement('''
        INSERT INTO ledger_sync_outbox(id, transaction_id, operation,
          payload_json, attempt_count, status, created_at, updated_at)
        VALUES ('$id', 't$id', 'create', '{}', 0, '$status',
          '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z');''');
      Future<void> planning(String id, String status) => db.customStatement('''
        INSERT INTO planning_sync_outbox(id, entity_type, entity_id, operation,
          payload_json, attempt_count, created_at, updated_at, status)
        VALUES ('$id', 'budget', 'e$id', 'create', '{}', 0,
          '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', '$status');''');
      await ledger('a', 'pending');
      await ledger('b', 'parked');
      await planning('c', 'pending');
      await planning('d', 'dead_letter');
      await planning('e', 'dead_letter');
      await db.customStatement('''
        INSERT INTO smart_inbox_items(id, server_id, type, title, status,
          server_created_at, synced_at, pending_sync, created_at, updated_at)
        VALUES ('i1', 's1', 'x', 't', 'open', '2026-01-01T00:00:00Z',
          '2026-01-01T00:00:00Z', 1, '2026-01-01T00:00:00Z',
          '2026-01-01T00:00:00Z');''');
      Future<void> mapping(String id, String sync) => db.customStatement('''
        INSERT INTO sender_bank_mappings(id, sender_id, normalized_sender_id,
          suggested_bank_name, suggested_country, confidence, status, source,
          first_seen_at, last_seen_at, confirmed_at, created_at, updated_at,
          sync_status)
        VALUES ('$id', '$id', '$id', 'B', 'SA', 0.9, 'confirmed',
          'user_manual', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z',
          '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z',
          '2026-01-01T00:00:00Z', '$sync');''');
      await mapping('m1', 'pending');
      await mapping('m2', 'failed');
      await mapping('m3', 'failed');

      final c = await SyncHealth.queueCounts(db);
      expect(c.pending, 2);
      expect(c.parked, 1);
      expect(c.deadLetter, 2);
      expect(c.senderMappingsPending, 1);
      expect(c.senderMappingsFailed, 2);
      expect(c.smartInboxPendingSync, 1);
    });
  });

  group('orchestrated phases record into SyncHealth', () {
    test('ledger engine: success, failure and consentBlocked', () async {
      final h = SyncHealth();
      await LedgerSyncEngine(
        pushService: _Push(() async => const LedgerPushResult()),
        pullService: _Pull(() async => const LedgerSyncResult()),
        health: h,
      ).sync();
      expect(h.of(SyncDomain.ledger).lastPushSuccessAt, isNotNull);
      expect(h.of(SyncDomain.ledger).lastPullSuccessAt, isNotNull);

      await LedgerSyncEngine(
        pushService: _Push(() async => throw const SocketException(_sentinel)),
        pullService: _Pull(() async {
          h.noteConsentBlocked(SyncDomain.ledger);
          return const LedgerSyncResult();
        }),
        health: h,
      ).sync();
      final s = h.of(SyncDomain.ledger);
      expect(s.lastErrorClass, SyncErrorClass.consentBlocked,
          reason: 'the last phase (pull) was consent-blocked');
      expect(s.consecutiveFailures, 1, reason: 'the push failure counted');
    });

    PlanningSyncEngine engine(SyncHealth h, Future<bool> Function() consent,
        {bool throwing = false}) {
      final queue = buildPlanningOutboxQueue(db);
      return PlanningSyncEngine(
        accountsPushService: AccountsPushService(
          db: db,
          queue: queue,
          isEnabled: () => true,
          getAuthUserId: () async => 'u',
          mayEgress: consent,
          health: h,
        ),
        accountsPullService: AccountsPullService(
          db: db,
          isEnabled: () => true,
          getAuthUserId: () async => 'u',
          remoteSource: throwing ? _ThrowingAccountsSource() : null,
          mayEgress: consent,
          health: h,
        ),
        planningPushService: PlanningPushService(
          db: db,
          queue: queue,
          isEnabled: (_) => true,
          getAuthUserId: () async => 'u',
          mayEgress: consent,
          health: h,
        ),
        planningPullService: PlanningPullService(
          db: db,
          isEnabled: (_) => true,
          getAuthUserId: () async => 'u',
          remoteSource: throwing ? _ThrowingPlanningSource() : null,
          mayEgress: consent,
          health: h,
        ),
        planningChildSyncService: PlanningChildSyncService(
          db: db,
          queue: queue,
          isEnabled: (_) => true,
          getAuthUserId: () async => 'u',
          mayEgress: consent,
          health: h,
        ),
        startupRegistrationService: PlanningStartupRegistrationService(
          db: db,
          queue: queue,
          isEnabled: (_) => false,
        ),
        conflictResolver: UniversalConflictResolver(db: db, reEnqueue: {}),
        health: h,
      );
    }

    test('planning engine, consent OFF: every domain is consentBlocked',
        () async {
      final h = SyncHealth();
      await engine(h, () async => false).sync();
      for (final d in [
        SyncDomain.accounts,
        SyncDomain.planning,
        SyncDomain.children,
      ]) {
        final s = h.of(d);
        expect(s.lastErrorClass, SyncErrorClass.consentBlocked, reason: '$d');
        expect(s.consecutiveFailures, 0, reason: '$d');
        expect(s.lastPushSuccessAt, isNull, reason: '$d');
        expect(s.lastPullSuccessAt, isNull, reason: '$d');
      }
    });

    test('planning engine, consent ON: a swallowed pull failure is recorded '
        'as a failure class, never as text', () async {
      final h = SyncHealth();
      await engine(h, () async => true, throwing: true).sync();
      expect(h.of(SyncDomain.accounts).lastPushSuccessAt, isNotNull);
      expect(h.of(SyncDomain.accounts).lastPullSuccessAt, isNull);
      expect(h.of(SyncDomain.accounts).lastErrorClass, SyncErrorClass.offline);
      expect(h.of(SyncDomain.planning).lastErrorClass, SyncErrorClass.offline);
      expect(h.all.values.map((v) => v.toJson()).toString(),
          isNot(contains('SENTINEL')));
    });
  });
}
