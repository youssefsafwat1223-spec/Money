import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_dedup_store.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/features/capture/services/ledger_sync_service.dart';

// Batch-3 Correction 3: LedgerSyncService.pull SyncPullStatus + cursor contract.

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
      'source_payload_id': null,
      'amount': 100.0,
      'amount_text': '100.0',
      'balance_after_text': null,
      'foreign_amount_text': null,
      'currency': 'SAR',
      'direction': 'debit',
      'transaction_type': 'expense',
      'source': 'ios_shortcut',
      'merchant': 'M $id',
      'occurred_at': '2026-01-01T10:00:00.000Z',
      'updated_at': updatedAt,
      'confidence': 0.9,
    };

class _FakeRemote implements LedgerRemoteSource {
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

Future<int> _txnCount(AppDatabase db) async =>
    (await db.customSelect('SELECT COUNT(*) AS n FROM transactions;').getSingle())
        .read<int>('n');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  LedgerSyncService svc(
    AppDatabase db,
    _FakeRemote remote, {
    bool enabled = true,
    bool signedIn = true,
    int pageSize = 200,
  }) =>
      LedgerSyncService(
        db: db,
        transactionRepository: DriftTransactionRepository(db),
        dedupStore: DriftDedupStore(db),
        isPullEnabled: () => enabled,
        remoteSource: remote,
        getAuthUserId: () async => signedIn ? 'user-1' : null,
        pageSize: pageSize,
      
    // C-3: covers pull MECHANICS; consent is asserted in
    // financial_pull_consent_test.dart.
    mayEgress: () async => true,
  );

  test('completed: EOF -> completed + cursor at final high-water', () async {
    final db = await _openDb();
    addTearDown(db.close);
    final remote = _FakeRemote([
      [_row('s1', '2026-01-01T00:00:00.000Z')],
      [_row('s2', '2026-01-02T00:00:00.000Z')],
    ]);
    final result = await svc(db, remote, pageSize: 1).pull();
    expect(result.status, SyncPullStatus.completed);
    expect((await readSyncCursor(db, 'ledger_transactions')).id, 's2');
    expect(await _txnCount(db), 2);
  });

  test('deferred (disabled): deferred, zero apply, cursor unchanged', () async {
    final db = await _openDb();
    addTearDown(db.close);
    await writeSyncCursor(db, 'ledger_transactions',
        const SyncCursor(updatedAt: '2025-01-01T00:00:00.000Z', id: 'keep'));
    final remote = _FakeRemote([
      [_row('s1', '2026-01-01T00:00:00.000Z')]
    ]);
    final result = await svc(db, remote, enabled: false).pull();
    expect(result.status, SyncPullStatus.deferred);
    expect(remote.fetchCount, 0);
    expect((await readSyncCursor(db, 'ledger_transactions')).id, 'keep');
    expect(await _txnCount(db), 0);
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
        [_row('s1', '2026-01-01T00:00:00.000Z')],
        [_row('s2', '2026-01-02T00:00:00.000Z')],
      ],
      onFetch: (i) {
        if (i == 1) admitted = false;
      },
    );
    final result =
        await svc(db, remote, pageSize: 1).pull(isAdmitted: () => admitted);
    expect(result.status, SyncPullStatus.failed);
    expect(await _txnCount(db), 1);
    expect((await readSyncCursor(db, 'ledger_transactions')).id, 's1');
  });

  test('from: epoch deferred does not reset the persisted cursor', () async {
    final db = await _openDb();
    addTearDown(db.close);
    await writeSyncCursor(db, 'ledger_transactions',
        const SyncCursor(updatedAt: '2025-09-09T00:00:00.000Z', id: 'hw'));
    final result = await svc(db, _FakeRemote(const []), enabled: false)
        .pull(from: const SyncCursor.epoch());
    expect(result.status, SyncPullStatus.deferred);
    expect((await readSyncCursor(db, 'ledger_transactions')).id, 'hw');
  });
}
