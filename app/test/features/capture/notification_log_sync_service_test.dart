import 'dart:convert';
import 'dart:async';

import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/features/capture/services/notification_log_service.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';
import 'package:money_companion/features/capture/services/notification_log_ownership.dart';
import 'package:money_companion/features/capture/services/notification_log_sync_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

SupabaseClient _client(MockClient http) {
  return SupabaseClient(
    'https://example.supabase.co',
    'public-anon-key',
    httpClient: http,
    accessToken: () async => 'qa-access-token',
  );
}

http.Response _json(Object body, http.BaseRequest request, {int status = 200}) {
  return http.Response(
    jsonEncode(body),
    status,
    headers: const {'content-type': 'application/json'},
    request: request,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late NotificationLogService logService;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    logService = NotificationLogService(db, readOrigin: () async =>
      NotificationLogOrigin('qa-user', 'generation-1', isCurrent: () => true));
  });

  tearDown(() async {
    await db.close();
  });

  test('A, legacy and old generation rows remain unsynced under B', () async {
    final id = await logService.recordCreated(channel: 'local_ios', notificationType: 'test');
    final unbound = NotificationLogService(db, readOrigin: () async => null);
    await unbound.recordCreated(channel: 'local_ios', notificationType: 'test');
    var requests = 0;
    final sync = NotificationLogSyncService(getCurrentAuthUserId: () => 'B', db: db, getAuthUserId: () async => 'B',
      readOrigin: () async => NotificationLogOrigin('B', 'generation-2', isCurrent: () => true),
      mayEgress: () async => true,
      getClient: () => _client(MockClient((r) async { requests++; return _json(<Object>[], r); })),
      getInstallId: () async => 'install');
    await sync.debugSyncBatch('B');
    expect(requests, 0);
    final rows = await db.customSelect('SELECT synced_at, sync_attempt_count FROM notification_log_events').get();
    expect(rows, hasLength(2));
    expect(rows.every((r) => r.readNullable<String>('synced_at') == null && r.read<int>('sync_attempt_count') == 0), isTrue);
    expect(id, isNotEmpty);
  });

  test('retained legacy queue cannot starve current scoped events', () async {
    final unbound = NotificationLogService(db, readOrigin: () async => null);
    for (var i = 0; i < 51; i++) {
      await unbound.recordCreated(channel: 'local_ios', notificationType: 'legacy');
    }
    final id = await logService.recordCreated(channel: 'local_ios', notificationType: 'current');
    final requests = <Map<String, dynamic>>[];
    final sync = NotificationLogSyncService(getCurrentAuthUserId: () => 'qa-user', db: db, getAuthUserId: () async => 'qa-user',
      readOrigin: () async => NotificationLogOrigin('qa-user', 'generation-1', isCurrent: () => true),
      mayEgress: () async => true,
      getClient: () => _client(MockClient((r) async {
        requests.add(jsonDecode(r.body) as Map<String, dynamic>);
        return _json(<Object>[], r);
      })), getInstallId: () async => 'install');
    await sync.debugSyncBatch('qa-user');
    expect(requests, hasLength(1));
    expect(requests.single['id'], id);
    final retained = await db.customSelect('SELECT 1 FROM notification_log_events WHERE synced_at IS NULL').get();
    expect(retained, hasLength(51));
  });

  test('cloud OFF blocks upload and retains current event', () async {
    await logService.recordCreated(channel: 'local_ios', notificationType: 'test');
    var requests = 0;
    final sync = NotificationLogSyncService(getCurrentAuthUserId: () => 'qa-user', db: db, getAuthUserId: () async => 'qa-user',
      readOrigin: () async => NotificationLogOrigin('qa-user', 'generation-1', isCurrent: () => true),
      mayEgress: () async => false,
      getClient: () => _client(MockClient((r) async { requests++; return _json(<Object>[], r); })),
      getInstallId: () async => 'install');
    await sync.debugSyncBatch('qa-user');
    expect(requests, 0);
    final row = await db.customSelect('SELECT synced_at FROM notification_log_events').getSingle();
    expect(row.readNullable<String>('synced_at'), isNull);
  });

  test('revoked operation after install await has no upload or acknowledgement', () async {
    await logService.recordCreated(channel: 'local_ios', notificationType: 'test');
    var current = true;
    var requests = 0;
    final install = Completer<String>();
    final entered = Completer<void>();
    final sync = NotificationLogSyncService(getCurrentAuthUserId: () => 'qa-user', db: db, getAuthUserId: () async => 'qa-user',
      readOrigin: () async => NotificationLogOrigin('qa-user', 'generation-1', isCurrent: () => current),
      mayEgress: () async => true,
      getClient: () => _client(MockClient((r) async { requests++; return _json(<Object>[], r); })),
      getInstallId: () { entered.complete(); return install.future; });
    final work = sync.debugSyncBatch('qa-user');
    await entered.future;
    current = false;
    install.complete('install');
    await work;
    expect(requests, 0);
    final row = await db.customSelect('SELECT synced_at, sync_attempt_count FROM notification_log_events').getSingle();
    expect(row.readNullable<String>('synced_at'), isNull);
    expect(row.read<int>('sync_attempt_count'), 0);
  });

  test('revocation during upload prevents acknowledgement and retry mutation', () async {
    await logService.recordCreated(channel: 'local_ios', notificationType: 'test');
    var current = true;
    var requests = 0;
    final pending = Completer<http.Response>();
    final entered = Completer<void>();
    final sync = NotificationLogSyncService(getCurrentAuthUserId: () => 'qa-user', db: db, getAuthUserId: () async => 'qa-user',
      readOrigin: () async => NotificationLogOrigin('qa-user', 'generation-1', isCurrent: () => current),
      mayEgress: () async => true,
      getClient: () => _client(MockClient((r) { requests++; entered.complete(); return pending.future; })),
      getInstallId: () async => 'install');
    final work = sync.debugSyncBatch('qa-user');
    await entered.future;
    current = false;
    pending.complete(http.Response('[]', 200, headers: {'content-type': 'application/json'}));
    await work;
    expect(requests, 1);
    final row = await db.customSelect('SELECT synced_at, sync_attempt_count FROM notification_log_events').getSingle();
    expect(row.readNullable<String>('synced_at'), isNull);
    expect(row.read<int>('sync_attempt_count'), 0);
  });

  for (final changed in ['generation', 'SDK uid']) {
    test('$changed changes during consent await reject upload without mutating the row', () async {
      await logService.recordCreated(channel: 'local_ios', notificationType: 'test');
      var generation = 'generation-1';
      var sdkUid = 'qa-user';
      var requests = 0;
      final sync = NotificationLogSyncService(getCurrentAuthUserId: () => sdkUid, db: db,
        readOrigin: () async => NotificationLogOrigin('qa-user', 'generation-1',
          isCurrent: () => true, validate: () async => generation == 'generation-1'),
        getAuthUserId: () async => sdkUid,
        mayEgress: () async {
          if (changed == 'generation') generation = 'generation-2';
          if (changed == 'SDK uid') sdkUid = 'B';
          return true;
        },
        getClient: () => _client(MockClient((r) async { requests++; return _json(<Object>[], r); })),
        getInstallId: () async => 'install');
      await sync.debugSyncBatch('qa-user');
      expect(requests, 0);
      final row = await db.customSelect('SELECT synced_at, sync_attempt_count FROM notification_log_events').getSingle();
      expect(row.readNullable<String>('synced_at'), isNull);
      expect(row.read<int>('sync_attempt_count'), 0);
    });
  }

  test('SDK switch while origin validation is paused rejects final network effect', () async {
    await logService.recordCreated(channel: 'local_ios', notificationType: 'test');
    var sdkUid = 'qa-user';
    var validations = 0;
    var requests = 0;
    final entered = Completer<void>();
    final release = Completer<bool>();
    final sync = NotificationLogSyncService(db: db,
      getCurrentAuthUserId: () => sdkUid,
      getAuthUserId: () async => sdkUid,
      readOrigin: () async => NotificationLogOrigin('qa-user', 'generation-1',
        isCurrent: () => true, validate: () async {
          validations++;
          if (validations == 4) { entered.complete(); return release.future; }
          return true;
        }),
      mayEgress: () async => true,
      getClient: () => _client(MockClient((r) async { requests++; return _json(<Object>[], r); })),
      getInstallId: () async => 'install');
    final work = sync.debugSyncBatch('qa-user');
    await entered.future;
    sdkUid = 'B';
    release.complete(true);
    await work;
    expect(requests, 0);
    final row = await db.customSelect('SELECT synced_at, sync_attempt_count FROM notification_log_events').getSingle();
    expect(row.readNullable<String>('synced_at'), isNull);
    expect(row.read<int>('sync_attempt_count'), 0);
  });

  test('native retrieval retry persists once and only acknowledges verified origin', () async {
    const event = NativeNotificationLogEvent(eventId: '00000000-0000-4000-8000-000000000001',
      notificationLogId: 'native-attempt', eventType: 'created', channel: 'ios_shortcut_local',
      notificationType: 'test', originKind: 'native', ownerUid: 'B', ownerGeneration: 2);
    var acknowledgements = 0;
    final sync = NotificationLogSyncService(getCurrentAuthUserId: () => 'qa-user', db: db,
      readOrigin: () async => NotificationLogOrigin('B', 'local-B', nativeGeneration: 2, isCurrent: () => true),
      consumeNativeEvents: (_, __) async => [event],
      acknowledgeNativeEvent: (e) async { expect(e.eventId, event.eventId); acknowledgements++; return false; });
    await sync.debugImportNativeEvents();
    await sync.debugImportNativeEvents();
    expect(await db.customSelect('SELECT 1 FROM notification_log_events').get(), hasLength(1));
    expect(acknowledgements, 2);
    await db.customUpdate("UPDATE notification_log_events SET payload_json = '{}' WHERE id = ?",
      variables: [Variable.withString('native:${event.eventId}')]);
    await sync.debugImportNativeEvents();
    expect(acknowledgements, 2, reason: 'conflicting persistence is never ownership proof');
  });

  test('persistence failure retains native event without acknowledging it', () async {
    await db.customStatement('DROP TABLE notification_log_events');
    var acknowledged = false;
    final sync = NotificationLogSyncService(getCurrentAuthUserId: () => 'qa-user', db: db,
      readOrigin: () async => NotificationLogOrigin('B', 'local-B', nativeGeneration: 2, isCurrent: () => true),
      consumeNativeEvents: (_, __) async => [const NativeNotificationLogEvent(
        eventId: '00000000-0000-4000-8000-000000000001', notificationLogId: 'native-attempt',
        eventType: 'created', channel: 'ios_shortcut_local', notificationType: 'test',
        originKind: 'native', ownerUid: 'B', ownerGeneration: 2)],
      acknowledgeNativeEvent: (_) async { acknowledged = true; return true; });
    await sync.debugImportNativeEvents();
    expect(acknowledged, isFalse);
  });

  test('revocation after persistence retains native event without acknowledgement', () async {
    var current = true;
    var validations = 0;
    var acknowledged = false;
    final sync = NotificationLogSyncService(getCurrentAuthUserId: () => 'qa-user', db: db,
      readOrigin: () async => NotificationLogOrigin('B', 'local-B', nativeGeneration: 2,
        isCurrent: () => current, validate: () async {
          validations++;
          // Entry, response, per-event, then the first post-insert boundary.
          if (validations == 4) current = false;
          return current;
        }),
      consumeNativeEvents: (_, __) async => [const NativeNotificationLogEvent(
        eventId: '00000000-0000-4000-8000-000000000001', notificationLogId: 'native-attempt',
        eventType: 'created', channel: 'ios_shortcut_local', notificationType: 'test',
        originKind: 'native', ownerUid: 'B', ownerGeneration: 2)],
      acknowledgeNativeEvent: (_) async { acknowledged = true; return true; });
    await sync.debugImportNativeEvents();
    expect(await db.customSelect('SELECT 1 FROM notification_log_events').get(), hasLength(1));
    expect(acknowledged, isFalse);
  });

  test('native importer rejects unbound, A and old B generation without relabeling', () async {
    NativeNotificationLogEvent event(String id, String? uid, int? generation) =>
      NativeNotificationLogEvent(eventId: '00000000-0000-4000-8000-000000000001', notificationLogId: id, eventType: 'created',
        channel: 'ios_shortcut_local', notificationType: 'test',
        originKind: uid == null ? null : 'native', ownerUid: uid, ownerGeneration: generation);
    final sync = NotificationLogSyncService(getCurrentAuthUserId: () => 'qa-user', db: db, getAuthUserId: () async => 'qa-user',
      readOrigin: () async => NotificationLogOrigin('B', 'local-B', nativeGeneration: 2, isCurrent: () => true),
      consumeNativeEvents: (uid, generation) async {
        expect(uid, 'B'); expect(generation, 2);
        return [event('unbound', null, null), event('A', 'A', 1), event('old-B', 'B', 1), event('current-B', 'B', 2)];
      });
    await sync.debugImportNativeEvents();
    final rows = await db.customSelect('SELECT notification_log_id, payload_json FROM notification_log_events').get();
    expect(rows, hasLength(1));
    expect(rows.single.read<String>('notification_log_id'), 'current-B');
    expect((jsonDecode(rows.single.read<String>('payload_json')) as Map)[NotificationLogOrigin.payloadKey],
      {'kind': 'native', 'uid': 'B', 'generation': 2});
  });

  test('native import continuation revoked during consume performs no database insert', () async {
    var current = true;
    final pending = Completer<List<NativeNotificationLogEvent>>();
    final entered = Completer<void>();
    final sync = NotificationLogSyncService(getCurrentAuthUserId: () => 'qa-user', db: db, getAuthUserId: () async => 'qa-user',
      readOrigin: () async => NotificationLogOrigin('B', 'local-B', nativeGeneration: 2, isCurrent: () => current),
      consumeNativeEvents: (_, __) { entered.complete(); return pending.future; });
    final work = sync.debugImportNativeEvents();
    await entered.future;
    current = false;
    pending.complete([const NativeNotificationLogEvent(eventId: '00000000-0000-4000-8000-000000000001', notificationLogId: 'B', eventType: 'created',
      channel: 'ios_shortcut_local', notificationType: 'test', originKind: 'native', ownerUid: 'B', ownerGeneration: 2)]);
    await work;
    expect(await db.customSelect('SELECT 1 FROM notification_log_events').get(), isEmpty);
  });

  test('uploads each event as an upsert keyed by the same notification_log_id',
      () async {
    final logId = await logService.recordCreated(
      channel: NotificationLogChannel.localIos,
      notificationType: 'budget_warning',
      relatedEntityType: 'budget',
      relatedEntityId: 'budget-1',
    );
    await logService.recordSent(
      logId: logId,
      channel: NotificationLogChannel.localIos,
      notificationType: 'budget_warning',
    );

    final upserts = <Map<String, dynamic>>[];
    final http = MockClient((request) async {
      expect(request.method, 'POST');
      final decoded = jsonDecode(request.body);
      upserts.add(Map<String, dynamic>.from(decoded as Map));
      return _json(<Object>[], request);
    });
    final sync = NotificationLogSyncService(getCurrentAuthUserId: () => 'qa-user',
      db: db,
      readOrigin: () async => NotificationLogOrigin(
        'qa-user', 'generation-1', isCurrent: () => true),
      mayEgress: () async => true,
      getClient: () => _client(http),
      getAuthUserId: () async => 'qa-user',
      getInstallId: () async => 'qa-install',
    );

    await sync.debugSyncBatch('qa-user');

    expect(upserts, hasLength(2));
    expect(upserts[0]['id'], logId);
    expect(upserts[0]['status'], 'pending');
    expect(upserts[1]['id'], logId);
    expect(upserts[1]['status'], 'sent');
    // Every unsynced row was marked synced after a successful upload.
    final remaining = await db
        .customSelect(
          'SELECT COUNT(*) AS total FROM notification_log_events WHERE synced_at IS NULL;',
        )
        .getSingle();
    expect(remaining.read<int>('total'), 0);
  });

  test('same-tick events still upload in insertion order', () async {
    // The ordering above used `id ASC` as its tie-breaker, and `id` is a
    // RANDOM 16-byte value. Two events for one notification normally share a
    // `created_at` tick — `recordCreated` is followed by `recordSent`
    // microseconds later — so the upload order was decided at random, and the
    // 'created after sent' regression this suite exists to prevent happened
    // roughly half the time. It surfaced as a flake: this file and
    // `local_notification_service_tracking_test` failed on alternate full-suite
    // runs and passed in isolation.
    //
    // Forcing an identical `created_at` on every row makes the tie-breaker the
    // ONLY thing that can order them, so this fails outright rather than
    // half the time.
    final logId = await logService.recordCreated(
      channel: NotificationLogChannel.localAndroid,
      notificationType: 'achievement',
    );
    await logService.recordSent(
      logId: logId,
      channel: NotificationLogChannel.localAndroid,
      notificationType: 'achievement',
    );
    await logService.recordOpened(
      logId: logId,
      channel: NotificationLogChannel.localAndroid,
      notificationType: 'achievement',
    );
    await db.customStatement(
      "UPDATE notification_log_events SET created_at = '2026-09-17T10:00:00.000Z';",
    );

    final statusesInOrder = <String>[];
    final http = MockClient((request) async {
      final decoded = jsonDecode(request.body) as Map;
      statusesInOrder.add(decoded['status'] as String);
      return _json(<Object>[], request);
    });
    final sync = NotificationLogSyncService(getCurrentAuthUserId: () => 'qa-user',
      db: db,
      readOrigin: () async => NotificationLogOrigin(
        'qa-user', 'generation-1', isCurrent: () => true),
      mayEgress: () async => true,
      getClient: () => _client(http),
      getAuthUserId: () async => 'qa-user',
      getInstallId: () async => 'qa-install',
    );
    await sync.debugSyncBatch('qa-user');

    expect(statusesInOrder.indexOf('pending'),
        lessThan(statusesInOrder.indexOf('sent')),
        reason: 'created uploaded after sent — the row status regresses');
    expect(statusesInOrder.indexOf('sent'),
        lessThan(statusesInOrder.indexOf('opened')),
        reason: 'sent uploaded after opened');
  });

  test('processes events oldest-first so created never uploads after sent',
      () async {
    final logId = await logService.recordCreated(
      channel: NotificationLogChannel.localAndroid,
      notificationType: 'achievement',
    );
    await logService.recordSent(
      logId: logId,
      channel: NotificationLogChannel.localAndroid,
      notificationType: 'achievement',
    );
    await logService.recordOpened(
      logId: logId,
      channel: NotificationLogChannel.localAndroid,
      notificationType: 'achievement',
    );

    final statusesInOrder = <String>[];
    final http = MockClient((request) async {
      final decoded = jsonDecode(request.body) as Map;
      statusesInOrder.add(decoded['status'] as String);
      return _json(<Object>[], request);
    });
    final sync = NotificationLogSyncService(getCurrentAuthUserId: () => 'qa-user',
      db: db,
      readOrigin: () async => NotificationLogOrigin(
        'qa-user', 'generation-1', isCurrent: () => true),
      mayEgress: () async => true,
      getClient: () => _client(http),
      getAuthUserId: () async => 'qa-user',
      getInstallId: () async => 'qa-install',
    );

    await sync.debugSyncBatch('qa-user');

    expect(statusesInOrder, ['pending', 'sent', 'opened']);
  });

  test('the opened upsert omits channel (cannot always be known at tap time)',
      () async {
    final logId = await logService.recordCreated(
      channel: NotificationLogChannel.apns,
      notificationType: 'new_transaction',
    );
    await db.customUpdate(
      "UPDATE notification_log_events SET synced_at = 'x' WHERE event_type = 'created';",
    );
    await logService.recordOpened(
      logId: logId,
      channel: NotificationLogChannel.apns,
      notificationType: 'new_transaction',
    );

    Map<String, dynamic>? openedBody;
    final http = MockClient((request) async {
      openedBody = Map<String, dynamic>.from(jsonDecode(request.body) as Map);
      return _json(<Object>[], request);
    });
    final sync = NotificationLogSyncService(getCurrentAuthUserId: () => 'qa-user',
      db: db,
      readOrigin: () async => NotificationLogOrigin(
        'qa-user', 'generation-1', isCurrent: () => true),
      mayEgress: () async => true,
      getClient: () => _client(http),
      getAuthUserId: () async => 'qa-user',
      getInstallId: () async => 'qa-install',
    );

    await sync.debugSyncBatch('qa-user');

    expect(openedBody, isNotNull);
    expect(openedBody!.containsKey('channel'), isFalse);
    expect(openedBody!['status'], 'opened');
  });

  test(
      'if opened is recorded locally before sent (a real race between the '
      'plugin displaying and this attempt finishing), sync still uploads in '
      'chronological order — opened first, sent second', () async {
    final logId = await logService.recordCreated(
      channel: NotificationLogChannel.localIos,
      notificationType: 'goal_milestone',
    );
    // Tap happens before recordSent runs for this same attempt.
    await logService.recordOpened(
      logId: logId,
      channel: NotificationLogChannel.localIos,
      notificationType: 'goal_milestone',
    );
    await logService.recordSent(
      logId: logId,
      channel: NotificationLogChannel.localIos,
      notificationType: 'goal_milestone',
    );

    final statusesInOrder = <String>[];
    final http = MockClient((request) async {
      final decoded = jsonDecode(request.body) as Map;
      statusesInOrder.add(decoded['status'] as String);
      return _json(<Object>[], request);
    });
    final sync = NotificationLogSyncService(getCurrentAuthUserId: () => 'qa-user',
      db: db,
      readOrigin: () async => NotificationLogOrigin(
        'qa-user', 'generation-1', isCurrent: () => true),
      mayEgress: () async => true,
      getClient: () => _client(http),
      getAuthUserId: () async => 'qa-user',
      getInstallId: () async => 'qa-install',
    );

    await sync.debugSyncBatch('qa-user');

    // The sync layer never reorders — it uploads in the order events
    // actually happened. The server-side monotonic-status trigger
    // (protect_notification_log_status in 0052_notification_logs.sql) is
    // what guarantees the row's final status doesn't regress from 'opened'
    // back down to 'sent' when the second upsert lands.
    expect(statusesInOrder, ['pending', 'opened', 'sent']);
  });

  test(
      'a failed upload stops the batch and is retried on the next pass instead of being skipped',
      () async {
    final logId = await logService.recordCreated(
      channel: NotificationLogChannel.localIos,
      notificationType: 'goal_milestone',
    );

    var calls = 0;
    final failingHttp = MockClient((request) async {
      calls++;
      return http.Response('server error', 500, request: request);
    });
    final failingSync = NotificationLogSyncService(getCurrentAuthUserId: () => 'qa-user',
      db: db,
      readOrigin: () async => NotificationLogOrigin(
        'qa-user', 'generation-1', isCurrent: () => true),
      mayEgress: () async => true,
      getClient: () => _client(failingHttp),
      getAuthUserId: () async => 'qa-user',
      getInstallId: () async => 'qa-install',
    );
    await failingSync.debugSyncBatch('qa-user');
    expect(calls, 1);

    final byId = await db
        .customSelect(
          "SELECT synced_at, sync_attempt_count FROM notification_log_events WHERE notification_log_id = '$logId';",
        )
        .getSingle();
    expect(byId.readNullable<String>('synced_at'), isNull);
    expect(byId.read<int>('sync_attempt_count'), 1);

    final succeedingHttp =
        MockClient((request) async => _json(<Object>[], request));
    final succeedingSync = NotificationLogSyncService(getCurrentAuthUserId: () => 'qa-user',
      db: db,
      readOrigin: () async => NotificationLogOrigin(
        'qa-user', 'generation-1', isCurrent: () => true),
      mayEgress: () async => true,
      getClient: () => _client(succeedingHttp),
      getAuthUserId: () async => 'qa-user',
      getInstallId: () async => 'qa-install',
    );
    await succeedingSync.debugSyncBatch('qa-user');
    final afterRetry = await db
        .customSelect(
          "SELECT synced_at FROM notification_log_events WHERE notification_log_id = '$logId';",
        )
        .getSingle();
    expect(afterRetry.readNullable<String>('synced_at'), isNotNull);
  });

  test(
      'exhausted events remain unsynced without additional network retries',
      () async {
    await logService.recordCreated(
      channel: NotificationLogChannel.localIos,
      notificationType: 'weekly_report',
    );
    final alwaysFailingHttp = MockClient(
        (request) async => http.Response('error', 500, request: request));
    final sync = NotificationLogSyncService(getCurrentAuthUserId: () => 'qa-user',
      db: db,
      readOrigin: () async => NotificationLogOrigin(
        'qa-user', 'generation-1', isCurrent: () => true),
      mayEgress: () async => true,
      getClient: () => _client(alwaysFailingHttp),
      getAuthUserId: () async => 'qa-user',
      getInstallId: () async => 'qa-install',
    );

    // 8 failing attempts bump sync_attempt_count to 8 (NotificationLogSyncService's
    // _maxAttemptsPerEvent); later passes exclude the exhausted row.
    for (var i = 0; i < 9; i++) {
      await sync.debugSyncBatch('qa-user');
    }

    final row = await db
        .customSelect(
          "SELECT synced_at, sync_attempt_count FROM notification_log_events;",
        )
        .getSingle();
    expect(row.readNullable<String>('synced_at'), isNull);
    expect(row.read<int>('sync_attempt_count'), 8);
  });
}
