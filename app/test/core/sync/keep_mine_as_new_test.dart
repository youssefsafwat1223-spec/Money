import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/sync/conflict_policy.dart';
import 'package:money_companion/core/sync/conflict_resolver.dart';
import 'package:money_companion/core/sync/keep_mine_as_new.dart';
import 'package:money_companion/core/sync/sync_conflict_store.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_goal_repository.dart';
import 'package:money_companion/data/repositories/drift_plan_repository.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/entities/plan_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';

// D1 (user decision 4): Keep Mine on a cloud TOMBSTONE of a goal or plan creates
// a NEW record with a NEW identity; the tombstone is never un-deleted and the
// cloud's children are never re-pointed. Keep Cloud keeps the tombstone.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

void main() {
  late AppDatabase db;
  late PlanningOutboxQueue queue;
  late DriftGoalRepository goals;
  late DriftPlanRepository plans;
  late SyncConflictStore store;

  setUp(() async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    queue = PlanningOutboxQueue(
      db: db,
      isSyncEnabled: (_) => true,
      getAuthUserId: () async => 'user-1',
    );
    goals = DriftGoalRepository(db, outboxQueue: queue);
    plans = DriftPlanRepository(db, outboxQueue: queue);
    store = SyncConflictStore(db);
  });
  tearDown(() => db.close());

  UniversalConflictResolver resolver() => UniversalConflictResolver(
        db: db,
        reEnqueue: const {},
        remoteSync: {
          // Keep Cloud applies the cloud row, which is the tombstone.
          ConflictEntities.goal: ConflictRemoteSync(
            fetch: (_) async => {'id': 'srv-g1', 'deleted_at': 'x'},
            apply: (_) async => db.customStatement(
                "UPDATE goals SET deleted_at = 'x' WHERE id = 'g1';"),
          ),
          ConflictEntities.plan: ConflictRemoteSync(
            fetch: (_) async => {'id': 'srv-p1', 'deleted_at': 'x'},
            apply: (_) async => db.customStatement(
                "UPDATE plans SET deleted_at = 'x' WHERE id = 'p1';"),
          ),
        },
        retireChildren: {
          ConflictEntities.goal: (id) => retireUnsyncedGoalChildren(db, id),
          ConflictEntities.plan: (id) => retireUnsyncedPlanChildren(db, id),
        },
        restoreAsNew: {
          ConflictEntities.goal: (id) =>
              restoreGoalAsNew(db: db, goals: goals, localId: id),
          ConflictEntities.plan: (id) =>
              restorePlanAsNew(db: db, plans: plans, localId: id),
        },
      );

  Future<List<Map<String, Object?>>> outbox() async => [
        for (final r in await db
            .customSelect('SELECT * FROM planning_sync_outbox ORDER BY entity_type, entity_id')
            .get())
          r.data
      ];

  Future<void> markSynced(String table, String id, String serverId) =>
      db.customStatement("UPDATE $table SET server_id = '$serverId', "
          "sync_status = 'synced' WHERE id = '$id';");

  // goal g1: saved 45 = cloud contribution A (30, synced) + pending B (15).
  Future<void> seedGoal() async {
    await goals.save(GoalEntity(
      id: 'g1',
      name: 'Travel',
      currency: 'SAR',
      targetMoney: Money.parse('5000', 'SAR'),
      savedMoney: Money(0, 'SAR'),
      lastNotifiedSavedMoney: Money(0, 'SAR'),
      vaultSkin: 'classic',
      status: 'active',
      createdAt: DateTime.utc(2026, 7, 1),
    ));
    await goals.addContribution(GoalContributionEntity(
        id: 'cA', goalId: 'g1', amountMoney: Money.parse('30', 'SAR'),
        createdAt: DateTime.utc(2026, 7, 2)));
    await markSynced('goals', 'g1', 'srv-g1');
    await markSynced('goal_contributions', 'cA', 'srv-cA');
    await db.customStatement('DELETE FROM planning_sync_outbox;');
    await goals.addContribution(GoalContributionEntity(
        id: 'cB', goalId: 'g1', amountMoney: Money.parse('15', 'SAR'),
        createdAt: DateTime.utc(2026, 7, 3), note: 'pending'));
    await goals.save((await goals.getById('g1'))!.copyWith(name: 'Travel 2'));
    await store.flag(
        entityType: ConflictEntities.goal,
        localId: 'g1',
        kind: SyncConflictKind.tombstone,
        serverId: 'srv-g1',
        theirs: {'id': 'srv-g1', 'deleted_at': 'x'});
  }

  group('goal', () {
    test('listConflicts offers Keep Mine for a tombstoned goal', () async {
      await seedGoal();
      final c = (await resolver().listConflicts())
          .firstWhere((c) => c.entityType == ConflictEntities.goal);
      expect(c.canKeepMine, isTrue);
    });

    test('Keep Mine: new identity, old record retired, never un-deleted',
        () async {
      await seedGoal();
      await resolver().resolveKeepLocal(ConflictEntities.goal, 'g1');

      final live = await goals.getAll();
      expect(live, hasLength(1));
      final n = live.single;
      expect(n.id, isNot('g1'));
      expect(n.name, 'Travel 2');
      expect(n.savedMoney, Money.parse('45', 'SAR'),
          reason: 'carried 30 + the pending 15 re-added');

      final old = (await db.customSelect("SELECT * FROM goals WHERE id='g1'").getSingle()).data;
      expect(old['deleted_at'], isNotNull, reason: 'the old record stays deleted');
      expect(old['sync_status'], 'synced');
      expect(old['server_id'], 'srv-g1');

      expect((await db.customSelect("SELECT resolution FROM sync_conflicts WHERE local_id='g1'").getSingle())
          .read<String>('resolution'), 'mine_as_new');
    });

    test('children: only the unsynced contribution is copied (new id, new '
        'goal); the cloud contribution is neither copied nor re-pointed',
        () async {
      await seedGoal();
      await resolver().resolveKeepLocal(ConflictEntities.goal, 'g1');
      final n = (await goals.getAll()).single;

      final copied = await goals.getContributions(n.id);
      expect(copied, hasLength(1));
      expect(copied.single.id, isNot('cB'));
      expect(copied.single.amountMoney, Money.parse('15', 'SAR'));
      expect(copied.single.note, 'pending');

      final a = (await db.customSelect("SELECT * FROM goal_contributions WHERE id='cA'").getSingle()).data;
      expect(a['goal_id'], 'g1', reason: 'cloud child never re-pointed');
      expect(a['server_id'], 'srv-cA');
      expect(a['deleted_at'], isNull, reason: 'cloud child untouched');

      final b = (await db.customSelect("SELECT * FROM goal_contributions WHERE id='cB'").getSingle()).data;
      expect(b['deleted_at'], isNotNull, reason: 'old pending child retired');
      expect(b['sync_status'], 'synced');
    });

    test('outbox: only creates for the NEW goal and NEW contribution; nothing '
        'for the tombstoned ids (no update, no un-delete, no dead letter)',
        () async {
      await seedGoal();
      await resolver().resolveKeepLocal(ConflictEntities.goal, 'g1');
      final n = (await goals.getAll()).single;
      final newC = (await goals.getContributions(n.id)).single;
      final rows = await outbox();
      expect({for (final r in rows) '${r['entity_type']}:${r['entity_id']}': r['operation']}, {
        'goal:${n.id}': 'create',
        'goal_contribution:${newC.id}': 'create',
      });
      for (final r in rows) {
        expect(r['entity_id'], isNot(anyOf('g1', 'cA', 'cB')));
      }
    });

    test('Keep Cloud keeps the tombstone: no new goal, outbox cleared',
        () async {
      await seedGoal();
      expect(await resolver().resolveKeepRemote(ConflictEntities.goal, 'g1'), isTrue);
      expect(await goals.getAll(), isEmpty);
      expect(await outbox(), isEmpty,
          reason: 'the unsynced child of a deleted goal is dropped, not left to dead-letter');
      expect((await db.customSelect("SELECT deleted_at FROM goals WHERE id='g1'").getSingle())
          .readNullable<String>('deleted_at'), isNotNull);
      expect((await db.customSelect("SELECT deleted_at, goal_id FROM goal_contributions WHERE id='cA'").getSingle())
          .readNullable<String>('deleted_at'), isNull, reason: 'cloud child untouched');
      expect((await db.customSelect("SELECT resolution FROM sync_conflicts WHERE local_id='g1'").getSingle())
          .read<String>('resolution'), 'cloud');
    });

    test('saved amount smaller than the pending sum floors the carry at 0',
        () async {
      await seedGoal();
      await db.customStatement(
          "UPDATE goals SET saved_amount = 5, saved_amount_minor = 500 WHERE id='g1';");
      await resolver().resolveKeepLocal(ConflictEntities.goal, 'g1');
      final n = (await goals.getAll()).single;
      expect(n.savedMoney, Money.parse('15', 'SAR'), reason: '0 carried + 15 re-added');
    });
  });

  group('plan', () {
    Future<void> tx(String id) async {
      await db.customStatement('''
        INSERT INTO transactions(id, amount, currency, type, source, occurred_at,
          raw_message, parse_confidence, status, created_at, updated_at, direction)
        VALUES ('$id', 10.0, 'SAR', 'payment', 'bank', '2026-07-05', '', 0.9,
          'confirmed', '2026-07-05', '2026-07-05', 'debit');
      ''');
    }

    // plan p1 with link L1 (tx-1, synced with the cloud) and link L2 (tx-2, pending).
    Future<void> seedPlan() async {
      await tx('tx-1');
      await tx('tx-2');
      await plans.save(PlanEntity(
        id: 'p1',
        name: 'Trip',
        budgetAmountMoney: Money.parse('900', 'SAR'),
        currency: 'SAR',
        startDate: DateTime.utc(2026, 7, 1),
        endDate: DateTime.utc(2026, 7, 31),
        accountIds: const [],
        cardLast4s: const [],
        status: PlanStatus.active,
        createdAt: DateTime.utc(2026, 7, 1),
        icon: 'plane',
      ));
      await plans.linkTransactionToPlan(planId: 'p1', transactionId: 'tx-1');
      await markSynced('plans', 'p1', 'srv-p1');
      await db.customStatement(
          "UPDATE plan_transaction_links SET server_id = 'srv-l1', "
          "sync_status = 'synced' WHERE transaction_id = 'tx-1';");
      await db.customStatement('DELETE FROM planning_sync_outbox;');
      await plans.linkTransactionToPlan(planId: 'p1', transactionId: 'tx-2');
      await store.flag(
          entityType: ConflictEntities.plan,
          localId: 'p1',
          kind: SyncConflictKind.tombstone,
          serverId: 'srv-p1',
          theirs: {'id': 'srv-p1', 'deleted_at': 'x'});
    }

    test('Keep Mine: new plan identity; only the pending link is copied; the '
        'cloud link stays with the tombstoned plan', () async {
      await seedPlan();
      expect((await resolver().listConflicts())
          .firstWhere((c) => c.entityType == ConflictEntities.plan)
          .canKeepMine, isTrue);
      await resolver().resolveKeepLocal(ConflictEntities.plan, 'p1');

      final live = await plans.getAll();
      expect(live, hasLength(1));
      final n = live.single;
      expect(n.id, isNot('p1'));
      expect(n.name, 'Trip');
      expect(n.budgetAmountMoney, Money.parse('900', 'SAR'));
      expect(n.icon, 'plane');

      final old = (await db.customSelect("SELECT * FROM plans WHERE id='p1'").getSingle()).data;
      expect(old['deleted_at'], isNotNull);
      expect(old['sync_status'], 'synced');

      final links = [
        for (final r in await db.customSelect('SELECT * FROM plan_transaction_links ORDER BY plan_id, transaction_id').get())
          r.data
      ];
      final byKey = {for (final l in links) '${l['plan_id']}|${l['transaction_id']}': l};
      expect(byKey['p1|tx-1']!['deleted_at'], isNull, reason: 'cloud link untouched');
      expect(byKey['p1|tx-1']!['server_id'], 'srv-l1');
      expect(byKey['p1|tx-2']!['deleted_at'], isNotNull, reason: 'old pending link retired');
      expect(byKey['${n.id}|tx-2']!['deleted_at'], isNull, reason: 'copied to the new plan');
      expect(byKey.containsKey('${n.id}|tx-1'), isFalse, reason: 'cloud link not copied');

      expect({for (final r in await outbox()) '${r['entity_type']}:${r['entity_id']}': r['operation']}, {
        'plan:${n.id}': 'create',
        'plan_transaction_link:${n.id}:tx-2': 'create',
      });
    });

    test('Keep Cloud keeps the tombstone: no new plan', () async {
      await seedPlan();
      expect(await resolver().resolveKeepRemote(ConflictEntities.plan, 'p1'), isTrue);
      expect(await plans.getAll(), isEmpty);
      expect(await outbox(), isEmpty);
    });
  });
}
