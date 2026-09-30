import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/privacy/consent_authority.dart';
import 'package:money_companion/core/sync/sync_health.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_dedup_store.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/data/sync/exact_transport_capability.dart';
import 'package:money_companion/data/sync/sender_bank_mapping_sync_service.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/capture/services/ledger_push_service.dart';
import 'package:money_companion/features/capture/services/ledger_sync_service.dart';
import 'package:money_companion/features/capture/services/smart_inbox_sync_service.dart';
import 'package:money_companion/features/gamification/services/engagement_event_service.dart';
import 'package:money_companion/features/planning_sync/services/accounts_pull_service.dart';
import 'package:money_companion/features/planning_sync/services/accounts_push_service.dart';
import 'package:money_companion/features/planning_sync/services/outbox_queue_factory.dart';
import 'package:money_companion/features/planning_sync/services/planning_child_sync_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';
import 'package:money_companion/features/planning_sync/services/planning_pull_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_push_service.dart';

/// Phase A-1a — every sync PUSH and PULL path for user data asks consent at the
/// moment of egress. With consent OFF there is NO client call and durable rows
/// stay exactly as they were (pending, attempt_count untouched); with consent ON
/// the service proceeds to its next gate / the client.
///
/// The "client" in each test is a tripwire: any call on it is counted, and the
/// consent-OFF assertions demand zero.
class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

class _Trip {
  int calls = 0;
  dynamic hit(Invocation i) {
    calls++;
    throw StateError('unexpected client call: ${i.memberName}');
  }
}

class _TripSink extends _Trip implements PlanningRemoteSink {
  @override
  dynamic noSuchMethod(Invocation i) => hit(i);
}

class _TripPlanningSource extends _Trip implements PlanningRemoteSource {
  final tables = <String>[];
  @override
  Future<List<Map<String, dynamic>>> fetchRows(String table,
      {required dynamic after, int limit = 200}) async {
    calls++;
    tables.add(table);
    return const [];
  }

  @override
  dynamic noSuchMethod(Invocation i) => hit(i);
}

class _TripAccountsSink extends _Trip implements AccountsRemoteSink {
  @override
  dynamic noSuchMethod(Invocation i) => hit(i);
}

class _TripAccountsSource extends _Trip implements AccountsRemoteSource {
  @override
  dynamic noSuchMethod(Invocation i) => hit(i);
}

class _TripLedgerSource extends _Trip implements LedgerRemoteSource {
  @override
  dynamic noSuchMethod(Invocation i) => hit(i);
}

class _TripChildRemote extends _Trip implements PlanningChildRemote {
  @override
  dynamic noSuchMethod(Invocation i) => hit(i);
}

class _TripInboxSource extends _Trip implements SmartInboxRemoteSource {
  @override
  dynamic noSuchMethod(Invocation i) => hit(i);
}

class _TripMappingStore extends _Trip implements SenderMappingRemoteStore {
  @override
  dynamic noSuchMethod(Invocation i) => hit(i);
}

class _TripRecorder extends _Trip implements EngagementRemoteRecorder {
  @override
  dynamic noSuchMethod(Invocation i) => hit(i);
}

/// Records consent-OFF patches; everything else trips.
class _RecordingSettingsSink extends _Trip implements PlanningRemoteSink {
  final upserts = <Map<String, dynamic>>[];
  final updates = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> upsert(
      String table, Map<String, dynamic> row) async {
    upserts.add(row);
    return {'id': 'srv', 'updated_at': 't1', 'revision': 1};
  }

  @override
  Future<Map<String, dynamic>?> updateByServerId(
      String table, String serverId, Map<String, dynamic> row) async {
    updates.add(row);
    return {'id': serverId, 'updated_at': 't2', 'revision': 2};
  }

  @override
  dynamic noSuchMethod(Invocation i) => hit(i);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
  });
  tearDown(() async => db.close());

  Future<void> seedPlanningRow(String type, String op, Map<String, dynamic> p,
      {String id = 'o1', String entityId = 'e1'}) async {
    await db.customStatement('''
      INSERT INTO planning_sync_outbox(
        id, entity_type, entity_id, operation, payload_json,
        attempt_count, created_at, updated_at, status
      ) VALUES ('$id', '$type', '$entityId', '$op',
        '${jsonEncode(p).replaceAll("'", "''")}', 0,
        '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 'pending');
    ''');
  }

  Future<List<Map<String, Object?>>> rows(String table) async => [
        for (final r in await db
            .customSelect('SELECT id, status, attempt_count, next_retry_at, '
                'last_error FROM $table ORDER BY id;')
            .get())
          r.data
      ];

  // ---------------------------------------------------------------- planning
  group('planning push (G13)', () {
    PlanningPushService service(_Trip sink, Future<bool> Function()? gate,
            {SyncHealth? health}) =>
        PlanningPushService(
          db: db,
          queue: buildPlanningOutboxQueue(db),
          isEnabled: (_) => true,
          getAuthUserId: () async => 'user-1',
          remoteSink: sink as PlanningRemoteSink,
          mayEgress: gate,
          health: health,
        );

    test('consent OFF: no client call, row untouched (budget)', () async {
      await seedPlanningRow('budget', 'create', {'local_id': 'e1'});
      final before = await rows('planning_sync_outbox');
      final sink = _TripSink();

      final r = await service(sink, () async => false).push();

      expect(sink.calls, 0);
      expect(r.pushed + r.failed + r.parked, 0);
      expect(await rows('planning_sync_outbox'), before);
    });

    test('omitting the gate fails CLOSED', () async {
      await seedPlanningRow('budget', 'create', {'local_id': 'e1'});
      final before = await rows('planning_sync_outbox');
      final sink = _TripSink();
      await service(sink, null).push();
      expect(sink.calls, 0);
      expect(await rows('planning_sync_outbox'), before);
    });

    test('every financial entity type is held with consent OFF', () async {
      var n = 0;
      for (final t in const [
        'budget',
        'goal',
        'plan',
        'subscription',
        'card',
        'category',
      ]) {
        await seedPlanningRow(t, 'create', {'local_id': 'e$n'},
            id: 'o$n', entityId: 'e$n');
        n++;
      }
      final before = await rows('planning_sync_outbox');
      final sink = _TripSink();
      await service(sink, () async => false).push();
      expect(sink.calls, 0);
      expect(await rows('planning_sync_outbox'), before);
    });

    test('consent ON: proceeds to the client', () async {
      await seedPlanningRow('budget', 'create', {'local_id': 'e1'});
      final sink = _TripSink();
      await service(sink, () async => true).push();
      expect(sink.calls, greaterThan(0));
    });

    test('revocation is observed by the next drain, not the next boot',
        () async {
      await seedPlanningRow('budget', 'create', {'local_id': 'e1'});
      var consent = true;
      final sink = _TripSink();
      final s = service(sink, () async => consent);
      await s.push();
      final afterFirst = sink.calls;
      expect(afterFirst, greaterThan(0));
      consent = false;
      await s.push();
      expect(sink.calls, afterFirst);
    });

    test('profile class is asked separately: settings held, budgets flow',
        () async {
      await seedPlanningRow('budget', 'create', {'local_id': 'b'},
          id: 'ob', entityId: 'b');
      await seedPlanningRow('settings', 'update',
          {'local_id': 'user_settings', 'display_name': 'Sentinel Name'},
          id: 'os', entityId: 'user_settings');
      final sink = _TripSink();
      final s = PlanningPushService(
        db: db,
        queue: buildPlanningOutboxQueue(db),
        isEnabled: (_) => true,
        getAuthUserId: () async => 'user-1',
        remoteSink: sink,
        mayEgress: () async => true,
        mayEgressProfile: () async => false,
      );
      await s.push();
      final settingsRow = (await rows('planning_sync_outbox'))
          .singleWhere((r) => r['id'] == 'os');
      expect(settingsRow['attempt_count'], 0);
      expect(settingsRow['status'], 'pending');
      expect(sink.calls, 1, reason: 'only the budget reached the client');
    });

    test('consent OFF records consentBlocked, not a failure', () async {
      final health = SyncHealth();
      await seedPlanningRow('budget', 'create', {'local_id': 'e1'});
      final s = service(_TripSink(), () async => false, health: health);
      await health.runPhase(
          SyncDomain.planning, SyncDirection.push, () => s.push());
      await health.runPhase(
          SyncDomain.planning, SyncDirection.push, () => s.push());
      final h = health.of(SyncDomain.planning);
      expect(h.lastErrorClass, SyncErrorClass.consentBlocked);
      expect(h.consecutiveFailures, 0);
    });
  });

  // -------------------------------------------- the consent-revocation carve-out
  group('consent-revocation exception (settings)', () {
    late DriftUserSettingsRepository settings;
    late PlanningOutboxQueue queue;

    setUp(() {
      queue = PlanningOutboxQueue(
        db: db,
        isSyncEnabled: (_) => true,
        getAuthUserId: () async => 'user-1',
      );
      settings = DriftUserSettingsRepository(db, outboxQueue: queue);
    });

    Future<void> bind() => db.customStatement(
        "UPDATE user_settings SET server_id = 'server-user_settings';");

    PlanningPushService service(_RecordingSettingsSink sink) =>
        PlanningPushService(
          db: db,
          queue: queue,
          isEnabled: (_) => true,
          getAuthUserId: () async => 'user-1',
          remoteSink: sink,
          // REAL authority over the REAL local settings — not a stub.
          mayEgress: () => ConsentAuthority(settings.getSettings)
              .allows(EgressClass.financialSync),
          mayEgressProfile: () => ConsentAuthority(settings.getSettings)
              .allows(EgressClass.profileAndSettings),
        );

    test(
        'bound: with cloud OFF only the consent-OFF columns leave the device, '
        'the full row stays pending, and it is not re-sent', () async {
      await bind();
      final s = await settings.getSettings();
      await settings.saveSettings(s.copyWith(
        displayName: 'Sentinel Name',
        aiConsentState: ConsentState.declined,
        cloudConsentState: ConsentState.declined,
      ));
      final sink = _RecordingSettingsSink();
      final svc = service(sink);

      await svc.push();

      expect(sink.upserts, isEmpty);
      expect(sink.updates, hasLength(1));
      expect(sink.updates.single, {
        'ai_consent_granted': false,
        'cloud_processing_enabled': false,
      }, reason: 'no profile column may travel while consent is off');
      expect(jsonEncode(sink.updates), isNot(contains('Sentinel Name')));
      final row = (await rows('planning_sync_outbox')).single;
      expect(row['status'], 'pending');
      expect(row['attempt_count'], 0);

      await svc.push();
      expect(sink.updates, hasLength(1),
          reason: 'the revocation is delivered once, not on every drain');
    });

    test('pre-bind: the consent-only CREATE is sent exactly as before',
        () async {
      final s = await settings.getSettings();
      await settings.saveSettings(s.copyWith(
        aiConsentState: ConsentState.accepted,
        cloudConsentState: ConsentState.accepted,
      ));
      await db.customStatement('DELETE FROM planning_sync_outbox;');
      final s2 = await settings.getSettings();
      await settings.saveSettings(s2.copyWith(
        aiConsentState: ConsentState.declined,
        cloudConsentState: ConsentState.declined,
      ));
      final sink = _RecordingSettingsSink();

      await service(sink).push();

      expect(sink.upserts, hasLength(1));
      final row = sink.upserts.single;
      expect(row['cloud_processing_enabled'], false);
      expect(row['ai_consent_granted'], false);
      for (final k in const [
        'display_name',
        'phone_number',
        'date_of_birth',
        'theme',
        'currency',
      ]) {
        expect(row.containsKey(k), isFalse, reason: '$k must not travel');
      }
    });

    test('non-revocation settings rows stay held when profile consent is off',
        () async {
      await bind();
      await seedPlanningRow('settings', 'update', {
        'local_id': 'user_settings',
        'display_name': 'Sentinel Name',
        'cloud_processing_enabled': true,
        'ai_consent_granted': true,
      }, id: 'os', entityId: 'user_settings');
      final sink = _RecordingSettingsSink();
      final svc = PlanningPushService(
        db: db,
        queue: queue,
        isEnabled: (_) => true,
        getAuthUserId: () async => 'user-1',
        remoteSink: sink,
        mayEgress: () async => false,
      );
      await svc.push();
      expect(sink.upserts, isEmpty);
      expect(sink.updates, isEmpty);
    });
  });

  group('planning pull', () {
    PlanningPullService service(_TripPlanningSource src,
            {Future<bool> Function()? fin, Future<bool> Function()? prof}) =>
        PlanningPullService(
          db: db,
          isEnabled: (_) => true,
          getAuthUserId: () async => 'user-1',
          remoteSource: src,
          mayEgress: fin,
          mayEgressProfile: prof,
        );

    test('consent OFF: zero client calls and no cursor written', () async {
      final src = _TripPlanningSource();
      await service(src, fin: () async => false, prof: () async => false)
          .pull();
      expect(src.calls, 0);
      expect(
          await db.customSelect('SELECT * FROM sync_cursors').get(), isEmpty);
    });

    test('consent ON: reaches the client', () async {
      final src = _TripPlanningSource();
      await service(src, fin: () async => true).pull();
      expect(src.calls, greaterThan(0));
    });

    test('settings are pulled under the profile class only', () async {
      final src = _TripPlanningSource();
      await service(src, fin: () async => false, prof: () async => true)
          .pull();
      expect(src.tables, ['user_settings']);

      final src2 = _TripPlanningSource();
      await service(src2, fin: () async => true, prof: () async => false)
          .pull();
      expect(src2.tables, isNot(contains('user_settings')));
      expect(src2.tables, isNotEmpty);
    });

    test('omitting the gates fails CLOSED', () async {
      final src = _TripPlanningSource();
      await service(src).pull();
      expect(src.calls, 0);
    });
  });

  // ------------------------------------------------------------------ children
  group('planning children', () {
    PlanningChildSyncService service(_TripChildRemote r,
            Future<bool> Function()? gate) =>
        PlanningChildSyncService(
          db: db,
          queue: buildPlanningOutboxQueue(db),
          isEnabled: (_) => true,
          isPullEnabled: (_) => true,
          getAuthUserId: () async => 'user-1',
          remote: r,
          mayEgress: gate,
          pullCapability: () => ExactTransportCapability.verifiedExact,
        );

    test('consent OFF: no client call, child rows untouched', () async {
      await seedPlanningRow(
          'goal_contribution', 'create', {'local_goal_id': 'g', 'amount': '1'});
      await seedPlanningRow('bill_payment', 'create', {'x': 1},
          id: 'o2', entityId: 'e2');
      final before = await rows('planning_sync_outbox');
      final r = _TripChildRemote();
      await service(r, () async => false).sync();
      expect(r.calls, 0);
      expect(await rows('planning_sync_outbox'), before);
    });

    test('omitting the gate fails CLOSED', () async {
      await seedPlanningRow(
          'goal_contribution', 'create', {'local_goal_id': 'g', 'amount': '1'});
      final before = await rows('planning_sync_outbox');
      final r = _TripChildRemote();
      await service(r, null).sync();
      expect(r.calls, 0);
      expect(await rows('planning_sync_outbox'), before);
    });

    test('consent ON: proceeds (push attempts the row, pull reaches client)',
        () async {
      await seedPlanningRow(
          'goal_contribution', 'create', {'local_goal_id': 'g', 'amount': '1'});
      final r = _TripChildRemote();
      await service(r, () async => true).sync();
      final row = (await rows('planning_sync_outbox')).single;
      expect(row['attempt_count'], 1,
          reason: 'consent ON reaches the push gate and attempts the row');
      expect(r.calls, greaterThan(0), reason: 'and the pull reaches the client');
    });
  });

  // ------------------------------------------------------------------ accounts
  group('accounts', () {
    test('push: consent OFF -> no client call, row untouched; ON -> proceeds',
        () async {
      await seedPlanningRow('account', 'create', {'local_id': 'e1'});
      final before = await rows('planning_sync_outbox');
      final sink = _TripAccountsSink();
      AccountsPushService svc(Future<bool> Function()? g) => AccountsPushService(
            db: db,
            queue: buildPlanningOutboxQueue(db),
            isEnabled: () => true,
            getAuthUserId: () async => 'user-1',
            remoteSink: sink,
            mayEgress: g,
          );
      await svc(() async => false).push();
      await svc(null).push();
      expect(sink.calls, 0);
      expect(await rows('planning_sync_outbox'), before);
      await svc(() async => true).push();
      expect(sink.calls, greaterThan(0));
    });

    test('pull: consent OFF -> no client call; ON -> proceeds', () async {
      final src = _TripAccountsSource();
      AccountsPullService svc(Future<bool> Function()? g) => AccountsPullService(
            db: db,
            isEnabled: () => true,
            getAuthUserId: () async => 'user-1',
            remoteSource: src,
            mayEgress: g,
          );
      await svc(() async => false).pull();
      await svc(null).pull();
      expect(src.calls, 0);
      await svc(() async => true).pull();
      expect(src.calls, greaterThan(0));
    });
  });

  // -------------------------------------------------------------------- ledger
  group('ledger', () {
    test('push: consent OFF -> no client, row untouched; ON -> proceeds',
        () async {
      await db.customStatement('''
        INSERT INTO ledger_sync_outbox(id, transaction_id, operation,
          payload_json, attempt_count, status, created_at, updated_at)
        VALUES ('l1', 't1', 'create', '{}', 0, 'pending',
          '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z');
      ''');
      final before = await rows('ledger_sync_outbox');
      var clientCalls = 0;
      LedgerPushService svc(Future<bool> Function()? g) => LedgerPushService(
            db: db,
            queue: buildLedgerOutboxQueue(db),
            isPushEnabled: () => true,
            getAuthUserId: () async => 'user-1',
            getClient: () {
              clientCalls++;
              throw StateError('client');
            },
            mayEgress: g,
          );
      await svc(() async => false).push();
      await svc(null).push();
      expect(clientCalls, 0);
      expect(await rows('ledger_sync_outbox'), before);
      await svc(() async => true).push();
      expect((await rows('ledger_sync_outbox')).single['attempt_count'], 1,
          reason: 'consent ON reaches the row');
    });

    test('pull: consent OFF -> no client call; ON -> proceeds', () async {
      final src = _TripLedgerSource();
      LedgerSyncService svc(Future<bool> Function()? g) => LedgerSyncService(
            db: db,
            transactionRepository: DriftTransactionRepository(db),
            dedupStore: DriftDedupStore(db),
            isPullEnabled: () => true,
            getAuthUserId: () async => 'user-1',
            remoteSource: src,
            mayEgress: g,
          );
      await svc(() async => false).pull();
      await svc(null).pull();
      expect(src.calls, 0);
      await svc(() async => true).pull();
      expect(src.calls, greaterThan(0));
    });
  });

  // --------------------------------------------------------------- smart inbox
  test('smart inbox: push+pull OFF -> no client, flag stays; ON -> proceeds',
      () async {
    await db.customStatement('''
      INSERT INTO smart_inbox_items(id, server_id, type, title, status,
        server_created_at, synced_at, pending_sync, created_at, updated_at)
      VALUES ('i1', 's1', 'x', 't', 'dismissed', '2026-01-01T00:00:00Z',
        '2026-01-01T00:00:00Z', 1, '2026-01-01T00:00:00Z',
        '2026-01-01T00:00:00Z');
    ''');
    final src = _TripInboxSource();
    SmartInboxSyncService svc(Future<bool> Function()? g) =>
        SmartInboxSyncService(
          db: db,
          isPullEnabled: () => true,
          getAuthUserId: () async => 'user-1',
          remoteSource: src,
          mayEgress: g,
        );
    for (final g in <Future<bool> Function()?>[() async => false, null]) {
      await svc(g).push();
      await svc(g).pull();
    }
    expect(src.calls, 0);
    final flag = await db
        .customSelect('SELECT pending_sync FROM smart_inbox_items')
        .getSingle();
    expect(flag.read<int>('pending_sync'), 1);
    await svc(() async => true).push();
    expect(src.calls, greaterThan(0));
  });

  // ------------------------------------------------------------ sender mappings
  test('sender mappings: OFF -> no client, row stays pending; ON -> proceeds',
      () async {
    await db.customStatement('''
      INSERT INTO sender_bank_mappings(id, sender_id, normalized_sender_id,
        suggested_bank_name, suggested_country, confidence, status, source,
        first_seen_at, last_seen_at, confirmed_at, created_at, updated_at)
      VALUES ('m1', 'BANK', 'bank', 'Bank', 'SA', 0.9, 'confirmed',
        'user_manual', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z',
        '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z',
        '2026-01-01T00:00:00Z');
    ''');
    final store = _TripMappingStore();
    SenderBankMappingSyncService svc(Future<bool> Function()? g) =>
        SenderBankMappingSyncService(
          db: db,
          remoteStore: store,
          currentUserId: () => 'user-1',
          mayEgress: g,
        );
    await svc(() async => false).sync();
    await svc(null).sync();
    expect(store.calls, 0);
    final st = await db
        .customSelect('SELECT sync_status FROM sender_bank_mappings')
        .getSingle();
    expect(st.read<String>('sync_status'), 'pending');
    await svc(() async => true).sync();
    expect(store.calls, greaterThan(0));
  });

  // ---------------------------------------------------------------- engagement
  test('engagement: OFF -> no client, event stays pending, attempts unchanged',
      () async {
    final rec = _TripRecorder();
    EngagementEventService svc(Future<bool> Function()? g) =>
        EngagementEventService(
          db: db,
          recorder: rec,
          isSyncEnabled: () => true,
          getAuthUserId: () async => 'user-1',
          mayEgress: g,
        );
    await svc(null).enqueue(eventType: 'transaction_confirmed');
    await svc(() async => false).push();
    await svc(null).push();
    expect(rec.calls, 0);
    final ev = await db
        .customSelect('SELECT status, attempt_count FROM engagement_events')
        .getSingle();
    expect(ev.read<String>('status'), 'pending');
    expect(ev.read<int>('attempt_count'), 0);
    await svc(() async => true).push();
    expect(rec.calls, greaterThan(0));
  });

  // ------------------------------------------------------ construction-site pin
  group('construction sites pass consent (source pin)', () {
    const gated = [
      'PlanningPushService',
      'PlanningPullService',
      'PlanningChildSyncService',
      'AccountsPushService',
      'AccountsPullService',
      'LedgerPushService',
      'LedgerSyncService',
      'SmartInboxSyncService',
      'SenderBankMappingSyncService',
      'EngagementEventService',
      'GamificationSyncService',
      'StartupSyncReconcileService',
    ];

    /// Every `Name(` call in lib/ that is not the class's own declaration.
    List<({String file, String name, String args})> sites() {
      final out = <({String file, String name, String args})>[];
      for (final f in Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        final src = f.readAsStringSync();
        for (final name in gated) {
          for (final m in RegExp('(?<![A-Za-z_])$name\\(').allMatches(src)) {
            final before = src.substring(0, m.start);
            // Skip the constructor declaration itself (`  Name({`) and
            // `class Name` / doc references.
            final lineStart = before.lastIndexOf('\n') + 1;
            final prefix = before.substring(lineStart);
            if (prefix.trim().isEmpty && src[m.end] == '{') continue;
            if (prefix.contains('//')) continue;
            var depth = 1;
            var i = m.end;
            while (i < src.length && depth > 0) {
              if (src[i] == '(') depth++;
              if (src[i] == ')') depth--;
              i++;
            }
            out.add((
              file: f.path,
              name: name,
              args: src.substring(m.end, i - 1),
            ));
          }
        }
      }
      return out;
    }

    test('every lib/ construction of a sync service supplies mayEgress', () {
      final all = sites();
      expect(all, isNotEmpty);
      final missing = [
        for (final s in all)
          if (!s.args.contains('mayEgress')) '${s.file}: ${s.name}',
      ];
      expect(missing, isEmpty,
          reason: 'a sync service built without a consent gate would '
              '(correctly) deny forever, or — if a default ever opens — leak');
    });

    test('background/isolate builders construct no network sync service', () {
      // The background capture isolate and BootstrapRunner only enqueue into
      // the outboxes (auth-gated, no network). Pushing happens in the
      // foreground services above, all consent-gated; pin that these files
      // never grow a direct sync-service construction without a gate.
      for (final path in const [
        'lib/features/planning_sync/services/outbox_queue_factory.dart',
        'lib/features/capture/services/captured_message_processor.dart',
      ]) {
        final src = File(path).readAsStringSync();
        for (final name in gated) {
          expect(src.contains('$name('), isFalse,
              reason: '$path must not construct $name');
        }
      }
      // The only non-provider construction is the bootstrap sender-mapping
      // sync, and it is gated (covered by the all-sites check above).
      final boot = File('lib/core/startup/bootstrap_runner.dart')
          .readAsStringSync();
      expect(boot, contains('EgressClass.senderBankMappings'));
    });

    test('providers wire the matching EgressClass', () {
      final src = File('lib/core/di/app_providers.dart').readAsStringSync();
      expect(src, contains('mayEgressProfile: _consentGate(ref, EgressClass.profileAndSettings)'));
      expect(
          RegExp('_consentGate\\(ref, EgressClass\\.financialSync\\)')
              .allMatches(src)
              .length,
          greaterThanOrEqualTo(4));
      final eng = File(
              'lib/features/gamification/services/engagement_event_service.dart')
          .readAsStringSync();
      expect(eng, contains('EgressClass.gamification'));
    });
  });
}
