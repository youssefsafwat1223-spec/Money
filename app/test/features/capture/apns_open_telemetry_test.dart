import 'ledger_admission_fixture.dart';
import '../../core/session/f2_fixture.dart';
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
import 'package:money_companion/features/capture/services/notification_log_ownership.dart';
import 'package:money_companion/features/capture/services/notification_log_sync_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A real iPhone tap routed correctly to the transaction details screen while
/// `notification_logs.opened_at` stayed NULL for every apns row: the push
/// carried no `notificationLogId`, and the client upserts the open by that
/// exact server id. The native and Dart plumbing already existed end to end —
/// only the server key was missing.
///
/// F1: a server id alone is not ownership proof. Unknown taps retain routing
/// behavior but must never manufacture telemetry owned by the current account.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

SupabaseClient? _admittedClient;
MockClient? _forwardTo;
SupabaseClient _client(MockClient client) {
  _forwardTo = client;
  expect(_admittedClient!.auth.currentUser?.id, 'qa-user');
  return _admittedClient!;
}
Future<http.Response> _forward(http.Request request) async {
  final copy = http.Request(request.method, request.url)
    ..headers.addAll(request.headers)..bodyBytes = request.bodyBytes;
  return http.Response.fromStream(await _forwardTo!.send(copy));
}

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
    logService = NotificationLogService(db, readOrigin: () async =>
      NotificationLogOrigin('qa-user', 'generation-1', isCurrent: () => true));
  });

  tearDown(() async => db.close());

  Future<List<Map<String, dynamic>>> syncAndCapture() async {
    final upserts = <Map<String, dynamic>>[];
    final client = MockClient((request) async {
      upserts.add(Map<String, dynamic>.from(jsonDecode(request.body) as Map));
      return _json(<Object>[], request);
    });
    await NotificationLogSyncService(getCurrentAuthUserId: () => 'qa-user',
      db: db,
      readOrigin: () async => NotificationLogOrigin('qa-user', 'generation-1', isCurrent: () => true),
      mayEgress: () async => true,
      getClient: () => _client(client),
      getAuthUserId: () async => 'qa-user',
      getInstallId: () async => 'qa-install',
    ).debugSyncBatch('qa-user');
    return upserts;
  }

  // The server id that arrives in the push; the tap must land on THIS row.
  const serverLogId = 'ab415ae1-b258-485b-9521-86acb1b38bcf';

  group('an APNs tap without trusted local provenance', () {
    late LedgerAdmissionFixture admission;
    setUp(() async {
      await db.close();
      admission = await LedgerAdmissionFixture.open('qa-user');
      db = admission.database;
      logService = NotificationLogService(db, readOrigin: () async =>
          NotificationLogOrigin('qa-user', 'generation-1', isCurrent: () => true));
      _admittedClient = admission.ownClient(SupabaseClient('https://example.supabase.co', 'anon',
          authOptions: const AuthClientOptions(autoRefreshToken: false), httpClient: MockClient(_forward)));
      await F2Fixture.recoverSession_(_admittedClient!, 'qa-user');
      expect(_admittedClient!.auth.currentUser?.id, 'qa-user');
      expect(admission.fixture.session.captureLocalWorkAuthority()!.isCurrent, isTrue);
    });
    tearDown(() async {
      try { await admission.finish(); }
      finally { _admittedClient = null; _forwardTo = null; }
    });

    test('foreground tap never creates or uploads a current-owner row', () async {
      await logService.recordOpened(logId: serverLogId,
        channel: NotificationLogChannel.apns, notificationType: 'new_transaction',
        relatedEntityType: 'transaction', relatedEntityId: 'txn-1');
      expect(await syncAndCapture(), isEmpty);
      expect(await db.customSelect('SELECT 1 FROM notification_log_events').get(), isEmpty);
    });

    test('cold-start tap is rejected after service reconstruction', () async {
      logService = NotificationLogService(db, readOrigin: () async =>
        NotificationLogOrigin('qa-user', 'generation-1', isCurrent: () => true));
      await logService.recordOpened(logId: serverLogId,
        channel: NotificationLogChannel.apns, notificationType: 'new_transaction');
      expect(await syncAndCapture(), isEmpty);
      expect(await db.customSelect('SELECT 1 FROM notification_log_events').get(), isEmpty);
    });

    test('duplicate unknown taps never manufacture provenance', () async {
      for (var i = 0; i < 3; i++) {
        await logService.recordOpened(logId: serverLogId,
          channel: NotificationLogChannel.apns, notificationType: 'new_transaction');
      }
      final row = await db.customSelect('SELECT COUNT(*) AS total FROM notification_log_events '
        'WHERE notification_log_id = ?', variables: [Variable.withString(serverLogId)]).getSingle();
      expect(row.read<int>('total'), 0);
      expect(await syncAndCapture(), isEmpty);
    });

    test('two unknown notification ids cannot become current account telemetry', () async {
      for (final id in [serverLogId, 'df033304-1b92-b55b-056a-de76de5508e0']) {
        await logService.recordOpened(logId: id,
          channel: NotificationLogChannel.apns, notificationType: 'new_transaction');
      }
      expect(await syncAndCapture(), isEmpty);
      expect(await db.customSelect('SELECT 1 FROM notification_log_events').get(), isEmpty);
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
