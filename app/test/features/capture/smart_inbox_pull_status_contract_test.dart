import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/features/capture/services/smart_inbox_sync_service.dart';

// Batch-3 Correction 3: SmartInboxSyncService.pull SyncPullStatus + cursor
// contract (completed / deferred / failed / cancelled), same as Accounts/Ledger.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

Future<AppDatabase> _openDb() =>
    AppDatabase.open(executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());

Map<String, dynamic> _row(String id, String updatedAt) => {
      'id': id,
      'transaction_id': null,
      'payload_id': null,
      'type': 'needs_review',
      'title': 'T $id',
      'body': null,
      'status': 'open',
      'confidence': null,
      'metadata': null,
      'created_at': '2026-01-01T00:00:00.000Z',
      'updated_at': updatedAt,
    };

class _FakeRemote implements SmartInboxRemoteSource {
  _FakeRemote(this.pages, {this.throwOnFetch = false, this.onFetch});
  final List<List<Map<String, dynamic>>> pages;
  final bool throwOnFetch;
  final void Function(int fetchIndex)? onFetch;
  int _i = 0;
  int fetchCount = 0;

  @override
  Future<List<Map<String, dynamic>>> fetchRows({
    required SyncCursor after,
    int limit = 200,
  }) async {
    onFetch?.call(fetchCount);
    fetchCount++;
    if (throwOnFetch) throw StateError('network down');
    if (_i >= pages.length) return const [];
    return pages[_i++];
  }

  @override
  Future<void> pushStatus(String serverId, String status) async {}
}

Future<int> _count(AppDatabase db) async =>
    (await db.customSelect('SELECT COUNT(*) AS n FROM smart_inbox_items;').getSingle())
        .read<int>('n');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  SmartInboxSyncService svc(
    AppDatabase db,
    _FakeRemote remote, {
    bool enabled = true,
    bool signedIn = true,
    int pageSize = 200,
  }) =>
      SmartInboxSyncService(
        db: db,
        isPullEnabled: () => enabled,
        getAuthUserId: () async => signedIn ? 'user-1' : null,
        remoteSource: remote,
        pageSize: pageSize,
      );

  test('completed: EOF -> completed + cursor at final high-water', () async {
    final db = await _openDb();
    addTearDown(db.close);
    final remote = _FakeRemote([
      [_row('s1', '2023-01-01T00:00:00.000Z')],
      [_row('s2', '2023-01-02T00:00:00.000Z')],
    ]);
    final result = await svc(db, remote, pageSize: 1).pull();
    expect(result.status, SyncPullStatus.completed);
    final cursor = await readSyncCursor(db, 'smart_inbox');
    expect(cursor.id, 's2');
    expect(await _count(db), 2);
  });

  test('deferred (disabled): deferred, zero apply, cursor unchanged', () async {
    final db = await _openDb();
    addTearDown(db.close);
    await writeSyncCursor(db, 'smart_inbox',
        const SyncCursor(updatedAt: '2022-01-01T00:00:00.000Z', id: 'keep'));
    final remote = _FakeRemote([
      [_row('s1', '2023-01-01T00:00:00.000Z')]
    ]);
    final result = await svc(db, remote, enabled: false).pull();
    expect(result.status, SyncPullStatus.deferred);
    expect(remote.fetchCount, 0);
    expect((await readSyncCursor(db, 'smart_inbox')).id, 'keep');
    expect(await _count(db), 0);
  });

  test('deferred (no auth): deferred', () async {
    final db = await _openDb();
    addTearDown(db.close);
    final result = await svc(db, _FakeRemote(const []), signedIn: false).pull();
    expect(result.status, SyncPullStatus.deferred);
  });

  test('failed: injected network error -> failed', () async {
    final db = await _openDb();
    addTearDown(db.close);
    final result =
        await svc(db, _FakeRemote(const [], throwOnFetch: true)).pull();
    expect(result.status, SyncPullStatus.failed);
  });

  test('cancelled mid-page: admission lost after page 1 -> failed, cursor at s1',
      () async {
    final db = await _openDb();
    addTearDown(db.close);
    var admitted = true;
    final remote = _FakeRemote(
      [
        [_row('s1', '2023-01-01T00:00:00.000Z')],
        [_row('s2', '2023-01-02T00:00:00.000Z')],
      ],
      onFetch: (i) {
        if (i == 1) admitted = false;
      },
    );
    final result =
        await svc(db, remote, pageSize: 1).pull(isAdmitted: () => admitted);
    expect(result.status, SyncPullStatus.failed);
    expect(await _count(db), 1);
    expect((await readSyncCursor(db, 'smart_inbox')).id, 's1');
  });

  test('from: epoch deferred does not reset the persisted cursor', () async {
    final db = await _openDb();
    addTearDown(db.close);
    await writeSyncCursor(db, 'smart_inbox',
        const SyncCursor(updatedAt: '2022-09-09T00:00:00.000Z', id: 'hw'));
    final result = await svc(db, _FakeRemote(const []), enabled: false)
        .pull(from: const SyncCursor.epoch());
    expect(result.status, SyncPullStatus.deferred);
    expect((await readSyncCursor(db, 'smart_inbox')).id, 'hw');
  });
}
