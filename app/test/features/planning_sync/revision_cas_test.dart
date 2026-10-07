import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_budget_repository.dart';
import 'package:money_companion/data/repositories/drift_bill_repository.dart';
import 'package:money_companion/data/repositories/drift_goal_repository.dart';
import 'package:money_companion/data/repositories/drift_plan_repository.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/entities/plan_entity.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/data/sync/server_capabilities.dart';
import 'package:money_companion/features/planning_sync/services/accounts_push_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';
import 'package:money_companion/features/planning_sync/services/planning_push_service.dart';
import '../../harness/fake_cas_server.dart';

// MALI-022 / WP-5 — revision compare-and-set contract tests. The CAS path runs
// through the sync_* RPCs when the server advertises `revision_cas` (false in
// production until G4); the legacy guarded path is unchanged otherwise.
// Covers legacy (capability false), CAS per family (applied / conflict / ack /
// not_found / epoch_mismatch / tombstone), durable conflicts and the accounts
// blind-overwrite fix.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

/// A planning sink with real revision semantics + call counters.
class _CasSink implements PlanningRemoteSink {
  _CasSink({this.serverRevision = 1});

  int serverRevision;
  // Matches the seeded base by default, so the guarded (OFF) path sees the
  // server as unchanged and proceeds to a normal update rather than a conflict.
  String serverUpdatedAt = 'base-ts';
  int guardedUpdateCalls = 0;

  @override
  Future<Map<String, dynamic>> upsert(String t, Map<String, dynamic> r) async =>
      {
        'id': 'srv-${r['local_id']}',
        'updated_at': serverUpdatedAt,
        'revision': serverRevision
      };

  @override
  Future<String?> fetchServerUpdatedAt(String t, String s) async =>
      serverUpdatedAt;

  @override
  Future<Map<String, dynamic>?> findByLocalId(
          String t, String u, String l) async =>
      null;

  @override
  Future<Map<String, dynamic>?> guardedTombstone(
          String t, String s, String? u) async =>
      {'id': s, 'updated_at': serverUpdatedAt};

  @override
  Future<Map<String, dynamic>?> fetchRowState(String t, String s) async => null;

  @override
  Future<Map<String, dynamic>> updateByServerId(
      String t, String s, Map<String, dynamic> r) async {
    guardedUpdateCalls++;
    serverUpdatedAt = 'guarded-ts';
    return {'id': s, 'updated_at': serverUpdatedAt, 'revision': serverRevision};
  }

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


}

GoalEntity _goal() => GoalEntity(
      id: 'g1',
      name: 'Travel',
      currency: 'SAR',
      targetMoney: Money.parse('5000', 'SAR'),
      savedMoney: Money.parse('300', 'SAR'),
      lastNotifiedSavedMoney: Money(0, 'SAR'),
      vaultSkin: 'classic',
      status: 'active',
      createdAt: DateTime.utc(2026, 7, 1),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late PlanningOutboxQueue queue;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    queue = PlanningOutboxQueue(
      db: db,
      isSyncEnabled: (_) => true,
      getAuthUserId: () async => 'user-1',
    );
  });
  tearDown(() => db.close());

  // Seeds a synced goal at [revision] (null = old row, revision unknown) and
  // enqueues an update, so the outbox payload carries the base revision.
  Future<void> seedAndEnqueue({int? revision}) async {
    await DriftGoalRepository(db, outboxQueue: queue).save(_goal());
    await db.customStatement('DELETE FROM planning_sync_outbox;');
    await db.customStatement(
      "UPDATE goals SET server_id = 'srv-g1', server_updated_at = 'base-ts', "
      "server_revision = ${revision ?? 'NULL'}, sync_status = 'synced' "
      "WHERE id = 'g1';",
    );
    final g = await DriftGoalRepository(db, outboxQueue: queue).getById('g1');
    await queue.enqueueGoal(PlanningSyncOperation.update, g!);
  }

  Future<String?> goalStatus() async => (await db
          .customSelect("SELECT sync_status FROM goals WHERE id='g1';")
          .getSingle())
      .readNullable<String>('sync_status');

  Future<int?> goalRevision() async => (await db
          .customSelect("SELECT server_revision FROM goals WHERE id='g1';")
          .getSingle())
      .readNullable<int>('server_revision');

  PlanningPushService push(_CasSink sink) => PlanningPushService(
        mayEgress: () async => true,
        db: db,
        queue: queue,
        isEnabled: (_) => true,
        getAuthUserId: () async => 'user-1',
        remoteSink: sink,
      );

  PlanningPushService casPush(FakeCasServer srv,
          {String epoch = 'e1',
          ServerCapabilityState cap = ServerCapabilityState.verified}) =>
      PlanningPushService(
        mayEgress: () async => true,
        db: db,
        queue: queue,
        isEnabled: (_) => true,
        getAuthUserId: () async => 'user-1',
        remoteSink: _CasSink(),
        casGate: casGate(db, epoch: epoch, capability: cap),
        casRemote: srv,
      );

  Future<int> openConflictCount() async => (await db
          .customSelect(
              'SELECT COUNT(*) AS n FROM sync_conflicts WHERE resolved_at IS NULL;')
          .getSingle())
      .read<int>('n');

  group('legacy (capability false) is unchanged', () {
    test('uses the guarded timestamp path, never the RPCs', () async {
      await seedAndEnqueue(revision: 5);
      final sink = _CasSink(serverRevision: 5);
      final r = await push(sink).push();
      expect(r.pushed, 1);
      expect(sink.guardedUpdateCalls, 1);
      expect(await goalStatus(), 'synced');
    });

    test('capability unsupported with a gate present: still legacy, RPCs '
        'untouched', () async {
      await seedAndEnqueue(revision: 5);
      final srv = FakeCasServer();
      final r = await casPush(srv, cap: ServerCapabilityState.unsupported).push();
      expect(r.failed + r.conflicts, 0);
      expect(srv.calls, isEmpty);
      expect(await goalStatus(), 'synced');
    });
  });

  group('planning CAS through the RPCs', () {
    test('goal update: applied, ack stores the new revision', () async {
      await seedAndEnqueue(revision: 5);
      final srv = FakeCasServer()
        ..seed('user_goals', {'local_id': 'g1'}, id: 'srv-g1', revision: 5);
      final r = await casPush(srv).push();
      expect(r.pushed, 1);
      expect(srv.calls, ['update:user_goals']);
      expect(await goalStatus(), 'synced');
      expect(await goalRevision(), 6);
    });

    test('goal update on a moved revision: durable conflict, no overwrite',
        () async {
      await seedAndEnqueue(revision: 5);
      final srv = FakeCasServer()
        ..seed('user_goals', {'local_id': 'g1', 'name': 'Other'},
            id: 'srv-g1', revision: 5)
        ..foreignEdit('user_goals', 'srv-g1', {'name': 'Theirs'});
      final r = await casPush(srv).push();
      expect(r.conflicts, 1);
      expect(srv.tables['user_goals']!['srv-g1']!['name'], 'Theirs');
      expect(await goalStatus(), 'conflict');
      expect(await openConflictCount(), 1);
      expect(await goalRevision(), 5);
    });

    test('lost ACK (crash after acceptance): the retry is an ACK', () async {
      await seedAndEnqueue(revision: 5);
      final srv = FakeCasServer()
        ..seed('user_goals', {'local_id': 'g1'}, id: 'srv-g1', revision: 5)
        ..loseNextAck = true;
      expect((await casPush(srv).push()).failed, 1);
      await db.customStatement('UPDATE planning_sync_outbox SET next_retry_at = NULL;');
      final r = await casPush(srv).push();
      expect(r.pushed, 1);
      expect(r.conflicts, 0);
      expect(srv.tables['user_goals']!['srv-g1']!['revision'], 6);
      expect(await goalStatus(), 'synced');
    });

    test('row gone in the cloud (not_found): re-created by identity', () async {
      await seedAndEnqueue(revision: 5);
      final srv = FakeCasServer();
      final r = await casPush(srv).push();
      expect(r.pushed, 1);
      expect(srv.calls, ['update:user_goals', 'insert:user_goals']);
    });

    test('stale epoch: the op stays queued, no attempt consumed', () async {
      await seedAndEnqueue(revision: 5);
      final srv = FakeCasServer(epoch: 'e2');
      final r = await casPush(srv).push();
      expect(r.pushed + r.failed + r.conflicts, 0);
      final row = await db
          .customSelect('SELECT status, attempt_count, in_flight_seq FROM planning_sync_outbox')
          .getSingle();
      expect(row.read<String>('status'), 'pending');
      expect(row.read<int>('attempt_count'), 0);
      expect(row.readNullable<int>('in_flight_seq'), isNull);
    });

    test('delete: CAS tombstone; a cloud row edited meanwhile is a conflict',
        () async {
      await seedAndEnqueue(revision: 5);
      await db.customStatement('DELETE FROM planning_sync_outbox;');
      final g = await DriftGoalRepository(db, outboxQueue: queue).getById('g1');
      await queue.enqueueGoal(PlanningSyncOperation.delete, g!);
      final srv = FakeCasServer()
        ..seed('user_goals', {'local_id': 'g1'}, id: 'srv-g1', revision: 5);
      expect((await casPush(srv).push()).pushed, 1);
      expect(srv.tables['user_goals']!['srv-g1']!['deleted_at'], isNotNull);

      await seedAndEnqueue(revision: 5);
      await db.customStatement('DELETE FROM planning_sync_outbox;');
      await queue.enqueueGoal(PlanningSyncOperation.delete, g);
      final srv2 = FakeCasServer()
        ..seed('user_goals', {'local_id': 'g1'}, id: 'srv-g1', revision: 5)
        ..foreignEdit('user_goals', 'srv-g1', {'name': 'Theirs'});
      final r = await casPush(srv2).push();
      expect(r.conflicts, 1);
      expect(srv2.tables['user_goals']!['srv-g1']!['deleted_at'], isNull);
    });

    test('remote tombstone vs local edit: conflict kind tombstone, never '
        'undeleted', () async {
      await seedAndEnqueue(revision: 5);
      final srv = FakeCasServer()
        ..seed('user_goals', {'local_id': 'g1'},
            id: 'srv-g1', revision: 5, deletedAt: '2026-08-01T00:00:00.000Z');
      final r = await casPush(srv).push();
      expect(r.conflicts, 1);
      expect(srv.tables['user_goals']!['srv-g1']!['deleted_at'], isNotNull);
      final kind = (await db
              .customSelect('SELECT kind FROM sync_conflicts')
              .getSingle())
          .read<String>('kind');
      expect(kind, 'tombstone');
    });

    test('creates for every family are insert-if-absent; an update on a moved '
        'revision conflicts per family', () async {
      final budgets = DriftBudgetRepository(db, outboxQueue: queue);
      final bills = DriftBillRepository(db, outboxQueue: queue);
      final plans = DriftPlanRepository(db, outboxQueue: queue);
      final goals = DriftGoalRepository(db, outboxQueue: queue);
      await budgets.save(BudgetEntity(
        id: 'b1',
        categoryId: BudgetEntity.allExpensesCategoryId,
        currency: 'SAR',
        amountMoney: Money.parse('500', 'SAR'),
        period: BudgetPeriod.monthly,
        startDate: DateTime.utc(2026, 7, 1),
        isActive: true,
        lastNotifiedSpentMoney: Money(0, 'SAR'),
        lastNotifiedPeriodStart: DateTime.utc(2000, 1, 1),
        showOnHeader: true,
      ));
      await bills.save(BillEntity(
        id: 's1',
        name: 'Netflix',
        amountMoney: Money.fromLegacyReal(39, 'SAR'),
        currency: 'SAR',
        type: BillType.subscription,
        frequency: BillFrequency.monthly,
        nextDueDate: DateTime.utc(2026, 7, 10),
        reminderOn: true,
        isConfirmed: true,
        createdAt: DateTime.utc(2026, 7, 1),
      ));
      await plans.save(PlanEntity(
        id: 'p1',
        name: 'Summer',
        budgetAmountMoney: Money.fromLegacyReal(2000, 'SAR'),
        currency: 'SAR',
        startDate: DateTime.utc(2026, 7, 1),
        endDate: DateTime.utc(2026, 7, 31),
        accountIds: const [],
        cardLast4s: const ['1234'],
        status: PlanStatus.active,
        createdAt: DateTime.utc(2026, 7, 1),
      ));
      await goals.save(_goal());
      final srv = FakeCasServer();
      final r = await casPush(srv).push();
      expect(r.pushed, 4);
      expect(srv.calls.every((c) => c.startsWith('insert:')), isTrue);
      for (final t in ['user_budgets', 'user_subscriptions', 'user_plans', 'user_goals']) {
        expect(srv.tables[t]!.length, 1, reason: t);
      }

      // Another device edits all four; this device edited the same ones.
      for (final t in ['user_budgets', 'user_subscriptions', 'user_plans', 'user_goals']) {
        final id = srv.tables[t]!.keys.single;
        srv.foreignEdit(t, id, {'x': 1});
      }
      await budgets.save((await budgets.getById('b1'))!
          .copyWith(amountMoney: Money.parse('900', 'SAR')));
      await bills.save((await bills.getById('s1'))!.copyWith(name: 'Netflix 2'));
      await plans.save((await plans.getById('p1'))!.copyWith(name: 'Summer 2'));
      await goals.save((await goals.getById('g1'))!.copyWith(name: 'Travel 2'));
      final r2 = await casPush(srv).push();
      expect(r2.conflicts, 4);
      expect(await openConflictCount(), 4);
    });
  });

  group('accounts fail-safe (blind-overwrite fix)', () {
    test(
        'OFF update of a synced account guards on updated_at instead of '
        'blindly upserting', () async {
      final repo = DriftAccountRepository(db, outboxQueue: queue);
      final now = DateTime.utc(2026, 7, 4, 12);
      await repo.create(AccountEntity(
        id: 'a1',
        name: 'Bank',
        currency: 'SAR',
        type: AccountType.bank,
        isDefault: false,
        sortOrder: 1,
        createdAt: now,
        updatedAt: now,
        initialBalanceMoney: Money.fromLegacyReal(100, 'SAR'),
        currentBalanceMoney: Money.fromLegacyReal(100, 'SAR'),
      ));
      // Mark it synced against a base the server has since moved past, then
      // enqueue an update (its payload captures the 'base-ts' base token).
      await db.customStatement('DELETE FROM planning_sync_outbox;');
      await db.customStatement(
        "UPDATE accounts SET server_id = 'srv-a1', server_updated_at = 'base-ts', "
        "sync_status = 'synced' WHERE id = 'a1';",
      );
      final a = await repo.getById('a1');
      await queue.enqueueAccount(PlanningSyncOperation.update, a!);

      // Server moved past our base — a blind upsert would clobber it; the
      // guarded path must flag a conflict instead.
      final sink = _CasAccountsSink(currentUpdatedAt: 'moved-ts');
      final r = await AccountsPushService(
        db: db,
        queue: queue,
        isEnabled: () => true,
        getAuthUserId: () async => 'user-1',
        remoteSink: sink,
      // C-3: these cover push MECHANICS; consent enforcement is asserted
      // separately in financial_push_consent_test.dart.
      mayEgress: () async => true,
    ).push();

      expect(r.conflicts, 1);
      expect(sink.upserts, 0,
          reason: 'an existing account must not be re-upserted');
      final status = (await db
              .customSelect("SELECT sync_status FROM accounts WHERE id='a1';")
              .getSingle())
          .readNullable<String>('sync_status');
      expect(status, 'conflict');
    });
  });
}

/// Accounts sink for the guarded-path fail-safe test.
class _CasAccountsSink implements AccountsRemoteSink {
  _CasAccountsSink({required this.currentUpdatedAt});
  final String currentUpdatedAt;
  int upserts = 0;

  @override
  Future<Map<String, dynamic>> upsertAccount(Map<String, dynamic> row) async {
    upserts++;
    return {'id': 'srv-${row['local_id']}', 'updated_at': currentUpdatedAt};
  }

  @override
  Future<Map<String, dynamic>?> findAccountByLocalId(
          String u, String id) async =>
      null;


  @override
  Future<Map<String, dynamic>?> guardedTombstoneAccount(
          String s, String? u) async =>
      {'id': s, 'updated_at': currentUpdatedAt};

  @override
  Future<Map<String, dynamic>?> fetchAccountState(String s) async => null;

  @override
  Future<String?> fetchAccountUpdatedAt(String s) async => currentUpdatedAt;

  @override
  Future<Map<String, dynamic>?> guardedUpdateAccount(
    String serverId,
    String expectedUpdatedAt,
    Map<String, dynamic> row,
  ) async {
    // C-6 — the fake must simulate the DATABASE predicate, not ignore it. The
    // point of the atomic guard is that a mismatched base matches ZERO rows;
    // a fake that always succeeds would make this test assert nothing.
    if (expectedUpdatedAt != currentUpdatedAt) return null;
    return updateAccountByServerId(serverId, row);
  }

    Future<Map<String, dynamic>> updateAccountByServerId(
          String s, Map<String, dynamic> r) async =>
      {'id': s, 'updated_at': currentUpdatedAt};


  @override
  Future<void> setDefaultAccount(String s) async {}
}
