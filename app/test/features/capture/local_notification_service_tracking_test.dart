import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/features/capture/services/local_notification_service.dart';
import 'package:money_companion/features/capture/services/notification_log_service.dart';

/// Phase 1 notification tracking (docs/NOTIFICATION_PIPELINE_AUDIT.md).
///
/// These tests run in a bare `flutter test` VM with no platform channel
/// registered for `flutter_local_notifications`, so every
/// `_plugin.show`/`zonedSchedule` call fails naturally (no mocking needed —
/// this is exactly the "unhandled async exception" scenario the pipeline
/// exists to make safe and observable instead of swallowed-and-invisible).
class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

Future<List<String>> _eventTypesFor(AppDatabase db, {String? logId}) async {
  final rows = logId == null
      ? await db
          .customSelect(
            'SELECT event_type FROM notification_log_events '
            'ORDER BY created_at ASC, id ASC;',
          )
          .get()
      : await db.customSelect(
          'SELECT event_type FROM notification_log_events '
          'WHERE notification_log_id = ? ORDER BY created_at ASC, id ASC;',
          variables: [Variable.withString(logId)],
        ).get();
  return [for (final row in rows) row.read<String>('event_type')];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    LocalNotificationService.instance.logService = NotificationLogService(db);
  });

  tearDown(() async {
    LocalNotificationService.instance.logService = null;
    await db.close();
  });

  test(
      'an awaited show call that fails records created→failed and never '
      'throws into the caller', () async {
    await expectLater(
      LocalNotificationService.instance.showBudgetAlert(
        title: 'اقتربت من ميزانية',
        body: 'body',
        type: NotificationType.budgetWarning,
        preferences: const NotificationPreferences(),
      ),
      completes,
    );

    final events = await _eventTypesFor(db);
    expect(events, ['created', 'failed']);
  });

  test(
      'an unawaited show call does not surface as an unhandled async error '
      'and still records the failure', () async {
    // Deliberately not awaited — this is exactly the fire-and-forget shape
    // used by several call sites in app_shell.dart.
    // ignore: unawaited_futures
    LocalNotificationService.instance.showAchievementNotification(
      title: 'شارة جديدة',
      body: 'body',
      preferences: const NotificationPreferences(),
    );

    // Let the fire-and-forget call run to completion. If it produced an
    // unhandled exception, the test framework would fail this test on its
    // own via FlutterError/the test zone — reaching this assertion at all
    // is part of what's being verified.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final events = await _eventTypesFor(db);
    expect(events, ['created', 'failed']);
  });

  test(
      'showTestNotification reports failure via its return value, not a thrown exception',
      () async {
    final sent = await LocalNotificationService.instance.showTestNotification();
    expect(sent, isFalse);

    final events = await _eventTypesFor(db);
    expect(events, ['created', 'failed']);
  });

  test(
      'scheduleStreakReminder records created→failed for the scheduling attempt',
      () async {
    await LocalNotificationService.instance.scheduleStreakReminder(
      hasActivityToday: false,
      preferences: const NotificationPreferences(),
    );
    final events = await _eventTypesFor(db);
    expect(events, ['created', 'failed']);
  });

  test(
      'tapping a notification records opened exactly once even if the '
      'handler runs twice for the same payload', () async {
    final logService = NotificationLogService(db);
    final logId = await logService.recordCreated(
      channel: NotificationLogChannel.localIos,
      notificationType: 'captureReview',
      relatedEntityType: 'transaction',
      relatedEntityId: 'tx-open-1',
    );
    final payload = CaptureNotificationPayload(
      kind: 'confirm',
      transactionId: 'tx-open-1',
      notificationLogId: logId,
      notificationType: 'captureReview',
    ).encode();

    await LocalNotificationService.instance
        .debugHandleNotificationTap(payload, actionId: null);
    await LocalNotificationService.instance
        .debugHandleNotificationTap(payload, actionId: null);

    final events = await _eventTypesFor(db, logId: logId);
    expect(events.where((e) => e == 'opened'), hasLength(1));
  });

  test(
      'a tap on a payload with no notificationLogId is a safe no-op for tracking',
      () async {
    const payload = '{"kind":"confirm","transactionId":"tx-legacy"}';
    await expectLater(
      LocalNotificationService.instance
          .debugHandleNotificationTap(payload, actionId: null),
      completes,
    );
    final events = await _eventTypesFor(db);
    expect(events, isEmpty);
  });

  test(
      'a tap on completely malformed JSON does not throw and navigation is '
      'simply skipped', () async {
    await expectLater(
      LocalNotificationService.instance
          .debugHandleNotificationTap('{not valid json', actionId: null),
      completes,
    );
    final events = await _eventTypesFor(db);
    expect(events, isEmpty);
  });

  test(
      'a tap on a payload whose notificationLogId has the wrong JSON type '
      'still routes navigation for the other fields', () async {
    const payload =
        '{"kind":"confirm","transactionId":"tx-bad-id","notificationLogId":12345}';
    await expectLater(
      LocalNotificationService.instance
          .debugHandleNotificationTap(payload, actionId: null),
      completes,
    );
    // No tracking event — the malformed id can't be correlated to anything
    // — but the call still completed without throwing, i.e. navigation logic
    // downstream of _recordOpenedFromPayload was still reached.
    final events = await _eventTypesFor(db);
    expect(events, isEmpty);
  });

  test(
      'recordOpened succeeds with no network/Supabase configuration '
      '(the offline-tap case — tracking is entirely local-first)', () async {
    final logService = NotificationLogService(db);
    final logId = await logService.recordCreated(
      channel: NotificationLogChannel.localIos,
      notificationType: 'captureReview',
    );
    await expectLater(
      logService.recordOpened(
        logId: logId,
        channel: NotificationLogChannel.localIos,
        notificationType: 'captureReview',
      ),
      completes,
    );
    final events = await _eventTypesFor(db, logId: logId);
    expect(events, ['created', 'opened']);
  });

  test(
      'an open event recorded before the sent event ever runs still ends up '
      'ordered correctly for sync (oldest-first upload)', () async {
    final logService = NotificationLogService(db);
    final logId = await logService.recordCreated(
      channel: NotificationLogChannel.localIos,
      notificationType: 'captureReview',
    );
    // Tap arrives (e.g. from a notification the plugin already displayed)
    // before this attempt's own recordSent call has run — a real race when
    // showing and scheduling happen on different code paths.
    await logService.recordOpened(
      logId: logId,
      channel: NotificationLogChannel.localIos,
      notificationType: 'captureReview',
    );
    await logService.recordSent(
      logId: logId,
      channel: NotificationLogChannel.localIos,
      notificationType: 'captureReview',
    );

    final rows = await db.customSelect(
      'SELECT event_type FROM notification_log_events '
      'WHERE notification_log_id = ? ORDER BY created_at ASC, id ASC;',
      variables: [Variable.withString(logId)],
    ).get();
    // Locally, both events are preserved in the order they actually
    // happened — 'created' then 'opened' then 'sent' — so the sync service's
    // oldest-first upload will upsert them in this same order. Whichever
    // status the server ends up with is compared against the previous
    // status by the monotonic-transition trigger.
    expect(rows.map((r) => r.read<String>('event_type')), [
      'created',
      'opened',
      'sent',
    ]);
  });
}
