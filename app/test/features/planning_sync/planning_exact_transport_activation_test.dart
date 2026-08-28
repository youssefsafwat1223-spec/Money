import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/planning_cutover.dart';
import 'package:money_companion/data/sync/exact_transport_capability.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/planning_sync/services/planning_child_sync_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';
import 'package:money_companion/features/planning_sync/services/planning_pull_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_push_service.dart';

// MALI-026 (B8-3 Step 5 §8/§11/§13) — when BOTH the planning-currency capability
// and the exact decimal transport are verified, the REAL production planning
// sync path is already exact: pushes emit decimal STRINGS + row currency, pulls
// parse ::text NUMERIC + row currency into exact `_minor` (+ a REAL shadow
// derived from Money), and a contribution queued while deferred replays exactly
// once when the capability opens. No display double / numeric fallback anywhere.

const _canonical =
    FixedPlanningCutoverCoordinator(PlanningCutoverState.canonical);
const _verified = ExactTransportCapability.verifiedExact;

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

class _CapturingSink implements PlanningRemoteSink {
  final upserts = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> upsert(
      String table, Map<String, dynamic> row) async {
    upserts.add(Map<String, dynamic>.from(row));
    return {'id': 'server-${row['local_id']}', 'updated_at': null};
  }

  @override
  Future<Map<String, dynamic>?> findByLocalId(
          String t, String u, String l) async =>
      null;
  @override
  Future<Map<String, dynamic>?> casTombstone(String t, String s, int r) async =>
      {'id': s, 'revision': r + 1};

  @override
  Future<Map<String, dynamic>?> guardedTombstone(
          String t, String s, String? u) async =>
      {'id': s};

  @override
  Future<Map<String, dynamic>?> fetchRowState(String t, String s) async => null;
  @override
  Future<String?> fetchServerUpdatedAt(String t, String s) async => null;
  @override
  Future<Map<String, dynamic>?> guardedUpdateByServerId(
    String table,
    String serverId,
    String expectedUpdatedAt,
    Map<String, dynamic> row,
  ) async {
    // C-6: no concurrent writer modelled; rejection is covered in
    // planning_guarded_update_atomicity_test.dart.
    return updateByServerId(table, serverId, row);
  }

  @override
  Future<Map<String, dynamic>> updateByServerId(
          String t, String s, Map<String, dynamic> r) async =>
      {'id': s, 'updated_at': null};
  @override
  Future<Map<String, dynamic>?> casUpdateByServerId(
          String t, String s, int e, Map<String, dynamic> r) async =>
      null;
}

class _BudgetPullRemote implements PlanningRemoteSource {
  _BudgetPullRemote(this.row);
  final Map<String, dynamic> row;
  @override
  Future<List<Map<String, dynamic>>> fetchRows(String table,
      {required SyncCursor after, int limit = 200}) async {
    if (table != 'user_budgets' || after.id.isNotEmpty) return const [];
    return [row];
  }
}

/// Counts add_goal_contribution RPCs so we can prove exactly-once replay.
class _CountingChildRemote implements PlanningChildRemote {
  int contributionRpcs = 0;
  @override
  Future<Map<String, dynamic>> callRpc(
      String name, Map<String, dynamic> params) async {
    if (name != 'add_goal_contribution') throw UnsupportedError(name);
    contributionRpcs++;
    return {
      'contribution': {
        'id': 'server-gc-${params['p_local_id']}',
        'local_id': params['p_local_id'],
        'goal_id': params['p_goal_id'],
        'updated_at': '2026-08-12T00:00:00.000Z',
        'deleted_at': null,
      },
      'goal': {
        'id': params['p_goal_id'],
        'currency': 'EGP',
        'saved_amount_text': '12.34',
        'updated_at': '2026-08-12T00:00:00.000Z',
      },
    };
  }

  @override
  Future<List<Map<String, dynamic>>> fetchRows(String table,
          {required SyncCursor after, int limit = 200}) async =>
      const [];
  @override
  Future<Map<String, dynamic>> upsertPlanLink(Map<String, dynamic> r) async =>
      throw UnimplementedError();
  @override
  Future<Map<String, dynamic>?> findPlanLink(
          {required String userId,
          required String planId,
          required String transactionId}) async =>
      null;
  @override
  Future<void> tombstonePlanLink(String serverId) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  setUp(() async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    // The §8 exact-money cases below use `categoryId: 'c1'` as a placeholder.
    // Since F-029 fails CLOSED on an unresolvable category, that category has to
    // actually exist or those tests would be asserting the refusal path instead
    // of the transport path they are written to cover.
    await db.customStatement('''
      INSERT INTO categories(id, key, name_ar, icon, color, is_income, sort_order)
      VALUES('c1', 'c1_key', 'فئة', 'tag', '#000', 0, 98);
    ''');
  });
  tearDown(() async => db.close());

  PlanningOutboxQueue canonicalQueue() => PlanningOutboxQueue(
        db: db,
        isSyncEnabled: (_) => true,
        getAuthUserId: () async => 'user-1',
        coordinator: _canonical,
      );

  Future<Map<String, dynamic>> payload(String entityType) async {
    final r = await db
        .customSelect("SELECT payload_json FROM planning_sync_outbox "
            "WHERE entity_type = '$entityType' LIMIT 1;")
        .getSingle();
    return (jsonDecode(r.read<String>('payload_json')) as Map).cast();
  }

  BudgetEntity budget() => BudgetEntity(
        id: 'b1',
        categoryId: 'c1',
        currency: 'EGP',
        amountMoney: Money.parse('12.34', 'EGP'),
        lastNotifiedSpentMoney: Money.parse('1.00', 'EGP'),
        period: BudgetPeriod.monthly,
        startDate: DateTime.utc(2026, 8, 1),
        isActive: true,
        lastNotifiedPeriodStart: DateTime.utc(2026, 8, 1),
      );

  GoalEntity goal() => GoalEntity(
        id: 'g1',
        name: 'Trip',
        currency: 'KWD', // 3-decimal
        targetMoney: Money.parse('1.005', 'KWD'),
        savedMoney: Money.parse('0.250', 'KWD'),
        lastNotifiedSavedMoney: Money(0, 'KWD'),
        vaultSkin: 'classic',
        status: 'active',
        createdAt: DateTime.utc(2026, 8, 1),
      );

  // ── §8: canonical PUSH builders emit exact decimal strings + currency ──────

  test('§8 canonical budget enqueue → exact string amounts + currency',
      () async {
    final q = canonicalQueue();
    await q.enqueueBudget(PlanningSyncOperation.create, budget());
    final p = await payload('budget');
    expect(p['amount'], '12.34');
    expect(p['last_notified_spent_amount'], '1.00');
    expect(p['currency'], 'EGP');
  });

  // ── F-029 — server category_id must carry the stable KEY, not a local id ──
  // QA evidence (demo stack, PUSH-03, 2026-08-27): the delivered payload
  // overwrote the server's 'groceries' key with an opaque per-device Drift id;
  // any other device's pull would fail the key lookup and silently
  // re-categorise the budget to `other`.

  test('F-029: budget payload maps the local category id to its stable key',
      () async {
    // A category whose per-device local id visibly differs from its key.
    await db.customStatement('''
      INSERT INTO categories(id, key, name_ar, icon, color, is_income, sort_order)
      VALUES('cat-local-123', 'groceries_wire_test', 'بقالة', 'cart', '#fff', 0, 99);
    ''');
    final q = canonicalQueue();
    await q.enqueueBudget(
      PlanningSyncOperation.create,
      BudgetEntity(
        id: 'b-f029',
        categoryId: 'cat-local-123', // local id ≠ key
        currency: 'SAR',
        amountMoney: Money.parse('2500.00', 'SAR'),
        lastNotifiedSpentMoney: Money(0, 'SAR'),
        period: BudgetPeriod.monthly,
        startDate: DateTime.utc(2026, 8, 1),
        isActive: true,
        lastNotifiedPeriodStart: DateTime.utc(2026, 8, 1),
      ),
    );
    final p = await payload('budget');
    expect(p['category_id'], 'groceries_wire_test',
        reason: 'the wire value must be the stable key the pull resolves — '
            'never the per-device local id');
    expect(p['local_id'], 'b-f029');
  });

  test(
      'F-029: an unresolvable category FAILS CLOSED — nothing is queued, and '
      'the local id never reaches the wire', () async {
    // Independent review (QIRSH_MASTER_PLAN_V2.md §3, F-029) flagged that the
    // id→key lookup failed OPEN: when the category row could not be resolved it
    // transmitted the known-invalid local id anyway. That is the exact value
    // whose arrival on the server silently re-categorises the budget to `other`
    // on every other device — i.e. the fallback re-created the bug the fix
    // exists to prevent, in the one case where we KNOW the value is wrong.
    //
    // Correct behaviour: refuse to enqueue. The budget stays local (recoverable,
    // still visible to its owner) rather than corrupting a row other devices read.
    final q = canonicalQueue();
    final queued = await q.enqueueBudget(
      PlanningSyncOperation.create,
      BudgetEntity(
        id: 'b-dangling',
        categoryId: 'cat-does-not-exist',
        currency: 'SAR',
        amountMoney: Money.parse('50.00', 'SAR'),
        lastNotifiedSpentMoney: Money(0, 'SAR'),
        period: BudgetPeriod.monthly,
        startDate: DateTime.utc(2026, 8, 1),
        isActive: true,
        lastNotifiedPeriodStart: DateTime.utc(2026, 8, 1),
      ),
    );

    expect(queued, isFalse,
        reason: 'an unresolvable category must not produce a wire payload');
    final rows = await db
        .customSelect(
          "SELECT COUNT(*) AS c FROM planning_sync_outbox "
          "WHERE entity_id = 'b-dangling';",
        )
        .getSingle();
    expect(rows.read<int>('c'), 0,
        reason: 'nothing may be queued for an unresolvable category');
  });

  test('F-029: the all-expenses sentinel travels as its key form', () async {
    final q = canonicalQueue();
    await q.enqueueBudget(
      PlanningSyncOperation.create,
      BudgetEntity(
        id: 'b-all',
        categoryId: BudgetEntity.allExpensesCategoryId,
        currency: 'SAR',
        amountMoney: Money.parse('100.00', 'SAR'),
        lastNotifiedSpentMoney: Money(0, 'SAR'),
        period: BudgetPeriod.monthly,
        startDate: DateTime.utc(2026, 8, 1),
        isActive: true,
        lastNotifiedPeriodStart: DateTime.utc(2026, 8, 1),
      ),
    );
    final p = await payload('budget');
    expect(p['category_id'], BudgetEntity.allExpensesCategoryKey);
  });

  test('§8 canonical goal enqueue → exact string amounts + currency', () async {
    final q = canonicalQueue();
    await q.enqueueGoal(PlanningSyncOperation.create, goal());
    final p = await payload('goal');
    expect(p['target_amount'], '1.005');
    expect(p['saved_amount'], '0.250');
    expect(p['currency'], 'KWD');
  });

  test('§8 both caps verified → budget push sends the exact string + currency',
      () async {
    final q = canonicalQueue();
    await q.enqueueBudget(PlanningSyncOperation.create, budget());
    final sink = _CapturingSink();
    final result = await PlanningPushService(
      db: db,
      queue: q,
      isEnabled: (_) => true,
      getAuthUserId: () async => 'user-1',
      remoteSink: sink,
      coordinator: _canonical,
      pushCapability: () => _verified,
      planningCurrencyCapability: () => _verified,
    ).push();

    expect(result.parked, 0);
    expect(result.pushed, 1);
    final sent = sink.upserts.single;
    expect(sent['amount'], '12.34');
    expect(sent['currency'], 'EGP');
    // No lossy numeric leaked into the wire row.
    expect(sent['amount'], isA<String>());
  });

  // ── §11: exact PULL activation writes _minor + REAL shadow, no double ──────

  test('§11 exact budget pull → currency + exact _minor + REAL shadow',
      () async {
    final remote = _BudgetPullRemote({
      'id': 'server-b1',
      'local_id': 'b1',
      'category_id': BudgetEntity.allExpensesCategoryKey,
      'currency': 'EGP',
      'amount_text': '12.34',
      'last_notified_spent_amount_text': '0',
      'period': 'monthly',
      'start_date': '2026-08-01T00:00:00Z',
      'is_active': true,
      'last_notified_period_start': '2000-01-01T00:00:00Z',
      'show_on_header': false,
      'updated_at': '2026-08-02T00:00:00Z',
      'deleted_at': null,
    });

    final result = await PlanningPullService(
      db: db,
      isEnabled: (e) => e == PlanningOutboxQueue.budgetsEntityType,
      getAuthUserId: () async => 'user-1',
      remoteSource: remote,
    
    // C-3: covers pull MECHANICS; consent is asserted in
    // financial_pull_consent_test.dart.
    mayEgress: () async => true,
  ).pull();

    expect(result.imported, 1);
    final r = await db
        .customSelect("SELECT currency, amount, amount_minor AS m "
            "FROM budgets WHERE id='b1';")
        .getSingle();
    expect(r.read<String>('currency'), 'EGP');
    expect(r.read<int>('m'), 1234); // exact minor from ::text
    expect(r.read<double>('amount'), 12.34); // REAL shadow derived from Money
  });

  test('§11 exact budget pull FAILS CLOSED on a numeric (cast not applied)',
      () async {
    final remote = _BudgetPullRemote({
      'id': 'server-b1',
      'local_id': 'b1',
      'category_id': BudgetEntity.allExpensesCategoryKey,
      'currency': 'EGP',
      'amount_text': 12.34, // a JSON number, not ::text → must fail closed
      'last_notified_spent_amount_text': '0',
      'period': 'monthly',
      'start_date': '2026-08-01T00:00:00Z',
      'is_active': true,
      'updated_at': '2026-08-02T00:00:00Z',
      'deleted_at': null,
    });

    final result = await PlanningPullService(
      db: db,
      isEnabled: (e) => e == PlanningOutboxQueue.budgetsEntityType,
      getAuthUserId: () async => 'user-1',
      remoteSource: remote,
    
    // C-3: covers pull MECHANICS; consent is asserted in
    // financial_pull_consent_test.dart.
    mayEgress: () async => true,
  ).pull();

    // The page errored → nothing imported, no lossy row written.
    expect(result.imported, 0);
    expect(
        await db
            .customSelect('SELECT COUNT(*) AS n FROM budgets;')
            .getSingle()
            .then((r) => r.read<int>('n')),
        0);
  });

  // ── §13: contribution queued while deferred replays EXACTLY ONCE ───────────

  test('§13 contribution deferred while capability unknown, then sends once',
      () async {
    // Canonical goal already synced (server_id + currency).
    await db.customStatement(
      "INSERT INTO goals(id,name,currency,target_amount,target_amount_minor,"
      "saved_amount,saved_amount_minor,last_notified_saved_amount,"
      "last_notified_saved_amount_minor,vault_skin,status,created_at,server_id,"
      "sync_status) VALUES ('g1','هدف','EGP',100,10000,0,0,0,0,'classic',"
      "'active','2026-08-01T00:00:00Z','server-goal-1','synced');",
    );
    final q = canonicalQueue();
    await q.enqueueGoalContribution(
      PlanningSyncOperation.create,
      GoalContributionEntity(
        id: 'gc1',
        goalId: 'g1',
        amountMoney: Money.parse('12.34', 'EGP'),
        createdAt: DateTime.utc(2026, 8, 2),
      ),
    );
    // Payload is exact (string) even though it stays parked/pending.
    expect((await payload('goal_contribution'))['amount'], '12.34');

    final remote = _CountingChildRemote();
    PlanningChildSyncService child(bool Function(String) isEnabled) =>
        PlanningChildSyncService(
          db: db,
          queue: q,
          isEnabled: isEnabled,
          getAuthUserId: () async => 'user-1',
          remote: remote,
          coordinator: _canonical,
        );

    // Capability UNKNOWN → contribution deferred (gate closed), no RPC, durable.
    await child((_) => false).sync();
    expect(remote.contributionRpcs, 0);
    expect(
      await db
          .customSelect("SELECT COUNT(*) AS n FROM planning_sync_outbox "
              "WHERE entity_type='goal_contribution';")
          .getSingle()
          .then((r) => r.read<int>('n')),
      1,
      reason: 'still durably queued',
    );

    // Capability opens → drains EXACTLY once; a second pass does not resend.
    await child((_) => true).sync();
    await child((_) => true).sync();
    expect(remote.contributionRpcs, 1);
    // Parent goal saved amount applied exactly (minor authority).
    final g = await db
        .customSelect(
            "SELECT saved_amount_minor AS m FROM goals WHERE id='g1';")
        .getSingle();
    expect(g.read<int>('m'), 1234);
  });
}
