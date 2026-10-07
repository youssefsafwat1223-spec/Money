import '../../data/db/app_database.dart';
import '../../data/db/sql_value_codec.dart';
import '../../domain/entities/goal_entity.dart';
import '../../domain/entities/plan_entity.dart';
import '../../domain/finance/money.dart';
import '../../domain/repositories/goal_repository.dart';
import '../../domain/repositories/plan_repository.dart';
import '../../features/planning_sync/services/planning_outbox_queue.dart';
import '../utils/id_generator.dart';

/// D1 (user decision 4): Keep Mine against a cloud TOMBSTONE of a goal or plan
/// re-creates the user's version as a NEW record with a NEW identity. The cloud
/// row is never un-deleted and its children are never re-pointed or resurrected.
/// Both run inside the resolver's transaction (see [ConflictRestoreAsNew]); the
/// resolver then removes the old record's own outbox rows and retires the old
/// row locally.
///
/// CHILDREN. Only the user's UNSYNCED children (no server id, not deleted) move
/// to the new record, each as a NEW child created through the normal repository
/// path (new identity, queued as a create). The cloud's own children (already
/// synced, i.e. cloud records of the record the other device deleted) stay with
/// the old record, which is hidden. The old record's unsynced children have
/// their queued operations dropped (their parent is gone, so they could only
/// dead-letter) and are retired locally.
///   goal  -> pending contributions are copied. The new goal's saved amount is the
///            old local amount minus those pending contributions (the balance
///            carried over, floored at 0); re-adding each contribution through
///            addContribution brings it back to the old local amount, and the
///            server's own saved_amount (insert + add_goal_contribution) matches.
///   plan  -> pending transaction links are copied as links of the new plan.
///            Pending link deletes are simply dropped. (Bill payments belong to
///            subscriptions, not plans; subscriptions are outside this change.)
Future<void> restoreGoalAsNew({
  required AppDatabase db,
  required GoalRepository goals,
  required String localId,
}) async {
  final old = await goals.getById(localId);
  if (old == null) return;
  final unsynced = {
    for (final r in await db.customSelect(
      'SELECT id FROM goal_contributions WHERE goal_id = ${sqlString(localId)} '
      'AND server_id IS NULL AND deleted_at IS NULL;',
    ).get())
      r.read<String>('id'),
  };
  final pending = [
    for (final c in await goals.getContributions(localId))
      if (unsynced.contains(c.id)) c,
  ];
  var carried = old.savedMoney;
  for (final c in pending) {
    carried = carried - c.amountMoney;
  }
  if (carried.isNegative) carried = Money.zero(old.currency);

  final newId = IdGenerator.next();
  await goals.save(old.copyWith(id: newId, savedMoney: carried));
  for (final c in pending) {
    await goals.addContribution(GoalContributionEntity(
      id: IdGenerator.next(),
      goalId: newId,
      amountMoney: c.amountMoney,
      createdAt: c.createdAt,
      note: c.note,
    ));
  }

  await retireUnsyncedGoalChildren(db, localId);
}

Future<void> restorePlanAsNew({
  required AppDatabase db,
  required PlanRepository plans,
  required String localId,
}) async {
  final old = await plans.getById(localId);
  if (old == null) return;
  final pendingTx = [
    for (final r in await db.customSelect(
      'SELECT transaction_id FROM plan_transaction_links '
      'WHERE plan_id = ${sqlString(localId)} AND server_id IS NULL '
      'AND deleted_at IS NULL;',
    ).get())
      r.read<String>('transaction_id'),
  ];

  final newId = IdGenerator.next();
  await plans.save(PlanEntity(
    id: newId,
    name: old.name,
    budgetAmountMoney: old.budgetAmountMoney,
    currency: old.currency,
    startDate: old.startDate,
    endDate: old.endDate,
    accountIds: old.accountIds,
    cardLast4s: old.cardLast4s,
    status: old.status,
    createdAt: old.createdAt,
    icon: old.icon,
  ));
  for (final tx in pendingTx) {
    await plans.linkTransactionToPlan(planId: newId, transactionId: tx);
  }

  await retireUnsyncedPlanChildren(db, localId);
}

/// Drops the queued creates of a tombstoned goal's / plan's own UNSYNCED children
/// and retires those rows locally (their parent is deleted in the cloud, so they
/// could only dead-letter). Also used by Keep Cloud on a tombstone. Cloud-synced
/// children are never touched.
Future<void> retireUnsyncedGoalChildren(AppDatabase db, String goalId) async {
  for (final r in await db.customSelect(
    'SELECT id FROM goal_contributions WHERE goal_id = ${sqlString(goalId)} '
    'AND server_id IS NULL AND deleted_at IS NULL;',
  ).get()) {
    await db.customStatement(
      'DELETE FROM planning_sync_outbox WHERE entity_type = '
      '${sqlString(PlanningOutboxQueue.goalContributionsEntityType)} '
      'AND entity_id = ${sqlString(r.read<String>('id'))};',
    );
  }
  await db.customStatement(
    "UPDATE goal_contributions SET deleted_at = ${sqlString(dateTimeToSql(DateTime.now().toUtc()))}, "
    "sync_status = 'synced' WHERE goal_id = ${sqlString(goalId)} "
    'AND server_id IS NULL AND deleted_at IS NULL;',
  );
}

Future<void> retireUnsyncedPlanChildren(AppDatabase db, String planId) async {
  for (final r in await db.customSelect(
    'SELECT transaction_id FROM plan_transaction_links '
    'WHERE plan_id = ${sqlString(planId)} AND server_id IS NULL '
    'AND deleted_at IS NULL;',
  ).get()) {
    await db.customStatement(
      'DELETE FROM planning_sync_outbox WHERE entity_type = '
      '${sqlString(PlanningOutboxQueue.planLinksEntityType)} '
      "AND entity_id = ${sqlString('$planId:${r.read<String>('transaction_id')}')};",
    );
  }
  await db.customStatement(
    "UPDATE plan_transaction_links SET deleted_at = ${sqlString(dateTimeToSql(DateTime.now().toUtc()))}, "
    "sync_status = 'synced' WHERE plan_id = ${sqlString(planId)} "
    'AND server_id IS NULL AND deleted_at IS NULL;',
  );
}
