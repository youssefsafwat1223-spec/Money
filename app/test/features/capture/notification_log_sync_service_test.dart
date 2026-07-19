import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/features/capture/services/notification_log_service.dart';
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
    logService = NotificationLogService(db);
  });

  tearDown(() async {
    await db.close();
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
    final sync = NotificationLogSyncService(
      db: db,
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
    final sync = NotificationLogSyncService(
      db: db,
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
    final sync = NotificationLogSyncService(
      db: db,
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
    final sync = NotificationLogSyncService(
      db: db,
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
    final failingSync = NotificationLogSyncService(
      db: db,
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
    final succeedingSync = NotificationLogSyncService(
      db: db,
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
      'gives up after the max attempt count instead of blocking the queue forever',
      () async {
    await logService.recordCreated(
      channel: NotificationLogChannel.localIos,
      notificationType: 'weekly_report',
    );
    final alwaysFailingHttp = MockClient(
        (request) async => http.Response('error', 500, request: request));
    final sync = NotificationLogSyncService(
      db: db,
      getClient: () => _client(alwaysFailingHttp),
      getAuthUserId: () async => 'qa-user',
      getInstallId: () async => 'qa-install',
    );

    // 8 failing attempts bump sync_attempt_count to 8 (NotificationLogSyncService's
    // _maxAttemptsPerEvent); the give-up check runs at the *start* of the next
    // pass, so a 9th pass is what actually observes the row as exhausted.
    for (var i = 0; i < 9; i++) {
      await sync.debugSyncBatch('qa-user');
    }

    final row = await db
        .customSelect(
          "SELECT synced_at, sync_attempt_count FROM notification_log_events;",
        )
        .getSingle();
    // Given up on — marked synced despite never actually uploading, so it
    // doesn't block anything queued behind it.
    expect(row.readNullable<String>('synced_at'), isNotNull);
  });
}
