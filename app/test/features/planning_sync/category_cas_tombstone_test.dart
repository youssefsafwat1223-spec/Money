import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_category_repository.dart';
import 'package:money_companion/data/sync/server_capabilities.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';
import 'package:money_companion/features/planning_sync/services/planning_push_service.dart';
import '../../harness/fake_cas_server.dart';

// D1 (user decision 5a): a category delete pushes through the CAS tombstone RPC
// (0116 sync_cas_tombstone_category) when revision_cas is verified; the legacy
// guarded tombstone is unchanged when it is not.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

class _LegacySink implements PlanningRemoteSink {
  int guardedTombstones = 0;
  @override
  Future<Map<String, dynamic>?> guardedTombstone(
      String t, String s, String? u) async {
    guardedTombstones++;
    return {'id': s, 'updated_at': 'ts'};
  }

  @override
  dynamic noSuchMethod(Invocation i) => throw StateError('unexpected ${i.memberName}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late PlanningOutboxQueue queue;
  late String catId;

  setUp(() async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    queue = PlanningOutboxQueue(
      db: db,
      isSyncEnabled: (_) => true,
      getAuthUserId: () async => 'user-1',
    );
    final repo = DriftCategoryRepository(db, outboxQueue: queue);
    final c = await repo.createCategory(
        nameAr: 'تبرعات', icon: 'heart', color: '#ff0000', isIncome: false);
    catId = c.id;
    await db.customStatement('DELETE FROM planning_sync_outbox;');
    await db.customStatement(
      "UPDATE categories SET server_id = 'srv-c1', server_updated_at = 'base-ts', "
      "server_revision = 5, sync_status = 'synced' WHERE id = '$catId';",
    );
    await repo.deleteCategory(catId);
  });
  tearDown(() => db.close());

  PlanningPushService casPush(FakeCasServer srv,
          {String epoch = 'e1',
          ServerCapabilityState cap = ServerCapabilityState.verified,
          PlanningRemoteSink? sink}) =>
      PlanningPushService(
        mayEgress: () async => true,
        db: db,
        queue: queue,
        isEnabled: (_) => true,
        getAuthUserId: () async => 'user-1',
        remoteSink: sink ?? _LegacySink(),
        casGate: casGate(db, epoch: epoch, capability: cap),
        casRemote: srv,
      );

  Future<String?> status() async => (await db
          .customSelect("SELECT sync_status FROM categories WHERE id='$catId';")
          .getSingle())
      .readNullable<String>('sync_status');

  test('revision_cas verified: the delete is a CAS tombstone on user_categories',
      () async {
    final srv = FakeCasServer()
      ..seed('user_categories', {'local_id': catId}, id: 'srv-c1', revision: 5);
    final r = await casPush(srv).push();
    expect(r.pushed, 1);
    expect(srv.calls, ['tombstone:user_categories']);
    expect(srv.tables['user_categories']!['srv-c1']!['deleted_at'], isNotNull);
    expect(await status(), 'synced');
  });

  test('replay after a lost ACK converges (ack), no conflict', () async {
    final srv = FakeCasServer()
      ..seed('user_categories', {'local_id': catId}, id: 'srv-c1', revision: 5)
      ..loseNextAck = true;
    expect((await casPush(srv).push()).failed, 1);
    await db.customStatement('UPDATE planning_sync_outbox SET next_retry_at = NULL;');
    final r = await casPush(srv).push();
    expect(r.pushed, 1);
    expect(r.conflicts, 0);
    expect(await status(), 'synced');
  });

  test('already tombstoned in the cloud: the delete converged', () async {
    final srv = FakeCasServer()
      ..seed('user_categories', {'local_id': catId},
          id: 'srv-c1', revision: 5, deletedAt: '2026-08-01T00:00:00.000Z');
    final r = await casPush(srv).push();
    expect(r.pushed, 1);
    expect(await status(), 'synced');
  });

  test('stale revision: interactive delete conflict, the cloud row is not '
      'deleted', () async {
    final srv = FakeCasServer()
      ..seed('user_categories', {'local_id': catId, 'name_ar': 'x'},
          id: 'srv-c1', revision: 5)
      ..foreignEdit('user_categories', 'srv-c1', {'name_ar': 'Theirs'});
    final r = await casPush(srv).push();
    expect(r.conflicts, 1);
    expect(srv.tables['user_categories']!['srv-c1']!['deleted_at'], isNull);
    expect(await status(), 'conflict');
    final kind = (await db.customSelect('SELECT kind FROM sync_conflicts').getSingle())
        .read<String>('kind');
    expect(kind, 'delete');
  });

  test('stale epoch: stays queued, nothing consumed', () async {
    final srv = FakeCasServer(epoch: 'e2')
      ..seed('user_categories', {'local_id': catId}, id: 'srv-c1', revision: 5);
    final r = await casPush(srv).push();
    expect(r.pushed + r.failed + r.conflicts, 0);
    final row = await db
        .customSelect('SELECT status, attempt_count FROM planning_sync_outbox')
        .getSingle();
    expect(row.read<String>('status'), 'pending');
    expect(row.read<int>('attempt_count'), 0);
    expect(srv.tables['user_categories']!['srv-c1']!['deleted_at'], isNull);
  });

  test('revision_cas unsupported (production): legacy guarded tombstone, the '
      'RPCs are never called', () async {
    final srv = FakeCasServer();
    final sink = _LegacySink();
    final r = await casPush(srv, cap: ServerCapabilityState.unsupported, sink: sink).push();
    expect(r.pushed, 1);
    expect(sink.guardedTombstones, 1);
    expect(srv.calls, isEmpty);
    expect(await status(), 'synced');
  });
}
