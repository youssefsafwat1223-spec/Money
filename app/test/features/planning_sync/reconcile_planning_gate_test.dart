import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/sync/sync_health.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/sync/exact_transport_capability.dart';
import 'package:money_companion/features/planning_sync/services/startup_sync_reconcile_service.dart';

/// A-1c — the startup budgets/goals backfill is gated on the planning-currency
/// probe per table; other planning entities are unaffected.
class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

void main() {
  late AppDatabase db;
  late List<String> asked;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    for (final t in const ['budgets', 'goals', 'planning_sync_outbox']) {
      await db.customStatement('DELETE FROM $t;');
    }
    asked = [];
  });
  tearDown(() async => db.close());

  Future<void> insertBudget() async {
    final catId = (await db
            .customSelect(
                "SELECT id FROM categories WHERE key = 'restaurants' LIMIT 1;")
            .getSingle())
        .read<String>('id');
    await db.customStatement('''
      INSERT INTO budgets(id, category_id, amount, period, start_date, is_active)
      VALUES ('b1', '$catId', 500.0, 'monthly', '2026-07-01', 1);
    ''');
  }

  Future<void> insertGoal() async {
    await db.customStatement('''
      INSERT INTO goals(id, name, target_amount, saved_amount, vault_skin,
        status, created_at)
      VALUES ('g1', 'Trip', 100.0, 0.0, 'default', 'active', '2026-07-01');
    ''');
  }

  StartupSyncReconcileService service(
          Map<String, ExactTransportCapability> answers) =>
      StartupSyncReconcileService(
        db: db,
        getAuthUserId: () async => 'u1',
        planningCurrencyFor: (table) async {
          asked.add(table);
          return answers[table] ?? ExactTransportCapability.unknown;
        },
      );

  test('no unsynced budgets/goals: nothing probed, nothing parked', () async {
    final plan = await service({}).planningBackfillPlan();
    expect(plan.parked, isFalse);
    expect(plan.entities, containsAll(['budgets', 'goals', 'subscriptions', 'plans']));
    expect(asked, isEmpty);
  });

  test('unverified (unknown/unsupported) budgets+goals are parked, others run',
      () async {
    await insertBudget();
    await insertGoal();
    for (final cap in [
      ExactTransportCapability.unknown,
      ExactTransportCapability.unsupported,
    ]) {
      final plan =
          await service({'user_budgets': cap, 'user_goals': cap}).planningBackfillPlan();
      expect(plan.parked, isTrue, reason: '$cap');
      expect(plan.entities, {'subscriptions', 'plans'}, reason: '$cap');
    }
  });

  test('verified per table: each is gated independently', () async {
    await insertBudget();
    await insertGoal();
    final plan = await service({
      'user_budgets': ExactTransportCapability.verifiedExact,
      'user_goals': ExactTransportCapability.unsupported,
    }).planningBackfillPlan();
    expect(plan.entities, {'subscriptions', 'plans', 'budgets'});
    expect(plan.parked, isTrue);
    expect(asked, ['user_budgets', 'user_goals']);

    final both = await service({
      'user_budgets': ExactTransportCapability.verifiedExact,
      'user_goals': ExactTransportCapability.verifiedExact,
    }).planningBackfillPlan();
    expect(both.parked, isFalse);
    expect(both.entities, containsAll(['budgets', 'goals']));
  });

  test('rows already queued on the outbox are not a backfill concern',
      () async {
    await insertBudget();
    final now = DateTime.now().toUtc().toIso8601String();
    await db.customStatement('''
      INSERT INTO planning_sync_outbox(id, entity_type, entity_id, operation,
        payload_json, attempt_count, created_at, updated_at)
      VALUES ('ob1', 'budgets', 'b1', 'create', '{}', 0, '$now', '$now');
    ''');
    final plan = await service({}).planningBackfillPlan();
    expect(plan.parked, isFalse);
    expect(asked, isEmpty);
  });

  test('fail-closed default: no probe wired => parked', () async {
    await insertBudget();
    final plan = await StartupSyncReconcileService(
            db: db, getAuthUserId: () async => 'u1')
        .planningBackfillPlan();
    expect(plan.parked, isTrue);
    expect(plan.entities.contains('budgets'), isFalse);
  });

  test('capability-parked is an observable, non-failure SyncHealth state', () {
    final health = SyncHealth()..recordCapabilityParked(SyncDomain.planning);
    final s = health.of(SyncDomain.planning);
    expect(s.lastErrorClass, SyncErrorClass.capabilityParked);
    expect(s.consecutiveFailures, 0);
  });

  test('sign-out flush gives the backfill a bounded time budget', () {
    final shell = File('lib/features/app/app_shell.dart').readAsStringSync();
    final flush = shell.substring(shell.indexOf('Future<void> _flushPendingForSignOut'));
    final call = flush.indexOf('startupSyncReconcileServiceProvider');
    expect(call, greaterThan(-1));
    expect(flush.substring(call, call + 200), contains('timeBudget'));
    final service = File(
            'lib/features/planning_sync/services/startup_sync_reconcile_service.dart')
        .readAsStringSync();
    expect(service, contains('.run(deadline: deadline)'),
        reason: 'the budget must reach the transactions backfill');
    // The unsynced-inventory contract is unchanged: unsent rows stay visible.
    final inventory =
        File('lib/core/session/unsynced_inventory.dart').readAsStringSync();
    expect(inventory, contains('t.server_id IS NULL'));
  });
}
