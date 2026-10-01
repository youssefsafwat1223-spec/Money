import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_dedup_store.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/features/capture/services/ledger_sync_service.dart';
import 'package:money_companion/features/planning_sync/services/accounts_pull_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';
import 'package:money_companion/features/planning_sync/services/planning_pull_service.dart';

/// A-1c — a NORMAL pull stops after [maxPagesPerRun] pages (not completed) and
/// the next cycle continues from the persisted cursor; an epoch/reconcile pull
/// (`from` given) is exempt, because it restarts from epoch and must reach EOF.
class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

/// Tombstones for ids that do not exist locally: they apply as no-ops but still
/// carry the keyset cursor, which is all this test is about.
Map<String, dynamic> _tomb(int i) => {
      'id': 's$i',
      'updated_at': '2023-01-${(i + 1).toString().padLeft(2, '0')}T00:00:00.000Z',
      'deleted_at': '2023-02-01T00:00:00.000Z',
    };

/// Serves one row per page from a keyset-ordered list, honouring the cursor.
List<Map<String, dynamic>> _serve(
    List<Map<String, dynamic>> all, SyncCursor after, int limit) {
  final rest = after.id.isEmpty
      ? all
      : all.where((r) => (r['id'] as String).compareTo(after.id) > 0).toList();
  return rest.take(limit).toList();
}

class _AccountsRemote implements AccountsRemoteSource {
  _AccountsRemote(this.all);
  final List<Map<String, dynamic>> all;
  int fetches = 0;
  @override
  Future<List<Map<String, dynamic>>> fetchRows(
      {required SyncCursor after, int limit = 200}) async {
    fetches++;
    return _serve(all, after, limit);
  }
}

class _LedgerRemote implements LedgerRemoteSource {
  _LedgerRemote(this.all);
  final List<Map<String, dynamic>> all;
  int fetches = 0;
  @override
  Future<List<Map<String, dynamic>>> fetchRows(
      {required SyncCursor after, int limit = 200}) async {
    fetches++;
    return _serve(all, after, limit);
  }
}

class _PlanningRemote implements PlanningRemoteSource {
  _PlanningRemote(this.all);
  final List<Map<String, dynamic>> all;
  int fetches = 0;
  @override
  Future<List<Map<String, dynamic>>> fetchRows(String table,
      {required SyncCursor after, int limit = 200}) async {
    if (table != 'user_cards') return const [];
    fetches++;
    return _serve(all, after, limit);
  }
}

void main() {
  late AppDatabase db;
  final rows = [for (var i = 0; i < 5; i++) _tomb(i)];

  setUp(() async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
  });
  tearDown(() async => db.close());

  test('accounts: capped run is not completed; next runs continue; epoch '
      'pull is exempt', () async {
    final remote = _AccountsRemote(rows);
    AccountsPullService svc() => AccountsPullService(
          db: db,
          isEnabled: () => true,
          getAuthUserId: () async => 'u1',
          remoteSource: remote,
          pageSize: 1,
          maxPagesPerRun: 2,
          mayEgress: () async => true,
        );

    final r1 = await svc().pull();
    expect(remote.fetches, 2);
    expect(r1.status, SyncPullStatus.failed, reason: 'capped => not completed');
    final r2 = await svc().pull();
    expect(remote.fetches, 4, reason: 'continues from the persisted cursor');
    expect(r2.status, SyncPullStatus.failed);
    final r3 = await svc().pull();
    expect(r3.status, SyncPullStatus.completed, reason: 'reached EOF');

    remote.fetches = 0;
    final epoch = await svc().pull(from: const SyncCursor.epoch());
    expect(epoch.status, SyncPullStatus.completed);
    expect(remote.fetches, 6, reason: '5 pages + the EOF page, uncapped');
  });

  test('ledger: capped run is not completed; epoch pull is exempt', () async {
    final remote = _LedgerRemote(rows);
    LedgerSyncService svc() => LedgerSyncService(
          db: db,
          transactionRepository: DriftTransactionRepository(db),
          dedupStore: DriftDedupStore(db),
          isPullEnabled: () => true,
          mayEgress: () async => true,
          getAuthUserId: () async => 'u1',
          remoteSource: remote,
          pageSize: 1,
          maxPagesPerRun: 2,
        );
    expect((await svc().pull()).status, SyncPullStatus.failed);
    expect(remote.fetches, 2);
    expect((await svc().pull()).status, SyncPullStatus.failed);
    expect((await svc().pull()).status, SyncPullStatus.completed);
    remote.fetches = 0;
    expect((await svc().pull(from: const SyncCursor.epoch())).status,
        SyncPullStatus.completed);
    expect(remote.fetches, 6);
  });

  test('planning: per-entity cap; entity not reported completed until EOF',
      () async {
    final remote = _PlanningRemote(rows);
    PlanningPullService svc() => PlanningPullService(
          db: db,
          isEnabled: (e) => e == PlanningOutboxQueue.cardsEntityType,
          getAuthUserId: () async => 'u1',
          remoteSource: remote,
          pageSize: 1,
          maxPagesPerRun: 2,
          mayEgress: () async => true,
          mayEgressProfile: () async => true,
        );
    final r1 = await svc().pull();
    expect(remote.fetches, 2);
    expect(r1.completedEntities, isNot(contains(PlanningOutboxQueue.cardsEntityType)));
    await svc().pull();
    final r3 = await svc().pull();
    expect(r3.completedEntities, contains(PlanningOutboxQueue.cardsEntityType));
  });
}
