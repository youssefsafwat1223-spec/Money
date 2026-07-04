import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/sql_value_codec.dart';
import 'planning_outbox_queue.dart';

class PlanningPushResult {
  const PlanningPushResult({
    this.pushed = 0,
    this.conflicts = 0,
    this.failed = 0,
    this.abandoned = 0,
  });

  final int pushed;
  final int conflicts;
  final int failed;
  final int abandoned;
}

abstract class PlanningRemoteSink {
  Future<Map<String, dynamic>> upsert(
    String table,
    Map<String, dynamic> row,
  );

  Future<Map<String, dynamic>?> findByLocalId(
    String table,
    String userId,
    String localId,
  );

  Future<void> tombstone(String table, String serverId);
}

class SupabasePlanningRemoteSink implements PlanningRemoteSink {
  const SupabasePlanningRemoteSink();

  SupabaseClient get _client => Supabase.instance.client;

  @override
  Future<Map<String, dynamic>?> findByLocalId(
    String table,
    String userId,
    String localId,
  ) async {
    return await _client
        .from(table)
        .select('id, updated_at')
        .eq('user_id', userId)
        .eq('local_id', localId)
        .maybeSingle();
  }

  @override
  Future<void> tombstone(String table, String serverId) async {
    await _client.from(table).update({
      'deleted_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', serverId);
  }

  @override
  Future<Map<String, dynamic>> upsert(
    String table,
    Map<String, dynamic> row,
  ) async {
    return await _client
        .from(table)
        .upsert(row, onConflict: 'user_id,local_id')
        .select('id, updated_at')
        .single();
  }
}

class PlanningPushService {
  PlanningPushService({
    required AppDatabase db,
    required PlanningOutboxQueue queue,
    required bool Function(String entityType) isEnabled,
    Future<String?> Function()? getAuthUserId,
    PlanningRemoteSink? remoteSink,
  })  : _db = db,
        _queue = queue,
        _isEnabled = isEnabled,
        _getAuthUserId = getAuthUserId ?? _defaultGetAuthUserId,
        _remoteSink = remoteSink ?? const SupabasePlanningRemoteSink();

  final AppDatabase _db;
  final PlanningOutboxQueue _queue;
  final bool Function(String entityType) _isEnabled;
  final Future<String?> Function() _getAuthUserId;
  final PlanningRemoteSink _remoteSink;

  static const _entityTable = {
    PlanningOutboxQueue.budgetsEntityType: 'user_budgets',
    PlanningOutboxQueue.subscriptionsEntityType: 'user_subscriptions',
    PlanningOutboxQueue.goalsEntityType: 'user_goals',
    PlanningOutboxQueue.plansEntityType: 'user_plans',
  };

  static const _localTable = {
    PlanningOutboxQueue.budgetsEntityType: 'budgets',
    PlanningOutboxQueue.subscriptionsEntityType: 'subscriptions',
    PlanningOutboxQueue.goalsEntityType: 'goals',
    PlanningOutboxQueue.plansEntityType: 'plans',
  };

  static Future<String?> _defaultGetAuthUserId() async {
    if (!SupabaseConfig.isConfigured) return null;
    try {
      return Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  Future<PlanningPushResult> push() async {
    final userId = await _getAuthUserId();
    if (userId == null) return const PlanningPushResult();

    var pushed = 0;
    var conflicts = 0;
    var failed = 0;
    var abandoned = 0;

    for (final entityType in _entityTable.keys) {
      if (!_isEnabled(entityType)) continue;
      final items = await _queue.pendingItems(entityType: entityType);
      for (final item in items) {
        if (item.attemptCount >= 5) {
          abandoned++;
          await _queue.markSuccess(item.id);
          continue;
        }
        try {
          final outcome = await _process(item, userId);
          switch (outcome) {
            case _PlanningPushOutcome.pushed:
              pushed++;
            case _PlanningPushOutcome.conflict:
              conflicts++;
            case _PlanningPushOutcome.abandoned:
              abandoned++;
          }
        } catch (e) {
          failed++;
          await _queue.markFailed(item.id, e.toString());
          if (kDebugMode) debugPrint('[PlanningPush] item error: $e');
        }
      }
    }

    if (kDebugMode) {
      debugPrint(
        '[PlanningPush] done: pushed=$pushed conflicts=$conflicts '
        'failed=$failed abandoned=$abandoned',
      );
    }
    return PlanningPushResult(
      pushed: pushed,
      conflicts: conflicts,
      failed: failed,
      abandoned: abandoned,
    );
  }

  Future<_PlanningPushOutcome> _process(
    PlanningOutboxItem item,
    String userId,
  ) async {
    final remoteTable = _entityTable[item.entityType];
    final localTable = _localTable[item.entityType];
    if (remoteTable == null || localTable == null) {
      await _queue.markSuccess(item.id);
      return _PlanningPushOutcome.abandoned;
    }

    switch (item.operation) {
      case PlanningSyncOperation.create:
      case PlanningSyncOperation.update:
        return _pushUpsert(item, userId, remoteTable, localTable);
      case PlanningSyncOperation.delete:
        return _pushDelete(item, userId, remoteTable, localTable);
    }
  }

  Future<_PlanningPushOutcome> _pushUpsert(
    PlanningOutboxItem item,
    String userId,
    String remoteTable,
    String localTable,
  ) async {
    try {
      final response = await _remoteSink.upsert(
        remoteTable,
        _toServerRow(item.entityType, item.payloadJson, userId),
      );
      await _attachServerId(
        localTable,
        item.entityId,
        response['id'] as String,
        response['updated_at'] as String?,
      );
      await _queue.markSuccess(item.id);
      return _PlanningPushOutcome.pushed;
    } catch (e) {
      if (_isConflict(e)) {
        await _markConflict(localTable, item.entityId);
        await _queue.markSuccess(item.id);
        return _PlanningPushOutcome.conflict;
      }
      rethrow;
    }
  }

  Future<_PlanningPushOutcome> _pushDelete(
    PlanningOutboxItem item,
    String userId,
    String remoteTable,
    String localTable,
  ) async {
    var serverId = await _serverIdForLocal(localTable, item.entityId);
    serverId ??= (await _remoteSink.findByLocalId(
      remoteTable,
      userId,
      item.entityId,
    ))?['id'] as String?;
    if (serverId != null) {
      await _remoteSink.tombstone(remoteTable, serverId);
    }
    await _markSynced(localTable, item.entityId, serverId);
    await _queue.markSuccess(item.id);
    return _PlanningPushOutcome.pushed;
  }

  Future<String?> _serverIdForLocal(String table, String localId) async {
    final row = await _db
        .customSelect(
          'SELECT server_id FROM $table WHERE id = ${sqlString(localId)} LIMIT 1;',
        )
        .getSingleOrNull();
    return row?.readNullable<String>('server_id');
  }

  Future<void> _attachServerId(
    String table,
    String localId,
    String serverId,
    String? serverUpdatedAt,
  ) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _db.customStatement('''
      UPDATE $table
      SET server_id = ${sqlString(serverId)},
          synced_at = ${sqlString(now)},
          server_updated_at = ${sqlNullableString(serverUpdatedAt)},
          sync_status = 'synced'
      WHERE id = ${sqlString(localId)};
    ''');
  }

  Future<void> _markSynced(
    String table,
    String localId,
    String? serverId,
  ) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _db.customStatement('''
      UPDATE $table
      SET ${serverId == null ? '' : 'server_id = ${sqlString(serverId)},'}
          synced_at = ${sqlString(now)},
          sync_status = 'synced'
      WHERE id = ${sqlString(localId)};
    ''');
  }

  Future<void> _markConflict(String table, String localId) async {
    await _db.customStatement('''
      UPDATE $table
      SET sync_status = 'conflict'
      WHERE id = ${sqlString(localId)};
    ''');
  }

  Map<String, dynamic> _toServerRow(
    String entityType,
    Map<String, dynamic> payload,
    String userId,
  ) {
    return switch (entityType) {
      PlanningOutboxQueue.budgetsEntityType => {
          'user_id': userId,
          'local_id': payload['local_id'],
          'local_account_id': payload['local_account_id'],
          'category_id': payload['category_id'],
          'amount': payload['amount'],
          'period': payload['period'],
          'start_date': payload['start_date'],
          'is_active': payload['is_active'] == true,
          'alert_80_sent': payload['alert_80_sent'] == true,
          'alert_100_sent': payload['alert_100_sent'] == true,
          'show_on_header': payload['show_on_header'] == true,
        },
      PlanningOutboxQueue.subscriptionsEntityType => {
          'user_id': userId,
          'local_id': payload['local_id'],
          'local_account_id': payload['local_account_id'],
          'merchant_id': payload['merchant_id'],
          'name': payload['name'],
          'amount': payload['amount'],
          'currency': payload['currency'],
          'type': payload['type'],
          'frequency': payload['frequency'],
          'next_due_date': payload['next_due_date'],
          'reminder_on': payload['reminder_on'] == true,
          'is_confirmed': payload['is_confirmed'] == true,
          'custom_interval_days': payload['custom_interval_days'],
          'note': payload['note'],
          'status': payload['status'],
          'total_installments': payload['total_installments'],
          'paid_count': payload['paid_count'],
          'manual_paid_amount': payload['manual_paid_amount'],
          'total_purchase_amount': payload['total_purchase_amount'],
          'lender_name': payload['lender_name'],
          'interest_rate': payload['interest_rate'],
          'created_at': payload['created_at'],
        },
      PlanningOutboxQueue.goalsEntityType => {
          'user_id': userId,
          'local_id': payload['local_id'],
          'local_account_id': payload['local_account_id'],
          'name': payload['name'],
          'target_amount': payload['target_amount'],
          'saved_amount': payload['saved_amount'],
          'deadline': payload['deadline'],
          'vault_skin': payload['vault_skin'],
          'status': payload['status'],
          'auto_save_amount': payload['auto_save_amount'],
          'auto_save_period': payload['auto_save_period'],
          'auto_save_last_run': payload['auto_save_last_run'],
          'created_at': payload['created_at'],
        },
      PlanningOutboxQueue.plansEntityType => {
          'user_id': userId,
          'local_id': payload['local_id'],
          'name': payload['name'],
          'budget_amount': payload['budget_amount'],
          'currency': payload['currency'],
          'start_date': payload['start_date'],
          'end_date': payload['end_date'],
          'local_account_ids': payload['local_account_ids'] ?? const [],
          'card_last4s': payload['card_last4s'] ?? const [],
          'status': payload['status'],
          'icon': payload['icon'],
          'created_at': payload['created_at'],
        },
      _ => throw ArgumentError('Unsupported planning entity: $entityType'),
    };
  }

  static bool _isConflict(Object e) {
    final msg = e.toString().toLowerCase();
    return msg.contains('409') ||
        msg.contains('conflict') ||
        msg.contains('duplicate');
  }
}

enum _PlanningPushOutcome { pushed, conflict, abandoned }
