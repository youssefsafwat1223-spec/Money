import 'dart:convert';

import 'package:drift/drift.dart' show Variable;
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../core/sync/outbox_failure.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/bounded_lookup.dart';
import '../../../data/db/money_codec.dart';
import '../../../data/db/planning_cutover.dart';
import '../../../data/db/sql_value_codec.dart';
import '../../../data/repositories/drift_repository_support.dart';
import '../../../data/sync/exact_transport_capability.dart';
import '../../../data/sync/sync_cursor.dart';
import '../../../domain/finance/money_transport.dart';
import '../../../engine/parser/capture_money.dart';
import 'planning_outbox_queue.dart';

const planningChildBillPaymentSelect = '*, amount_text:amount::text';
// MALI-026 (B8-3 §9): canonical goal-contribution pull projects amount as ::text
// so it is parsed EXACTLY. The contribution carries no currency of its own — its
// parent goal is the currency authority (§10), resolved from the already-pulled
// canonical local goal, never from the base currency.
const planningChildGoalContributionSelect = '*, amount_text:amount::text';

/// MALI-051n: outcome of applying one child pull-row. `missingParent` means the
/// parent hasn't synced yet → the row is durably parked (never dropped) so the
/// cursor can advance safely and the row is retried after the parent arrives.
enum _ChildApplyOutcome { applied, missingParent, preservedPending }

/// After this many failed drain attempts a parked row is marked terminal: it
/// stops looping forever but stays visible for diagnostics (a permanently
/// unresolvable parent relationship rather than a transient ordering gap).
const int _kParkedChildMaxAttempts = 25;

abstract interface class PlanningChildRemote {
  Future<Map<String, dynamic>> callRpc(
    String name,
    Map<String, dynamic> params,
  );

  Future<Map<String, dynamic>> upsertPlanLink(
    Map<String, dynamic> row,
  );

  Future<Map<String, dynamic>?> findPlanLink({
    required String userId,
    required String planId,
    required String transactionId,
  });

  Future<void> tombstonePlanLink(String serverId);

  Future<List<Map<String, dynamic>>> fetchRows(
    String table, {
    required SyncCursor after,
    int limit,
  });
}

class SupabasePlanningChildRemote implements PlanningChildRemote {
  const SupabasePlanningChildRemote();

  SupabaseClient get _client => Supabase.instance.client;

  @override
  Future<Map<String, dynamic>> callRpc(
    String name,
    Map<String, dynamic> params,
  ) async {
    final response = await _client.rpc(name, params: params);
    return Map<String, dynamic>.from(response as Map);
  }

  @override
  Future<List<Map<String, dynamic>>> fetchRows(
    String table, {
    required SyncCursor after,
    int limit = 200,
  }) async {
    final query = _client.from(table).select(switch (table) {
      'user_bill_payments' => planningChildBillPaymentSelect,
      'user_goal_contributions' => planningChildGoalContributionSelect,
      _ => '*',
    });
    final filtered = after.id.isEmpty
        ? query
        : query.or(
            'updated_at.gt.${after.updatedAt},'
            'and(updated_at.eq.${after.updatedAt},id.gt.${after.id})',
          );
    final response = await filtered
        .order('updated_at', ascending: true)
        .order('id', ascending: true)
        .limit(limit);
    return (response as List)
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList(growable: false);
  }

  @override
  Future<Map<String, dynamic>?> findPlanLink({
    required String userId,
    required String planId,
    required String transactionId,
  }) async {
    final response = await _client
        .from('user_plan_transaction_links')
        .select()
        .eq('user_id', userId)
        .eq('plan_id', planId)
        .eq('transaction_id', transactionId)
        .maybeSingle();
    return response == null ? null : Map<String, dynamic>.from(response);
  }

  @override
  Future<Map<String, dynamic>> upsertPlanLink(
    Map<String, dynamic> row,
  ) async {
    final existing = await findPlanLink(
      userId: row['user_id'] as String,
      planId: row['plan_id'] as String,
      transactionId: row['transaction_id'] as String,
    );
    if (existing == null) {
      final response = await _client
          .from('user_plan_transaction_links')
          .insert(row)
          .select()
          .single();
      return Map<String, dynamic>.from(response);
    }
    if (existing['deleted_at'] != null) {
      final response = await _client
          .from('user_plan_transaction_links')
          .update({'deleted_at': null})
          .eq('id', existing['id'] as String)
          .select()
          .single();
      return Map<String, dynamic>.from(response);
    }
    return existing;
  }

  @override
  Future<void> tombstonePlanLink(String serverId) async {
    await _client.from('user_plan_transaction_links').update({
      'deleted_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', serverId);
  }
}

/// Synchronizes planning children after their parent rows. These records need
/// relationship-aware RPCs/server IDs, so they cannot use the flat parent
/// upsert worker. Local writes remain authoritative for UI and are retried via
/// [PlanningOutboxQueue].
class PlanningChildSyncService {
  PlanningChildSyncService({
    required AppDatabase db,
    required PlanningOutboxQueue queue,
    required bool Function(String entityType) isEnabled,
    bool Function(String entityType) isPullEnabled = _defaultPullEnabled,
    /// C-3 — child rows carry money (contribution amounts, bill payments).
    /// Defaults to DENY.
    Future<bool> Function()? mayEgress,
    Future<String?> Function()? getAuthUserId,
    PlanningChildRemote? remote,
    int pageSize = 200,
    PlanningCutoverCoordinator coordinator =
        const SchemaV29PlanningCutoverCoordinator(),
    ExactTransportCapability Function() pushCapability = _defaultPushCapability,
    ExactTransportCapability Function() pullCapability = _defaultPullCapability,
  })  : assert(pageSize > 0),
        _db = db,
        _queue = queue,
        _isPushEnabled = isEnabled,
        _isPullEnabled = isPullEnabled,
        _getAuthUserId = getAuthUserId ?? _defaultUserId,
        _pageSize = pageSize,
        _remote = remote ?? const SupabasePlanningChildRemote(),
        _coordinator = coordinator,
        _pushCapability = pushCapability,
        _pullCapability = pullCapability,
        _mayEgress = mayEgress ?? _denyEgressByDefault;

  static Future<bool> _denyEgressByDefault() async => false;

  final AppDatabase _db;
  final PlanningOutboxQueue _queue;
  final bool Function(String entityType) _isPushEnabled;
  final bool Function(String entityType) _isPullEnabled;
  final Future<String?> Function() _getAuthUserId;
  final PlanningChildRemote _remote;
  final int _pageSize;
  final PlanningCutoverCoordinator _coordinator;
  final ExactTransportCapability Function() _pushCapability;
  final ExactTransportCapability Function() _pullCapability;
  final Future<bool> Function() _mayEgress;

  static ExactTransportCapability _defaultPushCapability() =>
      ExactTransportCapability.unknown;
  static bool _defaultPullEnabled(String _) => false;
  static ExactTransportCapability _defaultPullCapability() =>
      ExactTransportCapability.unknown;

  static Future<String?> _defaultUserId() async {
    if (!SupabaseConfig.isConfigured) return null;
    try {
      return Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  Future<void> sync() async {
    final userId = await _getAuthUserId();
    if (userId == null) return;
    if (_pushCapability() == ExactTransportCapability.verifiedExact) {
      await _queue.reArmParked();
    }
    if (kDebugMode) debugPrint('[PlanningChildSync] start');
    await _push(userId);
    await _pull();
    if (kDebugMode) debugPrint('[PlanningChildSync] done');
  }

  Future<void> _push(String userId) async {
    for (final type in const [
      PlanningOutboxQueue.goalContributionsEntityType,
      PlanningOutboxQueue.billPaymentsEntityType,
      PlanningOutboxQueue.planLinksEntityType,
    ]) {
      if (!_isPushEnabled(type)) continue;
      final items = await _queue.pendingItems(entityType: type);
      for (final item in items) {
        try {
          if (item.entityType == PlanningOutboxQueue.billPaymentsEntityType &&
              item.operation != PlanningSyncOperation.delete &&
              shouldParkExactMoneyWrite(
                cutoverState: _coordinator.state(),
                pushCapability: _pushCapability(),
              )) {
            await _queue.park(
              item.id,
              exactMoneyTransportUnverifiedReason,
            );
            continue;
          }
          await _pushItem(userId, item);
          await _queue.markSuccess(item.id);
        } catch (error) {
          await _queue.markFailed(
            item.id,
            error.toString(),
            classifyOutboxError(error),
          );
          if (kDebugMode) {
            debugPrint('[PlanningChildSync] push ${item.entityType}: $error');
          }
        }
      }
    }
  }

  Future<void> _pushItem(String userId, PlanningOutboxItem item) async {
    switch (item.entityType) {
      case PlanningOutboxQueue.goalContributionsEntityType:
        await _pushGoalContribution(item);
      case PlanningOutboxQueue.billPaymentsEntityType:
        await _pushBillPayment(item);
      case PlanningOutboxQueue.planLinksEntityType:
        await _pushPlanLink(userId, item);
      default:
        throw ArgumentError('Unsupported planning child: ${item.entityType}');
    }
  }

  Future<void> _pushGoalContribution(PlanningOutboxItem item) async {
    if (item.operation == PlanningSyncOperation.delete) {
      throw UnsupportedError('Goal contribution deletion is not supported');
    }
    final payload = item.payloadJson;
    final goalId =
        await _serverId('goals', payload['local_goal_id'] as String?);
    if (goalId == null) throw StateError('goal_parent_not_synced');
    final result = await _remote.callRpc('add_goal_contribution', {
      'p_goal_id': goalId,
      'p_client_request_id': item.entityId,
      'p_local_id': item.entityId,
      'p_amount': payload['amount'],
      'p_created_at': payload['created_at'],
      'p_note': payload['note'],
    });
    final row = Map<String, dynamic>.from(result['contribution'] as Map);
    final goal = Map<String, dynamic>.from(result['goal'] as Map);
    await _markChildSynced('goal_contributions', item.entityId, row);
    final now = dateTimeToSql(DateTime.now().toUtc());
    if (_coordinator.state() == PlanningCutoverState.canonical) {
      // §8/§9: exact — the 0077-era RPC returns the goal's new saved amount as a
      // ::text NUMERIC + its currency, so write the `_minor` authority + the REAL
      // shadow from Money. No `(num).toDouble()` on the canonical path.
      final currency = goal['currency'];
      if (currency is! String) {
        throw const MoneyTransportException(
            'goal contribution response requires a String goal currency');
      }
      final saved =
          moneyFromPulledValueRequired(goal['saved_amount_text'], currency);
      await _db.customStatement('''
        UPDATE goals SET
          saved_amount = ${kMoneyCodec.sqlRealLiteral(saved)},
          saved_amount_minor = ${kMoneyCodec.sqlMinorLiteral(saved)},
          server_updated_at = ${sqlNullableString(goal['updated_at'] as String?)},
          synced_at = ${sqlString(now)},
          sync_status = 'synced'
        WHERE server_id = ${sqlString(goalId)};
      ''');
      return;
    }
    // LEGACY (pre-cutover) compatibility shape — JSON number.
    await _db.customStatement('''
      UPDATE goals SET saved_amount = ${(goal['saved_amount'] as num).toDouble()},
        server_updated_at = ${sqlNullableString(goal['updated_at'] as String?)},
        synced_at = ${sqlString(now)},
        sync_status = 'synced'
      WHERE server_id = ${sqlString(goalId)};
    ''');
  }

  Future<void> _pushBillPayment(PlanningOutboxItem item) async {
    if (item.operation == PlanningSyncOperation.delete) {
      final serverId = await _serverId('bill_payments', item.entityId);
      if (serverId == null) throw StateError('payment_not_synced');
      final result = await _remote.callRpc(
        'delete_bill_payment',
        {'p_payment_id': serverId},
      );
      final payment = Map<String, dynamic>.from(result['payment'] as Map);
      final subscription =
          Map<String, dynamic>.from(result['subscription'] as Map);
      await _markChildSynced('bill_payments', item.entityId, payment);
      await _updateSubscriptionCounter(subscription);
      return;
    }
    final payload = item.payloadJson;
    final subscriptionId = await _serverId(
      'subscriptions',
      payload['local_subscription_id'] as String?,
    );
    if (subscriptionId == null) {
      throw StateError('subscription_parent_not_synced');
    }
    final localTransactionId = payload['local_transaction_id'] as String?;
    final transactionId = await _serverId('transactions', localTransactionId);
    if (localTransactionId != null && transactionId == null) {
      throw StateError('transaction_parent_not_synced');
    }
    final result = await _remote.callRpc('record_bill_payment', {
      'p_subscription_id': subscriptionId,
      'p_transaction_id': transactionId,
      'p_client_request_id': item.entityId,
      'p_local_id': item.entityId,
      'p_amount': payload['amount'],
      'p_currency': payload['currency'],
      'p_period_start': payload['period_start'],
      'p_period_end': payload['period_end'],
      'p_paid_at': payload['paid_at'],
      'p_installment_index': payload['installment_index'],
      'p_note': payload['note'],
    });
    final payment = Map<String, dynamic>.from(result['payment'] as Map);
    final subscription =
        Map<String, dynamic>.from(result['subscription'] as Map);
    await _markChildSynced('bill_payments', item.entityId, payment);
    await _updateSubscriptionCounter(subscription);
  }

  Future<void> _pushPlanLink(
    String userId,
    PlanningOutboxItem item,
  ) async {
    final payload = item.payloadJson;
    final localPlanId = payload['local_plan_id'] as String;
    final localTransactionId = payload['local_transaction_id'] as String;
    final planId = await _serverId('plans', localPlanId);
    final transactionId = await _serverId('transactions', localTransactionId);
    if (planId == null || transactionId == null) {
      throw StateError('plan_link_parent_not_synced');
    }
    if (item.operation == PlanningSyncOperation.delete) {
      final existing = await _remote.findPlanLink(
        userId: userId,
        planId: planId,
        transactionId: transactionId,
      );
      if (existing != null) {
        await _remote.tombstonePlanLink(existing['id'] as String);
      }
      await _markPlanLinkSynced(
        localPlanId,
        localTransactionId,
        existing?['id'] as String?,
      );
      return;
    }
    final row = await _remote.upsertPlanLink({
      'user_id': userId,
      'plan_id': planId,
      'transaction_id': transactionId,
      'client_request_id': item.entityId,
      'created_at': payload['created_at'],
    });
    await _markPlanLinkSynced(
      localPlanId,
      localTransactionId,
      row['id'] as String,
      serverUpdatedAt: row['updated_at'] as String?,
    );
  }

  Future<void> _pull() async {
    // C-3 — consent precedes capability: a user who declined cloud sync must
    // not have child rows pulled even where the transport is proven.
    if (!await _mayEgress()) return;
    // Audit H-4: pull authority is independent from push authority. This guard
    // deliberately precedes parked-row draining, every remote fetch, and every
    // planning_child_* cursor read/write. Unknown and unsupported therefore
    // leave both canonical child rows and their watermarks entirely unproven.
    if (!exactPullAllowed(_pullCapability())) {
      if (kDebugMode) {
        debugPrint(
            '[PlanningChildSync] pull parked: exact transport unverified');
      }
      return;
    }
    if (_isPullEnabled(PlanningOutboxQueue.goalContributionsEntityType)) {
      // Drain BEFORE the cursor loop so children parked on earlier cycles are
      // re-attempted now that their parents (pulled earlier this cycle) exist.
      await _drainParked(
          'goal_contributions', _pullGoalContribution, _scopeForGoalContributions);
      await _pullTable(
        'user_goal_contributions',
        'goal_contributions',
        _pullGoalContribution,
        _scopeForGoalContributions,
      );
    }
    if (_isPullEnabled(PlanningOutboxQueue.billPaymentsEntityType)) {
      await _drainParked(
          'bill_payments', _pullBillPayment, _scopeForBillPayments);
      await _pullTable('user_bill_payments', 'bill_payments', _pullBillPayment,
          _scopeForBillPayments);
    }
    if (_isPullEnabled(PlanningOutboxQueue.planLinksEntityType)) {
      await _drainParked(
          'plan_transaction_links', _pullPlanLink, _scopeForPlanLinks);
      await _pullTable(
        'user_plan_transaction_links',
        'plan_transaction_links',
        _pullPlanLink,
        _scopeForPlanLinks,
      );
    }
  }

  Future<void> _pullTable(
    String table,
    String localTable,
    _ChildApply apply,
    _ChildScopeBuilder buildScope,
  ) async {
    try {
      final cursorKey = 'planning_child_${table.substring(5)}';
      var cursor = await readSyncCursor(_db, cursorKey);
      while (true) {
        final rows = await _remote.fetchRows(
          table,
          after: cursor,
          limit: _pageSize,
        );
        if (rows.isEmpty) break;

        final nextCursor = SyncCursor.fromServerRow(rows.last);
        await _db.transaction(() async {
          // MALI-029: resolve the whole page's parent/child/pending keys in a
          // handful of bounded lookups instead of per-row SELECTs. Children
          // never parent children, so applying one row cannot change another
          // row's parent existence — a page-built scope stays valid.
          final scope = await buildScope(rows);
          for (final row in rows) {
            final outcome = await apply(row, scope);
            // MALI-051n: a missing-parent row is durably PARKED before the
            // cursor advances past it, so it can never be permanently skipped.
            if (outcome == _ChildApplyOutcome.missingParent) {
              await _parkChild(localTable, row);
            } else {
              // A row that resolved (applied) or is a local pending/conflict is
              // no longer parked — clear any stale parked copy.
              await _unparkChild(localTable, row['id'] as String);
            }
          }
          await writeSyncCursor(_db, cursorKey, nextCursor);
        });
        cursor = nextCursor;
        if (rows.length < _pageSize) break;
      }
    } catch (error) {
      if (kDebugMode) debugPrint('[PlanningChildSync] pull $table: $error');
    }
  }

  /// MALI-051n: re-attempt previously-parked child rows (parents may now exist).
  /// Applied rows are unparked; still-missing rows accrue an attempt and become
  /// terminal after [_kParkedChildMaxAttempts] so they never loop forever.
  Future<void> _drainParked(
    String localTable,
    _ChildApply apply,
    _ChildScopeBuilder buildScope,
  ) async {
    final parked = await () async {
      try {
        return await _db.customSelect(
          "SELECT server_id, row_json, attempt_count FROM parked_child_rows "
          "WHERE table_name = ${sqlString(localTable)} "
          "AND reason != 'terminal' ORDER BY first_seen_at LIMIT 500;",
        ).get();
      } catch (error) {
        if (kDebugMode) debugPrint('[PlanningChildSync] drain read: $error');
        return null;
      }
    }();
    if (parked == null) return;
    // Decode the whole parked batch up front (corrupt rows → terminal) so the
    // resolve scope can be built once for the batch (MALI-029). Each row is
    // still applied in ITS OWN transaction so one bad child never forces
    // unrelated valid children to reprocess (Phase-3 isolation contract).
    final decoded = <({String serverId, int attempts, Map<String, dynamic> row})>[];
    for (final p in parked) {
      final serverId = p.read<String>('server_id');
      final attempts = p.read<int>('attempt_count');
      try {
        final row = jsonDecode(p.read<String>('row_json')) as Map<String, dynamic>;
        decoded.add((serverId: serverId, attempts: attempts, row: row));
      } catch (_) {
        await _markParkedTerminal(localTable, serverId); // corrupt → terminal
      }
    }
    if (decoded.isEmpty) return;
    final scope = await buildScope([for (final d in decoded) d.row]);
    for (final d in decoded) {
      try {
        await _db.transaction(() async {
          final outcome = await apply(d.row, scope);
          if (outcome == _ChildApplyOutcome.missingParent) {
            if (d.attempts + 1 >= _kParkedChildMaxAttempts) {
              await _markParkedTerminal(localTable, d.serverId);
            } else {
              await _bumpParked(localTable, d.serverId, d.attempts + 1);
            }
          } else {
            await _unparkChild(localTable, d.serverId);
          }
        });
      } catch (error) {
        if (kDebugMode) debugPrint('[PlanningChildSync] drain apply: $error');
      }
    }
  }

  Future<void> _parkChild(String localTable, Map<String, dynamic> row) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    final json = jsonEncode(row);
    // Preserve first_seen_at + attempt_count on re-park (ON CONFLICT).
    await _db.customStatement('''
      INSERT INTO parked_child_rows(
        table_name, server_id, row_json, reason, attempt_count,
        first_seen_at, updated_at
      ) VALUES (
        ${sqlString(localTable)}, ${sqlString(row['id'] as String)},
        ${sqlString(json)}, 'missing_parent', 0,
        ${sqlString(now)}, ${sqlString(now)}
      ) ON CONFLICT(table_name, server_id) DO UPDATE SET
        row_json = excluded.row_json, updated_at = excluded.updated_at;
    ''');
  }

  Future<void> _unparkChild(String localTable, String serverId) async {
    await _db.customStatement(
      'DELETE FROM parked_child_rows WHERE table_name = ${sqlString(localTable)} '
      'AND server_id = ${sqlString(serverId)};',
    );
  }

  Future<void> _bumpParked(
    String localTable,
    String serverId,
    int attempts,
  ) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _db.customStatement(
      'UPDATE parked_child_rows SET attempt_count = $attempts, '
      'updated_at = ${sqlString(now)} WHERE table_name = ${sqlString(localTable)} '
      'AND server_id = ${sqlString(serverId)};',
    );
  }

  Future<void> _markParkedTerminal(String localTable, String serverId) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _db.customStatement(
      "UPDATE parked_child_rows SET reason = 'terminal', "
      'updated_at = ${sqlString(now)} WHERE table_name = ${sqlString(localTable)} '
      'AND server_id = ${sqlString(serverId)};',
    );
  }

  Future<_ChildApplyOutcome> _pullGoalContribution(
    Map<String, dynamic> row,
    _ChildResolveScope scope,
  ) async {
    final goalServerId = row['goal_id'] as String?;
    final goalLocal = scope.parentLocalId('goals', goalServerId);
    if (goalLocal == null) return _ChildApplyOutcome.missingParent;
    // §10: the parent goal must be locally CANONICAL (carry a currency) before a
    // contribution can be canonicalized. If not, park as missing-parent — never
    // invent a currency, never fall back to base.
    final currency = scope.parentCurrency(goalServerId);
    if (currency == null) return _ChildApplyOutcome.missingParent;
    final localId = scope.childLocalId(
      row['id'] as String,
      row['local_id'] as String?,
    );
    if (await _preservePendingWithStatus(
        'goal_contributions', localId, scope.childStatus(localId))) {
      return _ChildApplyOutcome.preservedPending;
    }
    // §9: parse the ::text amount EXACTLY with the parent goal's currency, then
    // write amount_minor authority + the REAL shadow derived from Money.
    final amount = moneyFromPulledValueRequired(row['amount_text'], currency);
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _db.customStatement('''
      INSERT INTO goal_contributions(
        id, goal_id, amount, amount_minor, created_at, note, server_id,
        synced_at, server_updated_at, sync_status, deleted_at
      ) VALUES (
        ${sqlString(localId)}, ${sqlString(goalLocal)},
        ${kMoneyCodec.sqlRealLiteral(amount)},
        ${kMoneyCodec.sqlMinorLiteral(amount)},
        ${sqlString(row['created_at'] as String)},
        ${sqlNullableString(row['note'] as String?)},
        ${sqlString(row['id'] as String)}, ${sqlString(now)},
        ${sqlNullableString(row['updated_at'] as String?)}, 'synced',
        ${sqlNullableString(row['deleted_at'] as String?)}
      ) ON CONFLICT(id) DO UPDATE SET
        goal_id=excluded.goal_id, amount=excluded.amount,
        amount_minor=excluded.amount_minor,
        created_at=excluded.created_at, note=excluded.note,
        server_id=excluded.server_id, synced_at=excluded.synced_at,
        server_updated_at=excluded.server_updated_at,
        sync_status='synced', deleted_at=excluded.deleted_at;
    ''');
    scope.rememberChild(row['id'] as String, localId);
    return _ChildApplyOutcome.applied;
  }

  Future<_ChildApplyOutcome> _pullBillPayment(
    Map<String, dynamic> row,
    _ChildResolveScope scope,
  ) async {
    final billLocal =
        scope.parentLocalId('subscriptions', row['subscription_id'] as String?);
    if (billLocal == null) return _ChildApplyOutcome.missingParent;
    final transactionLocal =
        scope.parentLocalId('transactions', row['transaction_id'] as String?);
    if (row['transaction_id'] != null && transactionLocal == null) {
      return _ChildApplyOutcome.missingParent;
    }
    final localId = scope.childLocalId(
      row['id'] as String,
      row['local_id'] as String?,
    );
    if (await _preservePendingWithStatus(
        'bill_payments', localId, scope.childStatus(localId))) {
      return _ChildApplyOutcome.preservedPending;
    }
    final now = dateTimeToSql(DateTime.now().toUtc());
    final currency = row['currency'];
    if (currency is! String) {
      throw const MoneyTransportException(
          'bill-payment pull requires a String currency');
    }
    final amountMoney =
        moneyFromPulledValueRequired(row['amount_text'], currency);
    await writePulledBillPayment(
      db: _db,
      row: row,
      localId: localId,
      billLocalId: billLocal,
      transactionLocalId: transactionLocal,
      amountMoney: amountMoney,
      now: now,
    );
    scope.rememberChild(row['id'] as String, localId);
    return _ChildApplyOutcome.applied;
  }

  Future<_ChildApplyOutcome> _pullPlanLink(
    Map<String, dynamic> row,
    _ChildResolveScope scope,
  ) async {
    final planLocal = scope.parentLocalId('plans', row['plan_id'] as String?);
    final transactionLocal =
        scope.parentLocalId('transactions', row['transaction_id'] as String?);
    if (planLocal == null || transactionLocal == null) {
      return _ChildApplyOutcome.missingParent;
    }
    if (scope.planLinkStatus(planLocal, transactionLocal) == 'pending') {
      await _db.customStatement('''
        UPDATE plan_transaction_links SET sync_status = 'conflict'
        WHERE plan_id = ${sqlString(planLocal)}
          AND transaction_id = ${sqlString(transactionLocal)};
      ''');
      return _ChildApplyOutcome.preservedPending;
    }
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _db.customStatement('''
      INSERT INTO plan_transaction_links(
        plan_id, transaction_id, created_at, server_id, synced_at,
        server_updated_at, sync_status, deleted_at
      ) VALUES (
        ${sqlString(planLocal)}, ${sqlString(transactionLocal)},
        ${sqlString(row['created_at'] as String)},
        ${sqlString(row['id'] as String)}, ${sqlString(now)},
        ${sqlNullableString(row['updated_at'] as String?)}, 'synced',
        ${sqlNullableString(row['deleted_at'] as String?)}
      ) ON CONFLICT(plan_id, transaction_id) DO UPDATE SET
        server_id=excluded.server_id, synced_at=excluded.synced_at,
        server_updated_at=excluded.server_updated_at,
        sync_status='synced', deleted_at=excluded.deleted_at;
    ''');
    return _ChildApplyOutcome.applied;
  }

  /// [status] is the child row's prefetched sync_status (MALI-029) — resolved
  /// from the batch scope instead of a per-row SELECT. A local pending edit is
  /// preserved (and flagged conflict) exactly as before; a null/unknown status
  /// (the common brand-new-child case) proceeds to the upsert.
  Future<bool> _preservePendingWithStatus(
    String table,
    String localId,
    String? status,
  ) async {
    if (status == 'conflict') return true;
    if (status != 'pending') return false;
    await _db.customStatement(
      "UPDATE $table SET sync_status = 'conflict' WHERE id = ${sqlString(localId)};",
    );
    return true;
  }

  Future<String?> _serverId(String table, String? localId) async {
    if (localId == null) return null;
    final row = await _db
        .customSelect(
          'SELECT server_id FROM $table WHERE id = ${sqlString(localId)} LIMIT 1;',
        )
        .getSingleOrNull();
    return row?.readNullable<String>('server_id');
  }

  // ── MALI-029 batch parent/child resolution ────────────────────────────────
  // Each scope builder resolves one child batch's parent local ids + child
  // identity/pending status in a handful of bounded lookups (central chunk
  // primitive). Built fresh per batch — never an instance/static field — so a
  // sign-out/relogin under a new admission generation always resolves against
  // freshly-committed local state.

  Future<Map<String, String>> _prefetchParentLocals(
    String parentTable,
    Iterable<String?> serverIds,
  ) async {
    final ids = <String>{
      for (final s in serverIds)
        if (s != null && s.isNotEmpty) s,
    };
    final map = <String, String>{};
    for (final r in await selectByIdChunks(_db, ids,
        sql: (ph) =>
            'SELECT server_id, id FROM $parentTable WHERE server_id IN ($ph);')) {
      map[r.read<String>('server_id')] = r.read<String>('id');
    }
    return map;
  }

  Future<_ChildIndex> _prefetchChildIndex(
    String childTable,
    List<Map<String, dynamic>> rows,
  ) async {
    final serverIds = <String>{};
    final localCandidates = <String>{};
    for (final row in rows) {
      final sid = row['id'] as String?;
      if (sid != null) {
        serverIds.add(sid);
        localCandidates.add(sid); // serverId is _childLocalId's final fallback
      }
      final lid = row['local_id'] as String?;
      if (lid != null && lid.isNotEmpty) localCandidates.add(lid);
    }
    final index = _ChildIndex();
    const cols = 'SELECT id, server_id, sync_status FROM';
    for (final r in await selectByIdChunks(_db, serverIds,
        sql: (ph) => '$cols $childTable WHERE server_id IN ($ph);')) {
      index.addExisting(r.read<String>('id'), r.readNullable<String>('server_id'),
          r.readNullable<String>('sync_status'));
    }
    for (final r in await selectByIdChunks(_db, localCandidates,
        sql: (ph) => '$cols $childTable WHERE id IN ($ph);')) {
      index.addExisting(r.read<String>('id'), r.readNullable<String>('server_id'),
          r.readNullable<String>('sync_status'));
    }
    return index;
  }

  Future<_ChildResolveScope> _scopeForGoalContributions(
    List<Map<String, dynamic>> rows,
  ) async {
    final goals = await _prefetchParentLocals(
        'goals', rows.map((r) => r['goal_id'] as String?));
    // §10: batch the parent goals' canonical currencies once (no N+1). Only
    // goals that carry a non-null canonical currency locally are eligible
    // parents; a contribution whose parent lacks one parks until it does.
    final goalCurrencies = await _prefetchParentGoalCurrencies(
        rows.map((r) => r['goal_id'] as String?));
    final child = await _prefetchChildIndex('goal_contributions', rows);
    return _ChildResolveScope(
      parentLocalByServer: {'goals': goals},
      parentCurrencyByServer: goalCurrencies,
      child: child,
    );
  }

  /// §10: parent-goal serverId → canonical local currency, in one bounded lookup.
  /// Goals whose local `currency` is NULL (not yet canonical) are omitted, so a
  /// contribution referencing them parks instead of inventing a currency.
  Future<Map<String, String>> _prefetchParentGoalCurrencies(
    Iterable<String?> serverGoalIds,
  ) async {
    final ids = <String>{
      for (final s in serverGoalIds)
        if (s != null && s.isNotEmpty) s,
    };
    final map = <String, String>{};
    for (final r in await selectByIdChunks(_db, ids,
        sql: (ph) => 'SELECT server_id, currency FROM goals '
            'WHERE server_id IN ($ph) AND currency IS NOT NULL;')) {
      map[r.read<String>('server_id')] = r.read<String>('currency');
    }
    return map;
  }

  Future<_ChildResolveScope> _scopeForBillPayments(
    List<Map<String, dynamic>> rows,
  ) async {
    final subs = await _prefetchParentLocals(
        'subscriptions', rows.map((r) => r['subscription_id'] as String?));
    final txns = await _prefetchParentLocals(
        'transactions', rows.map((r) => r['transaction_id'] as String?));
    final child = await _prefetchChildIndex('bill_payments', rows);
    return _ChildResolveScope(
      parentLocalByServer: {'subscriptions': subs, 'transactions': txns},
      child: child,
    );
  }

  Future<_ChildResolveScope> _scopeForPlanLinks(
    List<Map<String, dynamic>> rows,
  ) async {
    final plans = await _prefetchParentLocals(
        'plans', rows.map((r) => r['plan_id'] as String?));
    final txns = await _prefetchParentLocals(
        'transactions', rows.map((r) => r['transaction_id'] as String?));
    // Plan links key their pending check by the resolved (plan_id,
    // transaction_id) LOCAL pair, so prefetch existing links by transaction
    // local id (few links per transaction) and index them by the pair.
    final txnLocals = <String>{};
    for (final row in rows) {
      final planLocal = plans[row['plan_id'] as String?];
      final txnLocal = txns[row['transaction_id'] as String?];
      if (planLocal != null && txnLocal != null) txnLocals.add(txnLocal);
    }
    final planLinkStatus = <String, String?>{};
    for (final r in await selectByIdChunks(_db, txnLocals,
        sql: (ph) => 'SELECT plan_id, transaction_id, sync_status '
            'FROM plan_transaction_links WHERE transaction_id IN ($ph);')) {
      planLinkStatus['${r.read<String>('plan_id')}|'
          '${r.read<String>('transaction_id')}'] =
          r.readNullable<String>('sync_status');
    }
    return _ChildResolveScope(
      parentLocalByServer: {'plans': plans, 'transactions': txns},
      child: _ChildIndex(),
      planLinkStatusByPair: planLinkStatus,
    );
  }

  Future<void> _markChildSynced(
    String table,
    String localId,
    Map<String, dynamic> row,
  ) async {
    await _db.customStatement('''
      UPDATE $table SET server_id = ${sqlString(row['id'] as String)},
        synced_at = ${sqlString(dateTimeToSql(DateTime.now().toUtc()))},
        server_updated_at = ${sqlNullableString(row['updated_at'] as String?)},
        sync_status = 'synced',
        deleted_at = ${sqlNullableString(row['deleted_at'] as String?)}
      WHERE id = ${sqlString(localId)};
    ''');
  }

  Future<void> _updateSubscriptionCounter(Map<String, dynamic> row) async {
    final serverId = row['id'] as String;
    final local = await _db.customSelect(
      'SELECT currency FROM subscriptions WHERE server_id = ? LIMIT 1;',
      variables: [Variable.withString(serverId)],
    ).getSingleOrNull();
    if (local == null) return;
    final currency = local.read<String>('currency');
    final rawManualPaid =
        row['manual_paid_amount_text'] ?? row['manual_paid_amount'];
    final manualPaidMoney = switch (rawManualPaid) {
      null => null,
      final String value => moneyFromPulledValue(value, currency),
      final num value => legacyLossyNumberToMoney(value, currency),
      _ => throw MoneyTransportException(
          'unsupported RPC manual_paid_amount type: '
          '${rawManualPaid.runtimeType}'),
    };
    await writePulledSubscriptionCounter(
      db: _db,
      serverId: serverId,
      paidCount: (row['paid_count'] as num?)?.toInt(),
      manualPaidMoney: manualPaidMoney,
      serverUpdatedAt: row['updated_at'] as String?,
    );
  }

  Future<void> _markPlanLinkSynced(
    String planId,
    String transactionId,
    String? serverId, {
    String? serverUpdatedAt,
  }) async {
    await _db.customStatement('''
      UPDATE plan_transaction_links SET
        server_id = ${sqlNullableString(serverId)},
        synced_at = ${sqlString(dateTimeToSql(DateTime.now().toUtc()))},
        server_updated_at = ${sqlNullableString(serverUpdatedAt)},
        sync_status = 'synced'
      WHERE plan_id = ${sqlString(planId)}
        AND transaction_id = ${sqlString(transactionId)};
    ''');
  }
}

typedef _ChildApply = Future<_ChildApplyOutcome> Function(
  Map<String, dynamic> row,
  _ChildResolveScope scope,
);

typedef _ChildScopeBuilder = Future<_ChildResolveScope> Function(
  List<Map<String, dynamic>> rows,
);

/// One child batch's prefetched resolution: parent local ids (per parent table),
/// child identity + pending status, and — for plan links — pending status keyed
/// by the resolved (plan_id, transaction_id) local pair.
class _ChildResolveScope {
  _ChildResolveScope({
    required Map<String, Map<String, String>> parentLocalByServer,
    required _ChildIndex child,
    Map<String, String?> planLinkStatusByPair = const {},
    Map<String, String> parentCurrencyByServer = const {},
  })  : _parent = parentLocalByServer,
        _child = child,
        _planLinkStatus = planLinkStatusByPair,
        _parentCurrency = parentCurrencyByServer;

  final Map<String, Map<String, String>> _parent;
  final _ChildIndex _child;
  final Map<String, String?> _planLinkStatus;
  // MALI-026 (B8-3 §10): parent-goal serverId → its canonical local currency,
  // prefetched once per page (no N+1). A contribution inherits this currency; a
  // parent absent here is not yet canonical → the child parks (never a base
  // fallback, never an invented currency).
  final Map<String, String> _parentCurrency;

  /// Local id of a parent by its server id — null when the parent hasn't synced
  /// yet (→ the child is durably parked), exactly like the old `_localId`.
  String? parentLocalId(String table, String? serverId) {
    if (serverId == null || serverId.isEmpty) return null;
    return _parent[table]?[serverId];
  }

  /// Canonical currency of a parent goal by its server id — null when the parent
  /// goal isn't locally canonical yet (→ the child contribution parks).
  String? parentCurrency(String? serverId) {
    if (serverId == null || serverId.isEmpty) return null;
    return _parentCurrency[serverId];
  }

  String childLocalId(String serverId, String? preferred) =>
      _child.localId(serverId, preferred);

  String? childStatus(String localId) => _child.status(localId);

  void rememberChild(String serverId, String localId) =>
      _child.remember(serverId, localId);

  String? planLinkStatus(String planLocal, String txnLocal) =>
      _planLinkStatus['$planLocal|$txnLocal'];
}

/// Child-table identity: server_id → existing local id, and local id →
/// sync_status. `localId` mirrors the old `_childLocalId` (server match, else the
/// preferred local_id, else the server id as the local id).
class _ChildIndex {
  final Map<String, String> _idByServer = {};
  final Map<String, String?> _statusById = {};

  void addExisting(String id, String? serverId, String? status) {
    _statusById[id] = status;
    if (serverId != null) _idByServer.putIfAbsent(serverId, () => id);
  }

  String localId(String serverId, String? preferred) {
    final byServer = _idByServer[serverId];
    if (byServer != null) return byServer;
    if (preferred != null && preferred.isNotEmpty) return preferred;
    return serverId;
  }

  String? status(String localId) => _statusById[localId];

  /// After a successful upsert the child row exists as `synced`; keep the index
  /// consistent for any later same-batch row that resolves to it.
  void remember(String serverId, String localId) {
    _idByServer[serverId] = localId;
    _statusById[localId] = 'synced';
  }
}
