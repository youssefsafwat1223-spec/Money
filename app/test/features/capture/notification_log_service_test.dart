import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/features/capture/services/notification_log_service.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

Future<List<Map<String, Object?>>> _eventsFor(
  AppDatabase db,
  String logId,
) async {
  final rows = await db.customSelect(
    'SELECT event_type, error_code, error_reason, synced_at '
    'FROM notification_log_events '
    "WHERE notification_log_id = ? ORDER BY created_at ASC, id ASC;",
    variables: [Variable.withString(logId)],
  ).get();
  return [
    for (final row in rows)
      {
        'event_type': row.read<String>('event_type'),
        'error_code': row.readNullable<String>('error_code'),
        'error_reason': row.readNullable<String>('error_reason'),
        'synced_at': row.readNullable<String>('synced_at'),
      },
  ];
}

void main() {
  late AppDatabase db;
  late NotificationLogService service;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    service = NotificationLogService(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('recordCreated returns a stable id used by every later call', () async {
    final logId = await service.recordCreated(
      channel: NotificationLogChannel.localIos,
      notificationType: 'budget_warning',
      relatedEntityType: 'budget',
      relatedEntityId: 'budget-1',
    );
    expect(logId, isNotEmpty);
    // Valid UUID v4 shape — required for the `uuid` column on the server.
    expect(
      RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      ).hasMatch(logId),
      isTrue,
    );

    await service.recordSent(
      logId: logId,
      channel: NotificationLogChannel.localIos,
      notificationType: 'budget_warning',
    );

    final events = await _eventsFor(db, logId);
    expect(events.map((e) => e['event_type']), ['created', 'sent']);
    // Every event for this attempt shares the exact same id — nothing
    // regenerates it mid-flight.
    final distinctIds = await db
        .customSelect(
          'SELECT DISTINCT notification_log_id FROM notification_log_events;',
        )
        .get();
    expect(distinctIds, hasLength(1));
  });

  test('recordFailed stores a sanitized error code and reason', () async {
    final logId = await service.recordCreated(
      channel: NotificationLogChannel.localAndroid,
      notificationType: 'achievement',
    );
    await service.recordFailed(
      logId: logId,
      channel: NotificationLogChannel.localAndroid,
      notificationType: 'achievement',
      error: StateError('plugin channel unavailable'),
      stackTrace: StackTrace.current,
    );

    final events = await _eventsFor(db, logId);
    expect(events.last['event_type'], 'failed');
    expect(events.last['error_code'], 'StateError');
    expect(events.last['error_reason'], contains('plugin channel unavailable'));
  });

  test('recordOpened is idempotent for repeated taps on the same id', () async {
    final logId = await service.recordCreated(
      channel: NotificationLogChannel.apns,
      notificationType: 'new_transaction',
      relatedEntityType: 'transaction',
      relatedEntityId: 'tx-1',
    );
    await service.recordOpened(
      logId: logId,
      channel: NotificationLogChannel.apns,
      notificationType: 'new_transaction',
    );
    await service.recordOpened(
      logId: logId,
      channel: NotificationLogChannel.apns,
      notificationType: 'new_transaction',
    );
    await service.recordOpened(
      logId: logId,
      channel: NotificationLogChannel.apns,
      notificationType: 'new_transaction',
    );

    final events = await _eventsFor(db, logId);
    final openedCount = events.where((e) => e['event_type'] == 'opened').length;
    expect(openedCount, 1);
  });

  test('new events start unsynced (synced_at is null)', () async {
    final logId = await service.recordCreated(
      channel: NotificationLogChannel.localIos,
      notificationType: 'streak_reminder',
    );
    final events = await _eventsFor(db, logId);
    expect(events.single['synced_at'], isNull);
  });

  test('never writes raw text into the stored payload', () async {
    // The API surface itself has no field for arbitrary free text — only
    // structured routing fields (channel/type/relatedEntity*) are ever
    // accepted, so raw SMS content cannot reach notification_log_events
    // through this service regardless of caller behavior.
    final logId = await service.recordCreated(
      channel: NotificationLogChannel.localIos,
      notificationType: 'capture_review',
      relatedEntityType: 'transaction',
      relatedEntityId: 'tx-42',
    );
    final row = await db.customSelect(
      'SELECT payload_json FROM notification_log_events '
      'WHERE notification_log_id = ?;',
      variables: [Variable.withString(logId)],
    ).getSingle();
    final storedJson = row.read<String>('payload_json');
    expect(storedJson, '{}');
  });
}
