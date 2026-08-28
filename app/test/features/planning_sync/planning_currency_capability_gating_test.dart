import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/planning_cutover.dart';
import 'package:money_companion/data/sync/exact_transport_capability.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';
import 'package:money_companion/features/planning_sync/services/planning_pull_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_push_service.dart';

// MALI-026 (B8-3 Step 4 §29/§30) — planning MONEY entities
// (budgets/goals/goal_contributions) only cloud-sync in a direction when the
// SERVER per-row planning-currency capability (0077) AND that direction's exact
// decimal transport are BOTH verified. 0077 is undeployed, so both are UNKNOWN
// and planning cloud sync stays fully deferred: pushes park, pulls skip. The gate
// is NEVER inferred from the local schema version or local canonical (P3) state,
// and it never touches non-planning entities.

const _budget = PlanningOutboxQueue.budgetsEntityType; // 'budget'
const _goal = PlanningOutboxQueue.goalsEntityType; // 'goal'
const _contribution = PlanningOutboxQueue.goalContributionsEntityType;

const _unknown = ExactTransportCapability.unknown;
const _verified = ExactTransportCapability.verifiedExact;
const _unsupported = ExactTransportCapability.unsupported;

const _canonical =
    FixedPlanningCutoverCoordinator(PlanningCutoverState.canonical);

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

/// Records every table push()ed to it. Throws if a supposedly-parked write ever
/// reaches the network.
class _RecordingSink implements PlanningRemoteSink {
  _RecordingSink({this.failIfCalled = false});
  final bool failIfCalled;
  final sentTables = <String>[];

  void _guard() {
    if (failIfCalled) {
      throw StateError('network must not be called while parked');
    }
  }

  @override
  Future<Map<String, dynamic>> upsert(
      String table, Map<String, dynamic> row) async {
    _guard();
    sentTables.add(table);
    return {'id': 'server-${row['local_id']}', 'updated_at': null};
  }

  @override
  Future<Map<String, dynamic>?> findByLocalId(
          String table, String userId, String localId) async =>
      null;

  @override
  Future<Map<String, dynamic>?> casTombstone(
      String table, String serverId, int expectedRevision) async {
    _guard();
    return {'id': serverId, 'revision': expectedRevision + 1};
  }

  @override
  Future<Map<String, dynamic>?> guardedTombstone(
      String table, String serverId, String? expectedUpdatedAt) async {
    _guard();
    return {'id': serverId};
  }

  @override
  Future<Map<String, dynamic>?> fetchRowState(
      String table, String serverId) async {
    _guard();
    return null;
  }

  @override
  Future<String?> fetchServerUpdatedAt(String table, String serverId) async {
    _guard();
    return null;
  }

  @override
  Future<Map<String, dynamic>> updateByServerId(
      String table, String serverId, Map<String, dynamic> row) async {
    _guard();
    sentTables.add(table);
    return {'id': serverId, 'updated_at': null};
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


  @override
  Future<Map<String, dynamic>?> casUpdateByServerId(
          String table,
          String serverId,
          int expectedRevision,
          Map<String, dynamic> row) async =>
      null;
}

/// Records which tables a pull fetched from; always returns an empty page.
class _RecordingRemoteSource implements PlanningRemoteSource {
  final fetchedTables = <String>[];

  @override
  Future<List<Map<String, dynamic>>> fetchRows(String table,
      {required SyncCursor after, int limit = 200}) async {
    fetchedTables.add(table);
    return const [];
  }
}

BudgetEntity _budgetEntity() => BudgetEntity(
      id: 'budget-001',
      categoryId: 'cat-001',
      currency: 'SAR',
      amountMoney: Money.parse('50.00', 'SAR'),
      lastNotifiedSpentMoney: Money(0, 'SAR'),
      period: BudgetPeriod.monthly,
      startDate: DateTime.utc(2026, 8, 1),
      isActive: true,
      lastNotifiedPeriodStart: DateTime.utc(2026, 8, 1),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ── Unit: the authoritative capability combinators ────────────────────────

  group('weakerCapability', () {
    test('verifiedExact ONLY when both are verified', () {
      expect(weakerCapability(_verified, _verified), _verified);
      expect(weakerCapability(_verified, _unknown), _unknown);
      expect(weakerCapability(_unknown, _verified), _unknown);
      expect(weakerCapability(_unknown, _unknown), _unknown);
    });

    test('unsupported dominates', () {
      expect(weakerCapability(_unsupported, _verified), _unsupported);
      expect(weakerCapability(_verified, _unsupported), _unsupported);
      expect(weakerCapability(_unsupported, _unknown), _unsupported);
    });
  });

  group('planningMoneyEntitySyncEnabled', () {
    // Scenario 6 — a non-planning-gated entity is NEVER blocked by this gate,
    // regardless of the (irrelevant) planning capabilities.
    test('non-gated entity is always enabled', () {
      expect(
        planningMoneyEntitySyncEnabled(
          isPlanningCurrencyGatedEntity: false,
          planningCurrencyCapability: _unknown,
          transportCapability: _unknown,
        ),
        isTrue,
      );
    });

    // Scenario 2 — P3 local + server incapable: both unknown → deferred.
    test('gated entity: both unknown → disabled', () {
      expect(
        planningMoneyEntitySyncEnabled(
          isPlanningCurrencyGatedEntity: true,
          planningCurrencyCapability: _unknown,
          transportCapability: _unknown,
        ),
        isFalse,
      );
    });

    // Both are required — one alone never enables (also scenario 7: being
    // canonical/P3 is irrelevant here; only the explicit capabilities matter).
    test('gated entity: only one verified → still disabled', () {
      expect(
        planningMoneyEntitySyncEnabled(
          isPlanningCurrencyGatedEntity: true,
          planningCurrencyCapability: _verified,
          transportCapability: _unknown,
        ),
        isFalse,
      );
      expect(
        planningMoneyEntitySyncEnabled(
          isPlanningCurrencyGatedEntity: true,
          planningCurrencyCapability: _unknown,
          transportCapability: _verified,
        ),
        isFalse,
      );
    });

    // Scenario 3 — P3 local + server capable: both verified → enabled.
    test('gated entity: both verified → enabled', () {
      expect(
        planningMoneyEntitySyncEnabled(
          isPlanningCurrencyGatedEntity: true,
          planningCurrencyCapability: _verified,
          transportCapability: _verified,
        ),
        isTrue,
      );
    });

    test('gated entity: unsupported → disabled', () {
      expect(
        planningMoneyEntitySyncEnabled(
          isPlanningCurrencyGatedEntity: true,
          planningCurrencyCapability: _unsupported,
          transportCapability: _verified,
        ),
        isFalse,
      );
    });

    test('the default providers are all UNKNOWN (deferred today)', () {
      // Guards the truthful default: nothing is inferred as verified.
      expect(_unknown, isNot(_verified));
    });
  });

  // ── Behavioural: canonical planning PUSH parks until BOTH verified ─────────

  group('canonical budget push', () {
    late AppDatabase db;

    setUp(() async {
      db = await AppDatabase.open(
        executor: NativeDatabase.memory(),
        keyStore: _MemoryKeyStore(),
      );
      // These cases assert PARKING behaviour and use 'cat-001' as a placeholder
      // category. Since F-029 fails closed on an unresolvable category, the row
      // must exist — otherwise the budget is never queued and the test would be
      // asserting the refusal path instead of the capability gate it covers.
      await db.customStatement(
        "INSERT INTO categories(id, key, name_ar, icon, color, is_income, "
        "sort_order) VALUES('cat-001', 'cat_001_key', 'فئة', 'tag', '#000', 0, 97);",
      );
    });
    tearDown(() async => db.close());

    PlanningOutboxQueue queue() => PlanningOutboxQueue(
          db: db,
          isSyncEnabled: (_) => true,
          getAuthUserId: () async => 'user-1',
          coordinator: _canonical,
        );

    PlanningPushService pushService({
      required PlanningOutboxQueue q,
      required PlanningCutoverCoordinator coordinator,
      required ExactTransportCapability planningCurrency,
      required ExactTransportCapability pushTransport,
      required PlanningRemoteSink sink,
    }) =>
        PlanningPushService(
          db: db,
          queue: q,
          isEnabled: (_) => true,
          getAuthUserId: () async => 'user-1',
          remoteSink: sink,
          coordinator: coordinator,
          pushCapability: () => pushTransport,
          planningCurrencyCapability: () => planningCurrency,
        );

    // Scenario 5 — push parked before capability (currency unknown parks even
    // though the exact transport happens to be verified).
    test('§30 currency UNKNOWN parks (transport verified is not enough)',
        () async {
      final q = queue();
      await q.enqueueBudget(PlanningSyncOperation.create, _budgetEntity());
      final sink = _RecordingSink(failIfCalled: true);

      final r = await pushService(
        q: q,
        coordinator: _canonical,
        planningCurrency: _unknown,
        pushTransport: _verified,
        sink: sink,
      ).push();

      expect(r.parked, 1);
      expect(r.pushed, 0);
      expect(sink.sentTables, isEmpty);
      expect(await q.parkedCount(), 1);
      final row = await db
          .customSelect(
            "SELECT status, failure_class FROM planning_sync_outbox "
            "WHERE entity_id = 'budget-001';",
          )
          .getSingle();
      expect(row.read<String>('status'), 'parked');
      expect(row.read<String>('failure_class'),
          exactMoneyTransportUnverifiedReason);
    });

    // Both required — transport unknown parks even with currency verified.
    test('§30 transport UNKNOWN parks (currency verified is not enough)',
        () async {
      final q = queue();
      await q.enqueueBudget(PlanningSyncOperation.create, _budgetEntity());
      final sink = _RecordingSink(failIfCalled: true);

      final r = await pushService(
        q: q,
        coordinator: _canonical,
        planningCurrency: _verified,
        pushTransport: _unknown,
        sink: sink,
      ).push();

      expect(r.parked, 1);
      expect(sink.sentTables, isEmpty);
    });

    // Scenario 3 — P3 local + server capable (BOTH verified) → NOT parked.
    test('§30 both verified → sends (not parked)', () async {
      final q = queue();
      await q.enqueueBudget(PlanningSyncOperation.create, _budgetEntity());
      final sink = _RecordingSink();

      final r = await pushService(
        q: q,
        coordinator: _canonical,
        planningCurrency: _verified,
        pushTransport: _verified,
        sink: sink,
      ).push();

      expect(r.parked, 0);
      expect(r.pushed, 1);
      expect(sink.sentTables, ['user_budgets']);
    });

    // Scenario 7 — a coordinator that INDEPENDENTLY recomputes canonical (P3)
    // from the live v30 DB does NOT activate planning cloud sync: the capability
    // is separate and still unknown, so the canonical budget still parks.
    test('§30 recomputed-canonical coordinator still parks (no P3 inference)',
        () async {
      final coordinator = DbBackedPlanningCutoverCoordinator(
        initialState: PlanningCutoverState.unresolved,
        readUserVersion: () async => 30,
        readMarker: () async => 1,
        countCanonicalViolations: () async => 0,
      );
      final recomputed = await coordinator.refreshFromDatabase();
      expect(recomputed, PlanningCutoverState.canonical);

      final q = PlanningOutboxQueue(
        db: db,
        isSyncEnabled: (_) => true,
        getAuthUserId: () async => 'user-1',
        coordinator: coordinator,
      );
      await q.enqueueBudget(PlanningSyncOperation.create, _budgetEntity());
      final sink = _RecordingSink(failIfCalled: true);

      final r = await pushService(
        q: q,
        coordinator: coordinator,
        planningCurrency: _unknown,
        pushTransport: _unknown,
        sink: sink,
      ).push();

      expect(r.parked, 1);
      expect(sink.sentTables, isEmpty);
    });
  });

  // ── Behavioural: planning PULL skips gated entities (no lossy application) ──

  group('planning pull gating', () {
    late AppDatabase db;

    setUp(() async {
      db = await AppDatabase.open(
        executor: NativeDatabase.memory(),
        keyStore: _MemoryKeyStore(),
      );
      // These cases assert PARKING behaviour and use 'cat-001' as a placeholder
      // category. Since F-029 fails closed on an unresolvable category, the row
      // must exist — otherwise the budget is never queued and the test would be
      // asserting the refusal path instead of the capability gate it covers.
      await db.customStatement(
        "INSERT INTO categories(id, key, name_ar, icon, color, is_income, "
        "sort_order) VALUES('cat-001', 'cat_001_key', 'فئة', 'tag', '#000', 0, 97);",
      );
    });
    tearDown(() async => db.close());

    // Scenario 4 (+6) — with the gate disabling planning money entities, the
    // pull NEVER fetches user_budgets/user_goals/goal_contributions, so no
    // legacy / missing-currency remote payload can be applied (and no currency
    // is reconstructed from base). Non-planning entities are still pulled.
    test('gated planning entities are never fetched; others are', () async {
      final remote = _RecordingRemoteSource();
      // The exact gate result the providers compute today (both caps unknown):
      // planning entities disabled, everything else enabled.
      bool gate(String e) => e != _budget && e != _goal && e != _contribution;

      await PlanningPullService(
        db: db,
        isEnabled: gate,
        getAuthUserId: () async => 'user-1',
        remoteSource: remote,
      
    // C-3: covers pull MECHANICS; consent is asserted in
    // financial_pull_consent_test.dart.
    mayEgress: () async => true,
  ).pull();

      expect(remote.fetchedTables, isNot(contains('user_budgets')));
      expect(remote.fetchedTables, isNot(contains('user_goals')));
      expect(remote.fetchedTables, contains('user_subscriptions'));

      // Nothing was applied to the local planning tables.
      final budgets = await db
          .customSelect('SELECT COUNT(*) AS n FROM budgets;')
          .getSingle();
      expect(budgets.read<int>('n'), 0);
    });
  });
}
