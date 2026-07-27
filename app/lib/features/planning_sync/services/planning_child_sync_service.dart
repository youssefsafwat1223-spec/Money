import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/sql_value_codec.dart';
import 'planning_outbox_queue.dart';

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

  Future<List<Map<String, dynamic>>> fetchRows(String table);
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
  Future<List<Map<String, dynamic>>> fetchRows(String table) async {
    final response = await _client
        .from(table)
        .select()
        .order('updated_at', ascending: false)
        .limit(500);
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
    Future<String?> Function()? getAuthUserId,
    PlanningChildRemote? remote,
  })  : _db = db,
        _queue = queue,
        _isEnabled = isEnabled,
        _getAuthUserId = getAuthUserId ?? _defaultUserId,
        _remote = remote ?? const SupabasePlanningChildRemote();

  final AppDatabase _db;
  final PlanningOutboxQueue _queue;
  final bool Function(String entityType) _isEnabled;
  final Future<String?> Function() _getAuthUserId;
  final PlanningChildRemote _remote;

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
      if (!_isEnabled(type)) continue;
      final items = await _queue.pendingItems(entityType: type);
      for (final item in items) {
        try {
          await _pushItem(userId, item);
          await _queue.markSuccess(item.id);
        } catch (error) {
          await _queue.markFailed(item.id, error.toString());
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
    await _db.customStatement('''
      UPDATE goals SET saved_amount = ${(goal['saved_amount'] as num).toDouble()},
        server_updated_at = ${sqlNullableString(goal['updated_at'] as String?)},
        synced_at = ${sqlString(dateTimeToSql(DateTime.now().toUtc()))},
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
    if (_isEnabled(PlanningOutboxQueue.goalContributionsEntityType)) {
      await _pullTable('user_goal_contributions', _pullGoalContribution);
    }
    if (_isEnabled(PlanningOutboxQueue.billPaymentsEntityType)) {
      await _pullTable('user_bill_payments', _pullBillPayment);
    }
    if (_isEnabled(PlanningOutboxQueue.planLinksEntityType)) {
      await _pullTable('user_plan_transaction_links', _pullPlanLink);
    }
  }

  Future<void> _pullTable(
    String table,
    Future<void> Function(Map<String, dynamic>) apply,
  ) async {
    try {
      for (final row in await _remote.fetchRows(table)) {
        await apply(row);
      }
    } catch (error) {
      if (kDebugMode) debugPrint('[PlanningChildSync] pull $table: $error');
    }
  }

  Future<void> _pullGoalContribution(Map<String, dynamic> row) async {
    final goalLocal = await _localId('goals', row['goal_id'] as String?);
    if (goalLocal == null) return;
    final localId = await _childLocalId(
      'goal_contributions',
      row['id'] as String,
      row['local_id'] as String?,
    );
    if (await _preservePending('goal_contributions', localId)) return;
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _db.customStatement('''
      INSERT INTO goal_contributions(
        id, goal_id, amount, created_at, note, server_id, synced_at,
        server_updated_at, sync_status, deleted_at
      ) VALUES (
        ${sqlString(localId)}, ${sqlString(goalLocal)},
        ${(row['amount'] as num).toDouble()},
        ${sqlString(row['created_at'] as String)},
        ${sqlNullableString(row['note'] as String?)},
        ${sqlString(row['id'] as String)}, ${sqlString(now)},
        ${sqlNullableString(row['updated_at'] as String?)}, 'synced',
        ${sqlNullableString(row['deleted_at'] as String?)}
      ) ON CONFLICT(id) DO UPDATE SET
        goal_id=excluded.goal_id, amount=excluded.amount,
        created_at=excluded.created_at, note=excluded.note,
        server_id=excluded.server_id, synced_at=excluded.synced_at,
        server_updated_at=excluded.server_updated_at,
        sync_status='synced', deleted_at=excluded.deleted_at;
    ''');
  }

  Future<void> _pullBillPayment(Map<String, dynamic> row) async {
    final billLocal =
        await _localId('subscriptions', row['subscription_id'] as String?);
    if (billLocal == null) return;
    final transactionLocal =
        await _localId('transactions', row['transaction_id'] as String?);
    if (row['transaction_id'] != null && transactionLocal == null) return;
    final localId = await _childLocalId(
      'bill_payments',
      row['id'] as String,
      row['local_id'] as String?,
    );
    if (await _preservePending('bill_payments', localId)) return;
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _db.customStatement('''
      INSERT INTO bill_payments(
        id, bill_id, amount, currency, period_start, period_end, paid_at,
        installment_index, transaction_id, note, server_id, synced_at,
        server_updated_at, sync_status, deleted_at
      ) VALUES (
        ${sqlString(localId)}, ${sqlString(billLocal)},
        ${(row['amount'] as num).toDouble()},
        ${sqlString(row['currency'] as String)},
        ${sqlString(row['period_start'] as String)},
        ${sqlString(row['period_end'] as String)},
        ${sqlString(row['paid_at'] as String)},
        ${sqlNullableNum(row['installment_index'] as num?)},
        ${sqlNullableString(transactionLocal)},
        ${sqlNullableString(row['note'] as String?)},
        ${sqlString(row['id'] as String)}, ${sqlString(now)},
        ${sqlNullableString(row['updated_at'] as String?)}, 'synced',
        ${sqlNullableString(row['deleted_at'] as String?)}
      ) ON CONFLICT(id) DO UPDATE SET
        bill_id=excluded.bill_id, amount=excluded.amount,
        currency=excluded.currency, period_start=excluded.period_start,
        period_end=excluded.period_end, paid_at=excluded.paid_at,
        installment_index=excluded.installment_index,
        transaction_id=excluded.transaction_id, note=excluded.note,
        server_id=excluded.server_id, synced_at=excluded.synced_at,
        server_updated_at=excluded.server_updated_at,
        sync_status='synced', deleted_at=excluded.deleted_at;
    ''');
  }

  Future<void> _pullPlanLink(Map<String, dynamic> row) async {
    final planLocal = await _localId('plans', row['plan_id'] as String?);
    final transactionLocal =
        await _localId('transactions', row['transaction_id'] as String?);
    if (planLocal == null || transactionLocal == null) return;
    final status = await _db.customSelect('''
      SELECT sync_status FROM plan_transaction_links
      WHERE plan_id = ${sqlString(planLocal)}
        AND transaction_id = ${sqlString(transactionLocal)} LIMIT 1;
    ''').getSingleOrNull();
    if (status?.readNullable<String>('sync_status') == 'pending') {
      await _db.customStatement('''
        UPDATE plan_transaction_links SET sync_status = 'conflict'
        WHERE plan_id = ${sqlString(planLocal)}
          AND transaction_id = ${sqlString(transactionLocal)};
      ''');
      return;
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
  }

  Future<bool> _preservePending(String table, String localId) async {
    final row = await _db
        .customSelect(
          'SELECT sync_status FROM $table WHERE id = ${sqlString(localId)} LIMIT 1;',
        )
        .getSingleOrNull();
    final status = row?.readNullable<String>('sync_status');
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

  Future<String?> _localId(String table, String? serverId) async {
    if (serverId == null) return null;
    final row = await _db
        .customSelect(
          'SELECT id FROM $table WHERE server_id = ${sqlString(serverId)} LIMIT 1;',
        )
        .getSingleOrNull();
    return row?.readNullable<String>('id');
  }

  Future<String> _childLocalId(
    String table,
    String serverId,
    String? preferred,
  ) async {
    final byServer = await _localId(table, serverId);
    if (byServer != null) return byServer;
    if (preferred != null && preferred.isNotEmpty) return preferred;
    return serverId;
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
    await _db.customStatement('''
      UPDATE subscriptions
      SET paid_count = ${sqlNullableNum(row['paid_count'] as num?)},
          manual_paid_amount = ${sqlNullableNum(row['manual_paid_amount'] as num?)},
          synced_at = ${sqlString(dateTimeToSql(DateTime.now().toUtc()))},
          server_updated_at = ${sqlNullableString(row['updated_at'] as String?)},
          sync_status = 'synced'
      WHERE server_id = ${sqlString(row['id'] as String)};
    ''');
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
