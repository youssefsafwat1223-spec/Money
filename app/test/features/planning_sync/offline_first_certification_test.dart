// S4 certification: cross-cutting offline-first guarantees exercised through the
// shared outbox + planning push, using budgets as a representative entity.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_budget_repository.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';
import 'package:money_companion/features/planning_sync/services/planning_push_service.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

class _FakeRemote implements PlanningRemoteSink {
  final rows = <String, Map<String, Map<String, dynamic>>>{};
  int upserts = 0;
  int failNext = 0; // fail this many upserts (transient), then succeed

  @override
  Future<Map<String, dynamic>?> findByLocalId(
          String table, String userId, String localId) async =>
      rows[table]?[localId];

  Future<void> _tombstone(String table, String serverId) async {
    final m = rows[table]?.values.firstWhere((r) => r['id'] == serverId,
        orElse: () => <String, dynamic>{});
    if (m != null && m.isNotEmpty) m['deleted_at'] = 'x';
  }

  @override
  Future<Map<String, dynamic>?> casTombstone(
      String table, String serverId, int expectedRevision) async {
    await _tombstone(table, serverId);
    return {'id': serverId, 'revision': expectedRevision + 1};
  }

  @override
  Future<Map<String, dynamic>?> guardedTombstone(
      String table, String serverId, String? expectedUpdatedAt) async {
    await _tombstone(table, serverId);
    return {'id': serverId};
  }

  @override
  Future<Map<String, dynamic>?> fetchRowState(
          String table, String serverId) async =>
      null;

  @override
  Future<Map<String, dynamic>> upsert(
      String table, Map<String, dynamic> row) async {
    if (failNext > 0) {
      failNext--;
      throw Exception('transient network error');
    }
    upserts++;
    final localId = row['local_id'] as String;
    final saved = {
      ...row,
      'id': rows[table]?[localId]?['id'] ?? 'server-$localId',
      'updated_at': '2026-07-05T00:00:00.000Z',
      'deleted_at': null,
    };
    rows.putIfAbsent(table, () => {})[localId] = saved;
    return {'id': saved['id'], 'updated_at': '2026-07-05T00:00:00.000Z'};
  }

  @override
  Future<String?> fetchServerUpdatedAt(String table, String serverId) async {
    for (final r in rows[table]?.values ?? const <Map<String, dynamic>>[]) {
      if (r['id'] == serverId) return r['updated_at'] as String?;
    }
    return null;
  }

  @override
  Future<Map<String, dynamic>> updateByServerId(
          String table, String serverId, Map<String, dynamic> row) =>
      upsert(table, row);

  @override
  Future<Map<String, dynamic>?> guardedUpdateByServerId(
    String table,
    String serverId,
    String expectedUpdatedAt,
    Map<String, dynamic> row,
  ) async {
    // C-6: this fake models no concurrent writer, so the guarded and plain
    // updates are equivalent here. Guard REJECTION is modelled properly in
    // planning_guarded_update_atomicity_test.dart — delegating there instead
    // would make the rejection case pass for the wrong reason.
    return updateByServerId(table, serverId, row);
  }


  @override
  Future<Map<String, dynamic>?> casUpdateByServerId(String table,
          String serverId, int expectedRevision, Map<String, dynamic> row) =>
      throw UnimplementedError('CAS is exercised by the dedicated CAS test');
}

Future<AppDatabase> _openDb() => AppDatabase.open(
    executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());

PlanningOutboxQueue _queue(
  AppDatabase db, {
  void Function()? onQueued,
}) =>
    PlanningOutboxQueue(
      db: db,
      isSyncEnabled: (_) => true,
      getAuthUserId: () async => 'user-1',
      onQueued: onQueued,
    );

PlanningPushService _push(
        AppDatabase db, PlanningOutboxQueue q, _FakeRemote r) =>
    PlanningPushService(
        db: db,
        queue: q,
        isEnabled: (_) => true,
        getAuthUserId: () async => 'user-1',
        remoteSink: r);

BudgetEntity _budget(String id, {double amount = 500}) => BudgetEntity(
      id: id,
      categoryId: BudgetEntity.allExpensesCategoryId,
      currency: 'SAR',
      amountMoney: Money.fromLegacyReal(amount, 'SAR'),
      period: BudgetPeriod.monthly,
      startDate: DateTime.utc(2026, 7, 1),
      isActive: true,
      lastNotifiedSpentMoney: Money(0, 'SAR'),
      lastNotifiedPeriodStart: DateTime.utc(2000),
      showOnHeader: true,
    );

Future<int> _outboxCount(AppDatabase db) async => (await db
        .customSelect('SELECT COUNT(*) AS c FROM planning_sync_outbox;')
        .getSingle())
    .read<int>('c');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late _FakeRemote remote;
  late PlanningOutboxQueue queue;
  late DriftBudgetRepository budgets;

  setUp(() async {
    db = await _openDb();
    remote = _FakeRemote();
    queue = _queue(db);
    budgets = DriftBudgetRepository(db, outboxQueue: queue);
  });
  tearDown(() async => db.close());

  test('offline write persists locally and queues (no network needed)',
      () async {
    await budgets.save(_budget('b1'));
    // Local row exists and an outbox item is queued — no push yet.
    expect(await budgets.getAll(), isNotEmpty);
    expect(await _outboxCount(db), 1);
    expect(remote.upserts, 0);
  });

  test('successful planning enqueue wakes the background sync worker',
      () async {
    var wakeups = 0;
    final wakingQueue = _queue(db, onQueued: () => wakeups++);
    final wakingBudgets = DriftBudgetRepository(db, outboxQueue: wakingQueue);

    await wakingBudgets.save(_budget('wake-budget'));

    expect(wakeups, 1);
    expect(await _outboxCount(db), 1);
  });

  test('multiple pending operations all drain on one push', () async {
    await budgets.save(_budget('b1'));
    await budgets.save(_budget('b2'));
    await budgets.save(_budget('b3'));
    expect(await _outboxCount(db), greaterThanOrEqualTo(3));

    final res = await _push(db, queue, remote).push();
    expect(res.failed, 0);
    expect(await _outboxCount(db), 0);
    expect(remote.rows['user_budgets']!.length, 3);
  });

  test('idempotency: re-pushing does not duplicate or error', () async {
    await budgets.save(_budget('b1'));
    await _push(db, queue, remote).push();
    // Edit again + push, and a redundant push with an empty queue.
    await budgets.save(_budget('b1', amount: 900));
    await _push(db, queue, remote).push();
    await _push(db, queue, remote).push(); // empty queue — no-op

    expect(remote.rows['user_budgets']!.length, 1); // still one server row
    expect(remote.rows['user_budgets']!['b1']!['amount'], 900);
  });

  test('app restart during pending: outbox survives and drains later',
      () async {
    await budgets.save(_budget('b1')); // queued, not pushed ("app killed")
    expect(await _outboxCount(db), 1);

    // Simulate a fresh app launch: brand-new queue + push service, SAME db.
    final queue2 = _queue(db);
    final res = await _push(db, queue2, remote).push();
    expect(res.pushed, greaterThanOrEqualTo(1));
    expect(await _outboxCount(db), 0);
    expect(remote.rows['user_budgets']!['b1'], isNotNull);
  });

  test('transient failure keeps item queued, then succeeds on retry', () async {
    await budgets.save(_budget('b1'));
    remote.failNext = 1; // first push attempt fails

    final r1 = await _push(db, queue, remote).push();
    expect(r1.failed, 1);
    expect(await _outboxCount(db), 1); // still queued for retry

    // next_retry_at is in the future after a failure; clear it to simulate the
    // backoff window elapsing, then the retry succeeds.
    await db.customStatement(
        'UPDATE planning_sync_outbox SET next_retry_at = NULL;');
    final r2 = await _push(db, queue, remote).push();
    expect(r2.pushed, 1);
    expect(await _outboxCount(db), 0);
  });

  test('offline delete is queued and tombstones on reconnect', () async {
    await budgets.save(_budget('b1'));
    await _push(db, queue, remote).push();
    await budgets.delete('b1'); // offline delete → queued
    final res = await _push(db, queue, remote).push();
    expect(res.failed, 0);
    expect(remote.rows['user_budgets']!['b1']!['deleted_at'], isNotNull);
  });
}
