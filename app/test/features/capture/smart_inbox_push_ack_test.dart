import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_smart_inbox_repository.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/features/capture/services/smart_inbox_sync_service.dart';

/// A-4 (G11): a zero-row server update is a failure with backoff (never an
/// ACK); local-only items never reach the server and never stay pending_sync.
class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

class _Remote implements SmartInboxRemoteSource {
  int matched = 1;
  final calls = <String>[];

  @override
  Future<List<Map<String, dynamic>>> fetchRows(
          {required SyncCursor after, int limit = 200}) async =>
      const [];

  @override
  Future<int> pushStatus(String serverId, String status) async {
    calls.add(serverId);
    return matched;
  }
}

void main() {
  late AppDatabase db;
  late _Remote remote;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    remote = _Remote();
  });
  tearDown(() async => db.close());

  SmartInboxSyncService svc() => SmartInboxSyncService(
        db: db,
        isPullEnabled: () => true,
        getAuthUserId: () async => 'user-1',
        remoteSource: remote,
        mayEgress: () async => true,
      );

  Future<void> serverItem(String id) => db.customStatement('''
    INSERT INTO smart_inbox_items(id, server_id, type, title, status,
      server_created_at, synced_at, created_at, updated_at, pending_sync)
    VALUES ('$id', '$id', 'needs_review', 't', 'open',
      '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z',
      '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 0);
  ''');

  Future<Map<String, Object?>> item(String id) async => (await db
          .customSelect("SELECT * FROM smart_inbox_items WHERE id = '$id';")
          .getSingle())
      .data;

  test('zero matched rows is a failure with backoff, not success', () async {
    await serverItem('srv-1');
    await DriftSmartInboxRepository(db).dismiss('srv-1');
    remote.matched = 0;

    final pushed = await svc().push();

    expect(pushed, 0);
    final r = await item('srv-1');
    expect(r['pending_sync'], 1);
    expect(r['push_attempt_count'], 1);
    expect(r['push_next_retry_at'], isNotNull);

    remote.calls.clear();
    await svc().push();
    expect(remote.calls, isEmpty, reason: 'backoff has not elapsed');
  });

  test('a returned row ACKs and clears the retry state', () async {
    await serverItem('srv-1');
    await DriftSmartInboxRepository(db).dismiss('srv-1');
    await db.customStatement(
        "UPDATE smart_inbox_items SET push_attempt_count = 3, "
        "push_next_retry_at = '2020-01-01T00:00:00Z';");

    expect(await svc().push(), 1);
    final r = await item('srv-1');
    expect(r['pending_sync'], 0);
    expect(r['push_attempt_count'], 0);
    expect(r['push_next_retry_at'], isNull);
  });

  test('a local-only item never calls the server and is not left pending',
      () async {
    final repo = DriftSmartInboxRepository(db);
    final id = await repo.saveUnprocessableCapture(
        payloadId: 'p1', rawMessage: 'x', source: 'sms');
    await repo.dismiss(id);

    expect((await item(id))['pending_sync'], 0);
    await svc().push();
    expect(remote.calls, isEmpty);
    expect((await item(id))['status'], 'dismissed');
  });

  test('a legacy local-only row already stuck at pending_sync=1 is settled '
      'without a server call', () async {
    final repo = DriftSmartInboxRepository(db);
    final id = await repo.saveUnprocessableCapture(
        payloadId: 'p2', rawMessage: 'x', source: 'sms');
    await db.customStatement(
        "UPDATE smart_inbox_items SET status = 'dismissed', pending_sync = 1 "
        "WHERE id = '$id';");

    await svc().push();

    expect(remote.calls, isEmpty);
    expect((await item(id))['pending_sync'], 0);
  });
}
