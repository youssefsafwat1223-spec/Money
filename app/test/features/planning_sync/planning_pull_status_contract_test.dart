import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';
import 'package:money_companion/features/planning_sync/services/planning_pull_service.dart';

// Batch-3 Correction 3: Planning is per-entity (own `planning_<type>` cursor).
// Prove fromEpochEntities restarts only the requested entities from epoch, leaves
// siblings' cursors untouched, and reports completedEntities on true-EOF only.
// A recording/empty-or-throw remote isolates cursor + completion semantics
// without needing full row application.

const _budget = PlanningOutboxQueue.budgetsEntityType; // 'budget'
const _goal = PlanningOutboxQueue.goalsEntityType; // 'goal'

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

Future<AppDatabase> _openDb() =>
    AppDatabase.open(executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());

/// Records the [SyncCursor] passed per table; returns an empty page (clean EOF)
/// unless the table is in [throwFor].
class _RecordingRemote implements PlanningRemoteSource {
  _RecordingRemote({this.throwFor = const {}});
  final Set<String> throwFor;
  final Map<String, SyncCursor> seenAfter = {};

  @override
  Future<List<Map<String, dynamic>>> fetchRows(
    String table, {
    required SyncCursor after,
    int limit = 200,
  }) async {
    seenAfter[table] = after;
    if (throwFor.contains(table)) throw StateError('network down');
    return const [];
  }
}

PlanningPullService _svc(
  AppDatabase db,
  PlanningRemoteSource remote, {
  required bool Function(String) isEnabled,
  bool signedIn = true,
}) =>
    PlanningPullService(
      db: db,
      isEnabled: isEnabled,
      getAuthUserId: () async => signedIn ? 'user-1' : null,
      remoteSource: remote,
    
    // C-3: covers pull MECHANICS; consent is asserted in
    // financial_pull_consent_test.dart.
    mayEgress: () async => true,
  );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('fromEpochEntities: requested entity restarts from epoch', () async {
    final db = await _openDb();
    addTearDown(db.close);
    await writeSyncCursor(db, 'planning_$_budget',
        const SyncCursor(updatedAt: '2025-01-01T00:00:00.000Z', id: 'old'));
    final remote = _RecordingRemote();
    final result = await _svc(db, remote, isEnabled: (e) => e == _budget)
        .pull(fromEpochEntities: {_budget});
    expect(remote.seenAfter['user_budgets']?.id, '',
        reason: 'requested entity ignores the persisted high-water cursor');
    expect(result.completedEntities, contains(_budget));
  });

  test('non-requested sibling keeps its persisted cursor and it is untouched',
      () async {
    final db = await _openDb();
    addTearDown(db.close);
    await writeSyncCursor(db, 'planning_$_budget',
        const SyncCursor(updatedAt: '2025-02-02T00:00:00.000Z', id: 'hw'));
    final remote = _RecordingRemote();
    // budget enabled but NOT in fromEpochEntities -> incremental from persisted.
    final result = await _svc(db, remote, isEnabled: (e) => e == _budget)
        .pull(fromEpochEntities: const {});
    expect(remote.seenAfter['user_budgets']?.id, 'hw');
    // empty page -> no cursor write -> persisted cursor unchanged.
    expect((await readSyncCursor(db, 'planning_$_budget')).id, 'hw');
    expect(result.completedEntities, contains(_budget));
  });

  test(
      'completedEntities is true-EOF only: budget completes, goal throws -> '
      'budget completed, goal absent (no false completion)', () async {
    final db = await _openDb();
    addTearDown(db.close);
    final remote = _RecordingRemote(throwFor: {'user_goals'});
    final result =
        await _svc(db, remote, isEnabled: (e) => e == _budget || e == _goal)
            .pull(fromEpochEntities: {_budget, _goal});
    expect(result.completedEntities, contains(_budget),
        reason: 'a successful sibling completes independently');
    expect(result.completedEntities, isNot(contains(_goal)),
        reason: 'a failed entity must not be reported completed');
  });

  test('deferred (no auth): empty completedEntities', () async {
    final db = await _openDb();
    addTearDown(db.close);
    final result =
        await _svc(db, _RecordingRemote(), isEnabled: (_) => true, signedIn: false)
            .pull(fromEpochEntities: {_budget});
    expect(result.completedEntities, isEmpty);
  });

  test('cancelled before work: admission invalid -> entity not completed',
      () async {
    final db = await _openDb();
    addTearDown(db.close);
    final remote = _RecordingRemote();
    final result = await _svc(db, remote, isEnabled: (e) => e == _budget)
        .pull(fromEpochEntities: {_budget}, isAdmitted: () => false);
    expect(result.completedEntities, isEmpty);
    expect(remote.seenAfter, isEmpty,
        reason: 'no page fetched once admission is invalid');
  });
}
