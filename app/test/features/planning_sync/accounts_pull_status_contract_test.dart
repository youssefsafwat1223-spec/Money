import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/features/planning_sync/services/accounts_pull_service.dart';

// Batch-3 Correction 3: prove AccountsPullService reports the correct
// SyncPullStatus and cursor behaviour for completed / deferred / failed /
// cancelled — the contract the LegacyFinancialCacheReconciler relies on.

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
      'local_id': null,
      'name': 'Acc $id',
      'currency': 'SAR',
      'type': 'bank',
      'initial_balance_text': '0',
      'current_balance_text': '0',
      'credit_limit_text': null,
      'available_credit_text': null,
      'updated_at': updatedAt,
      'deleted_at': null,
    };

/// Returns successive [pages] regardless of the incoming cursor; optionally
/// throws, or invokes [onFetch] (used to flip admission mid-pull).
class _FakeRemote implements AccountsRemoteSource {
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
}

Future<int> _accountCount(AppDatabase db) async {
  final row = await db
      .customSelect('SELECT COUNT(*) AS n FROM accounts;')
      .getSingle();
  return row.read<int>('n');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('completed: reaches EOF -> status.completed + cursor at final high-water',
      () async {
    final db = await _openDb();
    addTearDown(db.close);
    await db.customStatement('DELETE FROM accounts;');
    final remote = _FakeRemote([
      [_row('s1', '2023-01-01T00:00:00.000Z')],
      [_row('s2', '2023-01-02T00:00:00.000Z')],
    ]);
    final svc = AccountsPullService(
      db: db,
      isEnabled: () => true,
      getAuthUserId: () async => 'user-1',
      remoteSource: remote,
      pageSize: 1,
    
    // C-3: covers pull MECHANICS; consent is asserted in
    // financial_pull_consent_test.dart.
    mayEgress: () async => true,
  );

    final result = await svc.pull();

    expect(result.status, SyncPullStatus.completed);
    final cursor = await readSyncCursor(db, 'accounts');
    expect(cursor.updatedAt, '2023-01-02T00:00:00.000Z');
    expect(cursor.id, 's2');
    expect(await _accountCount(db), 2);
  });

  test('deferred (disabled): status.deferred, zero apply, cursor unchanged',
      () async {
    final db = await _openDb();
    addTearDown(db.close);
    await db.customStatement('DELETE FROM accounts;');
    await writeSyncCursor(
        db, 'accounts', const SyncCursor(updatedAt: '2022-05-05T00:00:00.000Z', id: 'keep'));
    final remote = _FakeRemote([
      [_row('s1', '2023-01-01T00:00:00.000Z')]
    ]);
    final svc = AccountsPullService(
      db: db,
      isEnabled: () => false,
      getAuthUserId: () async => 'user-1',
      remoteSource: remote,
    
    // C-3: covers pull MECHANICS; consent is asserted in
    // financial_pull_consent_test.dart.
    mayEgress: () async => true,
  );

    final result = await svc.pull();

    expect(result.status, SyncPullStatus.deferred);
    expect(remote.fetchCount, 0, reason: 'no network work when disabled');
    final cursor = await readSyncCursor(db, 'accounts');
    expect(cursor.updatedAt, '2022-05-05T00:00:00.000Z');
    expect(cursor.id, 'keep');
    expect(await _accountCount(db), 0);
  });

  test('deferred (no auth): status.deferred, cursor unchanged', () async {
    final db = await _openDb();
    addTearDown(db.close);
    await writeSyncCursor(
        db, 'accounts', const SyncCursor(updatedAt: '2022-06-06T00:00:00.000Z', id: 'keep2'));
    final svc = AccountsPullService(
      db: db,
      isEnabled: () => true,
      getAuthUserId: () async => null,
      remoteSource: _FakeRemote(const []),
    
    // C-3: covers pull MECHANICS; consent is asserted in
    // financial_pull_consent_test.dart.
    mayEgress: () async => true,
  );

    final result = await svc.pull();

    expect(result.status, SyncPullStatus.deferred);
    final cursor = await readSyncCursor(db, 'accounts');
    expect(cursor.id, 'keep2');
  });

  test('failed: injected network error -> status.failed, never completed',
      () async {
    final db = await _openDb();
    addTearDown(db.close);
    final svc = AccountsPullService(
      db: db,
      isEnabled: () => true,
      getAuthUserId: () async => 'user-1',
      remoteSource: _FakeRemote(const [], throwOnFetch: true),
    
    // C-3: covers pull MECHANICS; consent is asserted in
    // financial_pull_consent_test.dart.
    mayEgress: () async => true,
  );

    final result = await svc.pull();

    expect(result.status, SyncPullStatus.failed);
  });

  test(
      'cancelled mid-page (same-UID / new generation): admission lost after page '
      '1 -> page 2 not applied, no further cursor advance, status.failed',
      () async {
    final db = await _openDb();
    addTearDown(db.close);
    await db.customStatement('DELETE FROM accounts;');
    var admitted = true;
    final remote = _FakeRemote(
      [
        [_row('s1', '2023-01-01T00:00:00.000Z')],
        [_row('s2', '2023-01-02T00:00:00.000Z')],
      ],
      onFetch: (i) {
        if (i == 1) admitted = false; // sign-out before page 2 applies
      },
    );
    final svc = AccountsPullService(
      db: db,
      isEnabled: () => true,
      getAuthUserId: () async => 'user-1',
      remoteSource: remote,
      pageSize: 1,
    
    // C-3: covers pull MECHANICS; consent is asserted in
    // financial_pull_consent_test.dart.
    mayEgress: () async => true,
  );

    final result = await svc.pull(isAdmitted: () => admitted);

    expect(result.status, SyncPullStatus.failed);
    // Page 1 committed and its cursor persisted; page 2 never applied.
    expect(await _accountCount(db), 1);
    final cursor = await readSyncCursor(db, 'accounts');
    expect(cursor.id, 's1');
  });

  test('from: epoch override does not destroy a good persisted cursor when deferred',
      () async {
    final db = await _openDb();
    addTearDown(db.close);
    await writeSyncCursor(
        db, 'accounts', const SyncCursor(updatedAt: '2022-07-07T00:00:00.000Z', id: 'hw'));
    final svc = AccountsPullService(
      db: db,
      isEnabled: () => false, // capability off -> deferred before reading `from`
      getAuthUserId: () async => 'user-1',
      remoteSource: _FakeRemote(const []),
    
    // C-3: covers pull MECHANICS; consent is asserted in
    // financial_pull_consent_test.dart.
    mayEgress: () async => true,
  );

    final result = await svc.pull(from: const SyncCursor.epoch());

    expect(result.status, SyncPullStatus.deferred);
    final cursor = await readSyncCursor(db, 'accounts');
    expect(cursor.updatedAt, '2022-07-07T00:00:00.000Z',
        reason: 'a deferred reconciliation pull must not reset the cursor');
    expect(cursor.id, 'hw');
  });
}
