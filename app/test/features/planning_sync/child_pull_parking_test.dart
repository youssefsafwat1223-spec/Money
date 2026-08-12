import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/features/planning_sync/services/planning_child_sync_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

/// Pull-only fake: serves injected server rows with real keyset pagination and
/// can be told to throw on a chosen page to exercise partial-failure recovery.
class _FakeChildRemote implements PlanningChildRemote {
  final rows = <String, List<Map<String, dynamic>>>{};
  int throwOnFetchCall = -1;
  int _fetchCalls = 0;

  @override
  Future<List<Map<String, dynamic>>> fetchRows(
    String table, {
    required SyncCursor after,
    int limit = 200,
  }) async {
    _fetchCalls++;
    if (_fetchCalls == throwOnFetchCall) {
      throw StateError('injected fetch failure on call $_fetchCalls');
    }
    final all = [...(rows[table] ?? const <Map<String, dynamic>>[])]..sort((a, b) {
        final t = normalizeCursorTimestamp(a['updated_at'])
            .compareTo(normalizeCursorTimestamp(b['updated_at']));
        return t != 0 ? t : (a['id'] as String).compareTo(b['id'] as String);
      });
    return all
        .where((row) {
          if (after.id.isEmpty) return true;
          final ts = normalizeCursorTimestamp(row['updated_at']);
          final c = ts.compareTo(after.updatedAt);
          return c > 0 || (c == 0 && (row['id'] as String).compareTo(after.id) > 0);
        })
        .take(limit)
        .toList();
  }

  @override
  Future<Map<String, dynamic>> callRpc(String n, Map<String, dynamic> p) async =>
      throw UnimplementedError();
  @override
  Future<Map<String, dynamic>> upsertPlanLink(Map<String, dynamic> r) async =>
      throw UnimplementedError();
  @override
  Future<Map<String, dynamic>?> findPlanLink({
    required String userId,
    required String planId,
    required String transactionId,
  }) async =>
      null;
  @override
  Future<void> tombstonePlanLink(String serverId) async {}
}

Map<String, dynamic> _gc(String id, {required String goalServerId, String when = '2026-07-23T10:00:00.000Z'}) => {
      'id': id,
      'local_id': id,
      'goal_id': goalServerId,
      // §9: canonical pull carries the exact NUMERIC::text amount; the parent
      // goal (seeded 'SAR') is the currency authority.
      'amount': 5.0,
      'amount_text': '5.00',
      'created_at': when,
      'note': null,
      'updated_at': when,
      'deleted_at': null,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppDatabase> openDb() => AppDatabase.open(
        executor: NativeDatabase.memory(),
        keyStore: _MemoryKeyStore(),
      );

  PlanningChildSyncService service(
    AppDatabase db,
    _FakeChildRemote remote, {
    int pageSize = 200,
  }) =>
      PlanningChildSyncService(
        db: db,
        queue: PlanningOutboxQueue(
          db: db,
          isSyncEnabled: (_) => true,
          getAuthUserId: () async => 'user-1',
        ),
        isEnabled: (_) => true,
        getAuthUserId: () async => 'user-1',
        remote: remote,
        pageSize: pageSize,
      );

  Future<void> seedGoal(AppDatabase db, String serverId) => db.customStatement(
        "INSERT INTO goals(id,name,currency,target_amount,target_amount_minor,"
        "saved_amount,saved_amount_minor,last_notified_saved_amount_minor,"
        "vault_skin,status,created_at,server_id,sync_status) VALUES "
        "('local-$serverId','هدف','SAR',100,10000,0,0,0,'classic',"
        "'active','2026-07-23T09:00:00Z','$serverId','synced');",
      );

  Future<int> count(AppDatabase db, String sql) async =>
      (await db.customSelect('SELECT COUNT(*) AS n FROM $sql;').getSingle())
          .read<int>('n');

  test('a child whose parent is not yet synced is PARKED, not dropped, and the '
      'cursor still advances', () async {
    final db = await openDb();
    addTearDown(db.close);
    final remote = _FakeChildRemote();
    remote.rows['user_goal_contributions'] = [_gc('gc1', goalServerId: 'ghost')];

    await service(db, remote).sync();

    expect(await count(db, 'goal_contributions'), 0, reason: 'not applied');
    expect(await count(db, "parked_child_rows WHERE server_id='gc1'"), 1,
        reason: 'durably parked');
    // Cursor advanced past the parked row (it is safely captured).
    final cursor = await readSyncCursor(db, 'planning_child_goal_contributions');
    expect(cursor.id, 'gc1');
  });

  test('a parked child is applied on a LATER cycle once its parent arrives, and '
      'is then unparked (durable across service instances)', () async {
    final db = await openDb();
    addTearDown(db.close);
    final remote = _FakeChildRemote();
    remote.rows['user_goal_contributions'] = [_gc('gc1', goalServerId: 'g-srv')];

    await service(db, remote).sync(); // parked (parent missing)
    expect(await count(db, "parked_child_rows WHERE server_id='gc1'"), 1);

    await seedGoal(db, 'g-srv'); // parent now exists locally
    // A NEW service instance (simulating a later launch / process restart) still
    // sees the durable parked row and drains it.
    await service(db, remote).sync();

    expect(await count(db, "goal_contributions WHERE server_id='gc1'"), 1,
        reason: 'parked child applied after parent synced');
    expect(await count(db, 'parked_child_rows'), 0, reason: 'unparked');
  });

  test('parking + draining is idempotent under duplicate replay', () async {
    final db = await openDb();
    addTearDown(db.close);
    await seedGoal(db, 'g-srv');
    final remote = _FakeChildRemote();
    remote.rows['user_goal_contributions'] = [_gc('gc1', goalServerId: 'g-srv')];

    await service(db, remote).sync();
    await service(db, remote).sync(); // replay same row
    await service(db, remote).sync();

    expect(await count(db, "goal_contributions WHERE server_id='gc1'"), 1,
        reason: 'exactly one row despite replay');
    expect(await count(db, 'parked_child_rows'), 0);
  });

  test('pagination at scale: many missing-parent children across pages are ALL '
      'parked, then all applied after the parent arrives', () async {
    final db = await openDb();
    addTearDown(db.close);
    final remote = _FakeChildRemote();
    remote.rows['user_goal_contributions'] = [
      for (var i = 0; i < 250; i++)
        _gc('gc$i',
            goalServerId: 'g-srv',
            when: '2026-07-23T10:00:${(i % 60).toString().padLeft(2, '0')}.000Z'),
    ];

    await service(db, remote, pageSize: 100).sync(); // 3 pages, all parked
    expect(await count(db, 'parked_child_rows'), 250);
    expect(await count(db, 'goal_contributions'), 0);

    await seedGoal(db, 'g-srv');
    await service(db, remote, pageSize: 100).sync(); // drain applies all
    expect(await count(db, 'goal_contributions'), 250);
    expect(await count(db, 'parked_child_rows'), 0);
  });

  test('a permanently invalid parent relationship becomes TERMINAL after the '
      'bound, so it stops looping but stays visible', () async {
    final db = await openDb();
    addTearDown(db.close);
    final remote = _FakeChildRemote();
    remote.rows['user_goal_contributions'] = [_gc('gc1', goalServerId: 'never')];

    // Parent never arrives. Drive enough cycles to exceed the attempt bound.
    for (var i = 0; i < 30; i++) {
      await service(db, remote).sync();
    }

    final row = await db
        .customSelect("SELECT reason, attempt_count FROM parked_child_rows "
            "WHERE server_id='gc1';")
        .getSingle();
    expect(row.read<String>('reason'), 'terminal',
        reason: 'no infinite loop; visible terminal state');
    expect(await count(db, 'goal_contributions'), 0);
  });

  test('a partial-page fetch failure does not advance the cursor past unfetched '
      'rows; a later cycle resumes correctly', () async {
    final db = await openDb();
    addTearDown(db.close);
    await seedGoal(db, 'g-srv');
    final remote = _FakeChildRemote();
    remote.rows['user_goal_contributions'] = [
      _gc('gc1', goalServerId: 'g-srv', when: '2026-07-23T10:00:01.000Z'),
      _gc('gc2', goalServerId: 'g-srv', when: '2026-07-23T10:00:02.000Z'),
      _gc('gc3', goalServerId: 'g-srv', when: '2026-07-23T10:00:03.000Z'),
    ];
    remote.throwOnFetchCall = 2; // page 1 applies, page 2 fetch throws

    await service(db, remote, pageSize: 1).sync(); // partial
    final applied1 = await count(db, 'goal_contributions');
    expect(applied1, greaterThanOrEqualTo(1));
    expect(applied1, lessThan(3), reason: 'aborted before all pages');

    remote.throwOnFetchCall = -1; // recover
    await service(db, remote, pageSize: 1).sync(); // resume from cursor
    expect(await count(db, 'goal_contributions'), 3, reason: 'no rows lost');
  });
}
