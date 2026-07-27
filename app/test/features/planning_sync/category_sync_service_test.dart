import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_category_repository.dart';
import 'package:money_companion/domain/entities/category_entity.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';
import 'package:money_companion/features/planning_sync/services/planning_pull_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_push_service.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

class _FakeRemote implements PlanningRemoteSink, PlanningRemoteSource {
  final rows = <String, Map<String, Map<String, dynamic>>>{};
  final tombstones = <String, List<Map<String, dynamic>>>{};

  @override
  Future<List<Map<String, dynamic>>> fetchActiveRows(String table,
      {int limit = 200}) async {
    return (rows[table]?.values ?? const <Map<String, dynamic>>[])
        .where((r) => r['deleted_at'] == null)
        .map(Map<String, dynamic>.from)
        .toList();
  }

  @override
  Future<List<Map<String, dynamic>>> fetchTombstones(String table,
      {int limit = 200}) async {
    return (tombstones[table] ?? const <Map<String, dynamic>>[])
        .map(Map<String, dynamic>.from)
        .toList();
  }

  @override
  Future<Map<String, dynamic>?> findByLocalId(
          String table, String userId, String localId) async =>
      rows[table]?[localId];

  @override
  Future<void> tombstone(String table, String serverId) async {
    final match = rows[table]?.values.firstWhere((r) => r['id'] == serverId,
        orElse: () => <String, dynamic>{});
    if (match == null || match.isEmpty) return;
    final at = DateTime.utc(2026, 7, 6).toIso8601String();
    match['deleted_at'] = at;
    match['updated_at'] = at;
    tombstones.putIfAbsent(table, () => []).add(Map.of(match));
  }

  @override
  Future<Map<String, dynamic>> upsert(
      String table, Map<String, dynamic> row) async {
    final localId = row['local_id'] as String;
    final now = DateTime.utc(2026, 7, 5, 1).toIso8601String();
    final saved = {
      ...row,
      'id': rows[table]?[localId]?['id'] ?? 'server-$localId',
      'updated_at': now,
      'deleted_at': null,
    };
    rows.putIfAbsent(table, () => {})[localId] = saved;
    return {'id': saved['id'], 'updated_at': now};
  }
}

Future<AppDatabase> _openDb() => AppDatabase.open(
    executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());

PlanningOutboxQueue _queue(AppDatabase db) => PlanningOutboxQueue(
    db: db, isSyncEnabled: (_) => true, getAuthUserId: () async => 'user-1');

PlanningPushService _push(
        AppDatabase db, PlanningOutboxQueue q, _FakeRemote r) =>
    PlanningPushService(
        db: db,
        queue: q,
        isEnabled: (_) => true,
        getAuthUserId: () async => 'user-1',
        remoteSink: r);

PlanningPullService _pull(AppDatabase db, _FakeRemote r) => PlanningPullService(
    db: db,
    isEnabled: (_) => true,
    getAuthUserId: () async => 'user-1',
    remoteSource: r);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late _FakeRemote remote;
  late PlanningOutboxQueue queue;
  late DriftCategoryRepository categories;

  setUp(() async {
    db = await _openDb();
    remote = _FakeRemote();
    queue = _queue(db);
    categories = DriftCategoryRepository(db, outboxQueue: queue);
  });
  tearDown(() async => db.close());

  test('custom category create + edit + delete push to user_categories',
      () async {
    final c = await categories.createCategory(
        nameAr: 'تبرعات', icon: 'heart', color: '#ff0000', isIncome: false);
    await _push(db, queue, remote).push();
    expect(remote.rows['user_categories']![c.id]!['name_ar'], 'تبرعات');

    await categories.updateCategory(CategoryEntity(
        id: c.id,
        key: c.key,
        nameAr: 'صدقات',
        icon: c.icon,
        color: '#00ff00',
        isIncome: c.isIncome,
        sort: c.sort));
    await _push(db, queue, remote).push();
    expect(remote.rows['user_categories']![c.id]!['name_ar'], 'صدقات');

    await categories.deleteCategory(c.id);
    final res = await _push(db, queue, remote).push();
    expect(res.failed, 0);
    expect(remote.rows['user_categories']![c.id]!['deleted_at'], isNotNull);
  });

  test('multi-device: category created on A pulls into B', () async {
    final c = await categories.createCategory(
        nameAr: 'هوايات', icon: 'star', color: '#123456', isIncome: false);
    await _push(db, queue, remote).push();

    final dbB = await _openDb();
    addTearDown(() async => dbB.close());
    await _pull(dbB, remote).pull();

    final all = await DriftCategoryRepository(dbB).getAll();
    expect(all.where((x) => x.id == c.id), hasLength(1));
    expect(all.firstWhere((x) => x.id == c.id).nameAr, 'هوايات');
  });

  test('local pending category edit is not overwritten by pull', () async {
    final c = await categories.createCategory(
        nameAr: 'أ', icon: 'tag', color: '#111', isIncome: false);
    await _push(db, queue, remote).push();
    // Local edit → pending, not yet pushed.
    await categories.updateCategory(CategoryEntity(
        id: c.id,
        key: c.key,
        nameAr: 'محلي',
        icon: c.icon,
        color: c.color,
        isIncome: c.isIncome,
        sort: c.sort));
    // Server has an older value.
    remote.rows['user_categories']![c.id]!['name_ar'] = 'خادم';

    await _pull(db, remote).pull();

    final read = (await DriftCategoryRepository(db).getAll())
        .firstWhere((x) => x.id == c.id);
    expect(read.nameAr, 'محلي'); // local pending preserved
  });
}
