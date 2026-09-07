import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/features/capture/services/notification_log_service.dart';
import 'package:money_companion/features/capture/services/notification_log_sync_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A real iPhone tap routed correctly to the transaction details screen while
/// `notification_logs.opened_at` stayed NULL for every apns row: the push
/// carried no `notificationLogId`, and the client upserts the open by that
/// exact server id. The native and Dart plumbing already existed end to end —
/// only the server key was missing.
///
/// These pin the client half (which server row an open targets, and that a
/// second tap changes nothing) plus the wiring the fix depends on.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

SupabaseClient _client(MockClient http) => SupabaseClient(
      'https://example.supabase.co',
      'public-anon-key',
      httpClient: http,
      accessToken: () async => 'qa-access-token',
    );

http.Response _json(Object body, http.BaseRequest request) => http.Response(
      jsonEncode(body),
      200,
      headers: const {'content-type': 'application/json'},
      request: request,
    );

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

  tearDown(() async => db.close());

  Future<List<Map<String, dynamic>>> syncAndCapture() async {
    final upserts = <Map<String, dynamic>>[];
    final client = MockClient((request) async {
      upserts.add(Map<String, dynamic>.from(jsonDecode(request.body) as Map));
      return _json(<Object>[], request);
    });
    await NotificationLogSyncService(
      db: db,
      getClient: () => _client(client),
      getAuthUserId: () async => 'qa-user',
      getInstallId: () async => 'qa-install',
    ).debugSyncBatch('qa-user');
    return upserts;
  }

  // The server id that arrives in the push; the tap must land on THIS row.
  const serverLogId = 'ab415ae1-b258-485b-9521-86acb1b38bcf';

  group('an APNs tap marks the exact server row opened', () {
    test('foreground tap upserts opened_at on the server log id', () async {
      await logService.recordOpened(
        logId: serverLogId,
        channel: NotificationLogChannel.apns,
        notificationType: 'new_transaction',
        relatedEntityType: 'transaction',
        relatedEntityId: 'txn-1',
      );

      final upserts = await syncAndCapture();
      expect(upserts, hasLength(1));
      expect(upserts.single['id'], serverLogId,
          reason: 'the open must target the server row, never a derived id');
      expect(upserts.single['status'], 'opened');
      expect(upserts.single['opened_at'], isNotNull);
      expect(upserts.single.containsKey('channel'), isFalse,
          reason: 'an open must not overwrite the channel recorded at send');
    });

    test('cold-start tap behaves identically — same drain, same id', () async {
      // A terminated-app tap queues the same route natively and is drained on
      // launch through the same path; the seam is identical.
      await logService.recordOpened(
        logId: serverLogId,
        channel: NotificationLogChannel.apns,
        notificationType: 'new_transaction',
      );
      final upserts = await syncAndCapture();
      expect(upserts.single['id'], serverLogId);
      expect(upserts.single['status'], 'opened');
    });

    test('a duplicate tap is idempotent — one event, one upsert', () async {
      for (var i = 0; i < 3; i++) {
        await logService.recordOpened(
          logId: serverLogId,
          channel: NotificationLogChannel.apns,
          notificationType: 'new_transaction',
        );
      }
      final rows = await db.customSelect(
        "SELECT COUNT(*) AS total FROM notification_log_events "
        "WHERE notification_log_id = ? AND event_type = 'opened';",
        variables: [Variable.withString(serverLogId)],
      ).getSingle();
      expect(rows.read<int>('total'), 1);

      final upserts = await syncAndCapture();
      expect(upserts, hasLength(1));
    });

    test('two different notifications keep separate opens', () async {
      await logService.recordOpened(
          logId: serverLogId,
          channel: NotificationLogChannel.apns,
          notificationType: 'new_transaction');
      await logService.recordOpened(
          logId: 'df033304-1b92-b55b-056a-de76de5508e0',
          channel: NotificationLogChannel.apns,
          notificationType: 'suspicious_duplicate');
      final upserts = await syncAndCapture();
      expect(upserts.map((u) => u['id']).toSet(), {
        serverLogId,
        'df033304-1b92-b55b-056a-de76de5508e0',
      });
    });
  });

  group('the wiring the fix depends on', () {
    test('a route without a log id records nothing — no invented id', () {
      // app_shell._recordOpenedForRoutes: `if (logId == null) continue;`
      // Inferring from payloadId would upsert a row the server never minted.
      final shell = File('lib/features/app/app_shell.dart').readAsStringSync();
      final body = shell.substring(shell.indexOf('void _recordOpenedForRoutes'));
      expect(body, contains('final logId = route.notificationLogId;'));
      expect(body, contains('if (logId == null) continue;'));
      expect(body, contains('service.recordOpened('));
      expect(body.substring(0, body.indexOf('}')).contains('payloadId'), isFalse,
          reason: 'the open must never be attributed by payloadId');
    });

    test('native reads notificationLogId out of the push userInfo', () {
      final store =
          File('ios/Runner/SharedCaptureStore.swift').readAsStringSync();
      expect(store,
          contains('notificationLogId: clean(userInfo["notificationLogId"] as? String)'));
    });

    test('the server puts notificationLogId in the APNs payload', () {
      final apns =
          File('../supabase/functions/_shared/apns.ts').readAsStringSync();
      expect(apns, contains("notificationLogId: message.notificationLogId ?? ''"));
      final ios = File('../supabase/functions/process-ios-sms/index.ts')
          .readAsStringSync();
      expect(ios, contains('notificationLogId,'),
          reason: 'process-ios-sms must pass the id it already minted');
      final retry =
          File('../supabase/functions/process-notification-retries/process_one.ts')
              .readAsStringSync();
      expect(retry, contains('notificationLogId: row.notification_log_id'),
          reason: 'a replayed push must stay attributable too');
    });
  });
}
