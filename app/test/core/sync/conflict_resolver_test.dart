import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/sync/conflict_policy.dart';
import 'package:money_companion/core/sync/conflict_resolver.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('conflict policy (pure)', () {
    test('covers all twelve entities with the right classification', () {
      expect(kConflictPolicies, hasLength(12));
      expect(interactiveConflictPolicies.map((p) => p.entityType).toSet(), {
        ConflictEntities.transaction,
        ConflictEntities.account,
        ConflictEntities.budget,
        ConflictEntities.subscription,
        ConflictEntities.goal,
        ConflictEntities.plan,
      });
      expect(deterministicConflictPolicies.map((p) => p.entityType).toSet(), {
        ConflictEntities.card,
        ConflictEntities.category,
        ConflictEntities.settings,
      });
      final appendOnly = kConflictPolicies.values
          .where((p) => p.resolution == ConflictResolution.none)
          .map((p) => p.entityType)
          .toSet();
      expect(appendOnly, {
        ConflictEntities.billPayment,
        ConflictEntities.goalContribution,
        ConflictEntities.planLink,
      });
      // Children never carry a revision — they are append-only idempotent.
      for (final p in kConflictPolicies.values) {
        expect(
          p.mechanism == ConflictMechanism.appendOnlyIdempotent,
          p.resolution == ConflictResolution.none,
          reason: '${p.entityType} mechanism/resolution must agree',
        );
      }
    });

    test('transactions are hard-deleted locally (no deleted_at filter)', () {
      expect(conflictPolicyFor(ConflictEntities.transaction).softDelete, isFalse);
      expect(conflictPolicyFor(ConflictEntities.goal).softDelete, isTrue);
    });

    test('an unknown entity throws rather than silently skipping', () {
      expect(() => conflictPolicyFor('nope'), throwsArgumentError);
    });
  });

  group('UniversalConflictResolver', () {
    late AppDatabase db;
    late List<String> reEnqueued;
    late UniversalConflictResolver resolver;

    setUp(() async {
      db = await AppDatabase.open(
        executor: NativeDatabase.memory(),
        keyStore: _MemoryKeyStore(),
      );
      reEnqueued = <String>[];
      resolver = UniversalConflictResolver(
        db: db,
        reEnqueue: {
          for (final p in interactiveConflictPolicies)
            p.entityType: (id) async => reEnqueued.add('${p.entityType}/$id'),
        },
        baseFetcher: (table, serverId) async =>
            const ConflictBase(updatedAt: 'current-server-ts', revision: 7),
      );
    });
    tearDown(() => db.close());

    Future<void> seedGoal(String id, {String status = 'conflict'}) async {
      await db.customStatement(
        "INSERT INTO goals(id, name, target_amount, saved_amount, vault_skin, "
        "status, created_at, server_id, server_updated_at, sync_status) VALUES "
        "('$id', 'Travel', 5000, 300, 'classic', 'active', '2026-07-01', "
        "'srv-$id', 'base-ts', '$status');",
      );
      await backfillNonPlanningMoneyV30(db);
      await db.customStatement(
        "INSERT INTO planning_sync_outbox(id, entity_type, entity_id, operation, "
        "payload_json, created_at, updated_at) VALUES "
        "('ob-$id', 'goal', '$id', 'update', '{}', '2026-07-01', '2026-07-01');",
      );
    }

    Future<void> seedTransaction(String id) async {
      await db.customStatement(
        "INSERT INTO transactions(id, amount, currency, type, source, "
        "occurred_at, raw_message, parse_confidence, status, created_at, "
        "updated_at, server_id, server_updated_at, sync_status) VALUES "
        "('$id', 42.0, 'SAR', 'payment', 'bank', '2026-07-01', 'msg', 0.9, "
        "'confirmed', '2026-07-01', '2026-07-01', 'srv-$id', 'base-ts', "
        "'conflict');",
      );
      await db.customStatement(
        "INSERT INTO ledger_sync_outbox(id, transaction_id, operation, "
        "payload_json, created_at, updated_at) VALUES "
        "('ob-$id', '$id', 'update', '{}', '2026-07-01', '2026-07-01');",
      );
    }

    Future<void> seedCategory(String id) async {
      await db.customStatement(
        "INSERT INTO categories(id, key, name_ar, icon, color, is_income, "
        "sort_order, sync_status) VALUES "
        "('$id', 'k-$id', 'اسم', 'i', '#fff', 0, 0, 'conflict');",
      );
      await db.customStatement(
        "INSERT INTO planning_sync_outbox(id, entity_type, entity_id, operation, "
        "payload_json, created_at, updated_at) VALUES "
        "('ob-$id', 'category', '$id', 'update', '{}', '2026-07-01', "
        "'2026-07-01');",
      );
    }

    Future<String?> statusOf(String table, String id) async => (await db
            .customSelect("SELECT sync_status FROM $table WHERE id='$id';")
            .getSingle())
        .readNullable<String>('sync_status');

    Future<int> outbox(String table, String where) async => (await db
            .customSelect('SELECT COUNT(*) AS n FROM $table WHERE $where;')
            .getSingle())
        .read<int>('n');

    test('listConflicts spans interactive entities across both outboxes, '
        'excluding deterministic ones', () async {
      await seedGoal('g1');
      await seedTransaction('tx1');
      await seedCategory('c1'); // deterministic → must NOT be listed

      final conflicts = await resolver.listConflicts();
      final byType = {for (final c in conflicts) c.entityType: c};
      expect(byType.keys.toSet(),
          {ConflictEntities.goal, ConflictEntities.transaction});
      expect(byType[ConflictEntities.goal]!.label, 'Travel');
      expect(byType[ConflictEntities.transaction]!.label, '42.0');
    });

    test('keep-remote (planning) marks synced and drops the planning outbox row',
        () async {
      await seedGoal('g1');
      await resolver.resolveKeepRemote(ConflictEntities.goal, 'g1');
      expect(await statusOf('goals', 'g1'), 'synced');
      expect(await outbox('planning_sync_outbox', "entity_id='g1'"), 0);
    });

    test('keep-remote (ledger) marks synced and drops the ledger outbox row',
        () async {
      await seedTransaction('tx1');
      await resolver.resolveKeepRemote(ConflictEntities.transaction, 'tx1');
      expect(await statusOf('transactions', 'tx1'), 'synced');
      expect(await outbox('ledger_sync_outbox', "transaction_id='tx1'"), 0);
    });

    test('keep-local rebases to the server version and re-enqueues', () async {
      await seedGoal('g1');
      await db.customStatement('DELETE FROM planning_sync_outbox;');

      await resolver.resolveKeepLocal(ConflictEntities.goal, 'g1');

      final row = await db
          .customSelect(
              "SELECT server_updated_at, sync_status FROM goals WHERE id='g1';")
          .getSingle();
      expect(row.readNullable<String>('server_updated_at'), 'current-server-ts');
      expect(row.readNullable<String>('sync_status'), 'pending');
      expect(reEnqueued, ['goal/g1']);
    });

    test('autoResolveDeterministic resolves config conflicts but leaves '
        'financial ones for the user', () async {
      await seedGoal('g1'); // interactive — must survive
      await seedCategory('c1'); // deterministic — must be auto-resolved

      final n = await resolver.autoResolveDeterministic();
      expect(n, 1);
      expect(await statusOf('categories', 'c1'), 'synced');
      expect(await outbox('planning_sync_outbox', "entity_id='c1'"), 0);
      // The interactive goal is untouched — still awaiting the user's decision.
      expect(await statusOf('goals', 'g1'), 'conflict');
      expect(await resolver.listConflicts(), hasLength(1));
    });
  });
}
