import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../core/utils/id_generator.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/sql_value_codec.dart';
import 'planning_outbox_queue.dart';

class PlanningPullResult {
  const PlanningPullResult({
    this.imported = 0,
    this.updated = 0,
    this.conflicts = 0,
    this.tombstoned = 0,
  });

  final int imported;
  final int updated;
  final int conflicts;
  final int tombstoned;
}

abstract class PlanningRemoteSource {
  Future<List<Map<String, dynamic>>> fetchActiveRows(
    String table, {
    int limit,
  });

  Future<List<Map<String, dynamic>>> fetchTombstones(
    String table, {
    int limit,
  });
}

class SupabasePlanningRemoteSource implements PlanningRemoteSource {
  const SupabasePlanningRemoteSource();

  SupabaseClient get _client => Supabase.instance.client;

  @override
  Future<List<Map<String, dynamic>>> fetchActiveRows(
    String table, {
    int limit = 200,
  }) async {
    final response = await _client
        .from(table)
        .select()
        .order('updated_at', ascending: false)
        .limit(limit);
    return (response as List)
        .cast<Map<String, dynamic>>()
        .where((row) => row['deleted_at'] == null)
        .toList();
  }

  @override
  Future<List<Map<String, dynamic>>> fetchTombstones(
    String table, {
    int limit = 200,
  }) async {
    final response = await _client
        .from(table)
        .select('id, local_id, deleted_at, updated_at')
        .order('updated_at', ascending: false)
        .limit(limit);
    return (response as List)
        .cast<Map<String, dynamic>>()
        .where((row) => row['deleted_at'] != null)
        .toList();
  }
}

class PlanningPullService {
  PlanningPullService({
    required AppDatabase db,
    required bool Function(String entityType) isEnabled,
    Future<String?> Function()? getAuthUserId,
    PlanningRemoteSource? remoteSource,
  })  : _db = db,
        _isEnabled = isEnabled,
        _getAuthUserId = getAuthUserId ?? _defaultGetAuthUserId,
        _remoteSource = remoteSource ?? const SupabasePlanningRemoteSource();

  final AppDatabase _db;
  final bool Function(String entityType) _isEnabled;
  final Future<String?> Function() _getAuthUserId;
  final PlanningRemoteSource _remoteSource;

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

  Future<PlanningPullResult> pull() async {
    final userId = await _getAuthUserId();
    if (userId == null) return const PlanningPullResult();

    var imported = 0;
    var updated = 0;
    var conflicts = 0;
    var tombstoned = 0;

    for (final entry in _entityTable.entries) {
      final entityType = entry.key;
      final remoteTable = entry.value;
      if (!_isEnabled(entityType)) continue;

      try {
        final rows = await _remoteSource.fetchActiveRows(remoteTable);
        for (final row in rows) {
          final outcome = await _processRow(entityType, row);
          switch (outcome) {
            case _PlanningPullOutcome.imported:
              imported++;
            case _PlanningPullOutcome.updated:
              updated++;
            case _PlanningPullOutcome.conflict:
              conflicts++;
            case _PlanningPullOutcome.skipped:
              break;
          }
        }
      } catch (e) {
        if (kDebugMode) debugPrint('[PlanningPull] $entityType fetch: $e');
      }

      try {
        final rows = await _remoteSource.fetchTombstones(remoteTable);
        for (final row in rows) {
          if (await _processTombstone(entityType, row)) tombstoned++;
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[PlanningPull] $entityType tombstones: $e');
        }
      }
    }

    if (kDebugMode) {
      debugPrint(
        '[PlanningPull] done: imported=$imported updated=$updated '
        'conflicts=$conflicts tombstoned=$tombstoned',
      );
    }
    return PlanningPullResult(
      imported: imported,
      updated: updated,
      conflicts: conflicts,
      tombstoned: tombstoned,
    );
  }

  Future<_PlanningPullOutcome> _processRow(
    String entityType,
    Map<String, dynamic> row,
  ) async {
    final serverId = row['id'] as String?;
    final localTable = _localTable[entityType];
    if (serverId == null || localTable == null) {
      return _PlanningPullOutcome.skipped;
    }

    final localId = await _findLocalId(
      localTable,
      serverId,
      row['local_id'] as String?,
    );
    if (localId != null) {
      final status = await _syncStatus(localTable, localId);
      if (status == null) return _PlanningPullOutcome.skipped;
      if (status == 'conflict') return _PlanningPullOutcome.conflict;
      if (status == 'pending') {
        await _markConflict(localTable, localId);
        return _PlanningPullOutcome.conflict;
      }
      await _updateLocal(entityType, localTable, localId, row);
      return _PlanningPullOutcome.updated;
    }

    await _insertLocal(entityType, row);
    return _PlanningPullOutcome.imported;
  }

  Future<bool> _processTombstone(
    String entityType,
    Map<String, dynamic> row,
  ) async {
    final serverId = row['id'] as String?;
    final localTable = _localTable[entityType];
    if (serverId == null || localTable == null) return false;
    final localId = await _findLocalId(
      localTable,
      serverId,
      row['local_id'] as String?,
    );
    if (localId == null) return false;

    final status = await _syncStatus(localTable, localId);
    if (status == 'conflict') return false;
    if (status == 'pending') {
      await _markConflict(localTable, localId);
      return false;
    }

    final now = dateTimeToSql(DateTime.now().toUtc());
    final deletedAt = _dateString(row['deleted_at']) ?? now;
    await _db.customStatement('''
      UPDATE $localTable
      SET deleted_at = ${sqlString(deletedAt)},
          server_id = ${sqlString(serverId)},
          server_updated_at = ${sqlNullableString(_dateString(row['updated_at']))},
          synced_at = ${sqlString(now)},
          sync_status = 'synced'
      WHERE id = ${sqlString(localId)};
    ''');
    return true;
  }

  Future<void> _insertLocal(String entityType, Map<String, dynamic> row) async {
    final id = row['local_id'] as String? ?? IdGenerator.next();
    switch (entityType) {
      case PlanningOutboxQueue.budgetsEntityType:
        await _insertBudget(id, row);
      case PlanningOutboxQueue.subscriptionsEntityType:
        await _insertSubscription(id, row);
      case PlanningOutboxQueue.goalsEntityType:
        await _insertGoal(id, row);
      case PlanningOutboxQueue.plansEntityType:
        await _insertPlan(id, row);
    }
  }

  Future<void> _updateLocal(
    String entityType,
    String table,
    String id,
    Map<String, dynamic> row,
  ) async {
    switch (entityType) {
      case PlanningOutboxQueue.budgetsEntityType:
        await _updateBudget(id, row);
      case PlanningOutboxQueue.subscriptionsEntityType:
        await _updateSubscription(id, row);
      case PlanningOutboxQueue.goalsEntityType:
        await _updateGoal(id, row);
      case PlanningOutboxQueue.plansEntityType:
        await _updatePlan(id, row);
    }
  }

  Future<void> _insertBudget(String id, Map<String, dynamic> row) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _db.customStatement('''
      INSERT OR IGNORE INTO budgets(
        id, category_id, amount, period, start_date, is_active,
        last_notified_spent_amount, last_notified_period_start, show_on_header, account_id,
        server_id, synced_at, server_updated_at, sync_status, deleted_at
      ) VALUES (
        ${sqlString(id)},
        ${sqlString(row['category_id'] as String? ?? '__all_expenses__')},
        ${(row['amount'] as num?)?.toDouble() ?? 0},
        ${sqlString(row['period'] as String? ?? 'monthly')},
        ${sqlString(_dateString(row['start_date']) ?? now)},
        ${row['is_active'] == false ? 0 : 1},
        ${(row['last_notified_spent_amount'] as num?)?.toDouble() ?? 0},
        ${sqlString(row['last_notified_period_start'] as String? ?? '2000-01-01T00:00:00Z')},
        ${row['show_on_header'] == true ? 1 : 0},
        ${sqlNullableString(row['local_account_id'] as String?)},
        ${sqlString(row['id'] as String)},
        ${sqlString(now)},
        ${sqlNullableString(_dateString(row['updated_at']))},
        'synced',
        NULL
      );
    ''');
  }

  Future<void> _updateBudget(String id, Map<String, dynamic> row) async {
    await _db.customStatement('''
      UPDATE budgets
      SET category_id = ${sqlString(row['category_id'] as String? ?? '__all_expenses__')},
          amount = ${(row['amount'] as num?)?.toDouble() ?? 0},
          period = ${sqlString(row['period'] as String? ?? 'monthly')},
          start_date = ${sqlString(_dateString(row['start_date']) ?? dateTimeToSql(DateTime.now().toUtc()))},
          is_active = ${row['is_active'] == false ? 0 : 1},
          last_notified_spent_amount = ${(row['last_notified_spent_amount'] as num?)?.toDouble() ?? 0},
          last_notified_period_start = ${sqlString(row['last_notified_period_start'] as String? ?? '2000-01-01T00:00:00Z')},
          show_on_header = ${row['show_on_header'] == true ? 1 : 0},
          account_id = ${sqlNullableString(row['local_account_id'] as String?)},
          server_id = ${sqlString(row['id'] as String)},
          synced_at = ${sqlString(dateTimeToSql(DateTime.now().toUtc()))},
          server_updated_at = ${sqlNullableString(_dateString(row['updated_at']))},
          sync_status = 'synced',
          deleted_at = NULL
      WHERE id = ${sqlString(id)};
    ''');
  }

  Future<void> _insertSubscription(String id, Map<String, dynamic> row) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    final merchantId = await _ensureMerchant(
        row['merchant_id'] as String?, row['name'] as String? ?? 'فاتورة');
    await _db.customStatement('''
      INSERT OR IGNORE INTO subscriptions(
        id, merchant_id, name, amount, currency, period, frequency, type,
        next_due_date, is_confirmed, reminder_on, custom_interval_days,
        note, created_at, status, account_id, total_installments, paid_count,
        manual_paid_amount, total_purchase_amount, lender_name, interest_rate,
        server_id, synced_at, server_updated_at, sync_status, deleted_at
      ) VALUES (
        ${sqlString(id)}, ${sqlString(merchantId)},
        ${sqlString(row['name'] as String? ?? 'فاتورة')},
        ${(row['amount'] as num?)?.toDouble() ?? 0},
        ${sqlString(row['currency'] as String? ?? 'SAR')},
        ${sqlString(row['frequency'] as String? ?? 'monthly')},
        ${sqlString(row['frequency'] as String? ?? 'monthly')},
        ${sqlString(row['type'] as String? ?? 'subscription')},
        ${sqlString(_dateString(row['next_due_date']) ?? now)},
        ${row['is_confirmed'] == true ? 1 : 0},
        ${row['reminder_on'] == false ? 0 : 1},
        ${sqlNullableNum(row['custom_interval_days'] as num?)},
        ${sqlNullableString(row['note'] as String?)},
        ${sqlString(_dateString(row['created_at']) ?? now)},
        ${sqlString(row['status'] as String? ?? 'active')},
        ${sqlNullableString(row['local_account_id'] as String?)},
        ${sqlNullableNum(row['total_installments'] as num?)},
        ${sqlNullableNum(row['paid_count'] as num?)},
        ${sqlNullableNum(row['manual_paid_amount'] as num?)},
        ${sqlNullableNum(row['total_purchase_amount'] as num?)},
        ${sqlNullableString(row['lender_name'] as String?)},
        ${sqlNullableNum(row['interest_rate'] as num?)},
        ${sqlString(row['id'] as String)},
        ${sqlString(now)},
        ${sqlNullableString(_dateString(row['updated_at']))},
        'synced',
        NULL
      );
    ''');
  }

  Future<void> _updateSubscription(String id, Map<String, dynamic> row) async {
    final merchantId = await _ensureMerchant(
        row['merchant_id'] as String?, row['name'] as String? ?? 'فاتورة');
    await _db.customStatement('''
      UPDATE subscriptions
      SET merchant_id = ${sqlString(merchantId)},
          name = ${sqlString(row['name'] as String? ?? 'فاتورة')},
          amount = ${(row['amount'] as num?)?.toDouble() ?? 0},
          currency = ${sqlString(row['currency'] as String? ?? 'SAR')},
          period = ${sqlString(row['frequency'] as String? ?? 'monthly')},
          frequency = ${sqlString(row['frequency'] as String? ?? 'monthly')},
          type = ${sqlString(row['type'] as String? ?? 'subscription')},
          next_due_date = ${sqlString(_dateString(row['next_due_date']) ?? dateTimeToSql(DateTime.now().toUtc()))},
          is_confirmed = ${row['is_confirmed'] == true ? 1 : 0},
          reminder_on = ${row['reminder_on'] == false ? 0 : 1},
          custom_interval_days = ${sqlNullableNum(row['custom_interval_days'] as num?)},
          note = ${sqlNullableString(row['note'] as String?)},
          status = ${sqlString(row['status'] as String? ?? 'active')},
          account_id = ${sqlNullableString(row['local_account_id'] as String?)},
          total_installments = ${sqlNullableNum(row['total_installments'] as num?)},
          paid_count = ${sqlNullableNum(row['paid_count'] as num?)},
          manual_paid_amount = ${sqlNullableNum(row['manual_paid_amount'] as num?)},
          total_purchase_amount = ${sqlNullableNum(row['total_purchase_amount'] as num?)},
          lender_name = ${sqlNullableString(row['lender_name'] as String?)},
          interest_rate = ${sqlNullableNum(row['interest_rate'] as num?)},
          server_id = ${sqlString(row['id'] as String)},
          synced_at = ${sqlString(dateTimeToSql(DateTime.now().toUtc()))},
          server_updated_at = ${sqlNullableString(_dateString(row['updated_at']))},
          sync_status = 'synced',
          deleted_at = NULL
      WHERE id = ${sqlString(id)};
    ''');
  }

  Future<void> _insertGoal(String id, Map<String, dynamic> row) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _db.customStatement('''
      INSERT OR IGNORE INTO goals(
        id, name, account_id, target_amount, saved_amount, deadline,
        vault_skin, status, created_at, auto_save_amount, auto_save_period,
        auto_save_last_run, server_id, synced_at, server_updated_at,
        sync_status, deleted_at
      ) VALUES (
        ${sqlString(id)},
        ${sqlString(row['name'] as String? ?? 'هدف')},
        ${sqlNullableString(row['local_account_id'] as String?)},
        ${(row['target_amount'] as num?)?.toDouble() ?? 0},
        ${(row['saved_amount'] as num?)?.toDouble() ?? 0},
        ${sqlNullableString(_dateString(row['deadline']))},
        ${sqlString(row['vault_skin'] as String? ?? 'classic')},
        ${sqlString(row['status'] as String? ?? 'active')},
        ${sqlString(_dateString(row['created_at']) ?? now)},
        ${sqlNullableNum(row['auto_save_amount'] as num?)},
        ${sqlNullableString(row['auto_save_period'] as String?)},
        ${sqlNullableString(_dateString(row['auto_save_last_run']))},
        ${sqlString(row['id'] as String)},
        ${sqlString(now)},
        ${sqlNullableString(_dateString(row['updated_at']))},
        'synced',
        NULL
      );
    ''');
  }

  Future<void> _updateGoal(String id, Map<String, dynamic> row) async {
    await _db.customStatement('''
      UPDATE goals
      SET name = ${sqlString(row['name'] as String? ?? 'هدف')},
          account_id = ${sqlNullableString(row['local_account_id'] as String?)},
          target_amount = ${(row['target_amount'] as num?)?.toDouble() ?? 0},
          saved_amount = ${(row['saved_amount'] as num?)?.toDouble() ?? 0},
          deadline = ${sqlNullableString(_dateString(row['deadline']))},
          vault_skin = ${sqlString(row['vault_skin'] as String? ?? 'classic')},
          status = ${sqlString(row['status'] as String? ?? 'active')},
          auto_save_amount = ${sqlNullableNum(row['auto_save_amount'] as num?)},
          auto_save_period = ${sqlNullableString(row['auto_save_period'] as String?)},
          auto_save_last_run = ${sqlNullableString(_dateString(row['auto_save_last_run']))},
          server_id = ${sqlString(row['id'] as String)},
          synced_at = ${sqlString(dateTimeToSql(DateTime.now().toUtc()))},
          server_updated_at = ${sqlNullableString(_dateString(row['updated_at']))},
          sync_status = 'synced',
          deleted_at = NULL
      WHERE id = ${sqlString(id)};
    ''');
  }

  Future<void> _insertPlan(String id, Map<String, dynamic> row) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _db.customStatement('''
      INSERT OR IGNORE INTO plans(
        id, name, budget_amount, currency, start_date, end_date,
        account_ids, card_last4s, status, icon, created_at,
        server_id, synced_at, server_updated_at, sync_status, deleted_at
      ) VALUES (
        ${sqlString(id)},
        ${sqlString(row['name'] as String? ?? 'خطة')},
        ${(row['budget_amount'] as num?)?.toDouble() ?? 0},
        ${sqlString(row['currency'] as String? ?? 'SAR')},
        ${sqlString(_dateString(row['start_date']) ?? now)},
        ${sqlString(_dateString(row['end_date']) ?? now)},
        ${sqlString(_csv(row['local_account_ids']))},
        ${sqlString(_csv(row['card_last4s']))},
        ${sqlString(row['status'] as String? ?? 'active')},
        ${sqlNullableString(row['icon'] as String?)},
        ${sqlString(_dateString(row['created_at']) ?? now)},
        ${sqlString(row['id'] as String)},
        ${sqlString(now)},
        ${sqlNullableString(_dateString(row['updated_at']))},
        'synced',
        NULL
      );
    ''');
  }

  Future<void> _updatePlan(String id, Map<String, dynamic> row) async {
    await _db.customStatement('''
      UPDATE plans
      SET name = ${sqlString(row['name'] as String? ?? 'خطة')},
          budget_amount = ${(row['budget_amount'] as num?)?.toDouble() ?? 0},
          currency = ${sqlString(row['currency'] as String? ?? 'SAR')},
          start_date = ${sqlString(_dateString(row['start_date']) ?? dateTimeToSql(DateTime.now().toUtc()))},
          end_date = ${sqlString(_dateString(row['end_date']) ?? dateTimeToSql(DateTime.now().toUtc()))},
          account_ids = ${sqlString(_csv(row['local_account_ids']))},
          card_last4s = ${sqlString(_csv(row['card_last4s']))},
          status = ${sqlString(row['status'] as String? ?? 'active')},
          icon = ${sqlNullableString(row['icon'] as String?)},
          server_id = ${sqlString(row['id'] as String)},
          synced_at = ${sqlString(dateTimeToSql(DateTime.now().toUtc()))},
          server_updated_at = ${sqlNullableString(_dateString(row['updated_at']))},
          sync_status = 'synced',
          deleted_at = NULL
      WHERE id = ${sqlString(id)};
    ''');
  }

  Future<String?> _findLocalId(
    String table,
    String serverId,
    String? localId,
  ) async {
    final byServer = await _db
        .customSelect(
          'SELECT id FROM $table WHERE server_id = ${sqlString(serverId)} LIMIT 1;',
        )
        .getSingleOrNull();
    if (byServer != null) return byServer.read<String>('id');

    if (localId == null) return null;
    final byLocal = await _db
        .customSelect(
          'SELECT id FROM $table WHERE id = ${sqlString(localId)} LIMIT 1;',
        )
        .getSingleOrNull();
    return byLocal?.read<String>('id');
  }

  Future<String?> _syncStatus(String table, String localId) async {
    final row = await _db
        .customSelect(
          'SELECT sync_status FROM $table WHERE id = ${sqlString(localId)} LIMIT 1;',
        )
        .getSingleOrNull();
    return row?.readNullable<String>('sync_status');
  }

  Future<void> _markConflict(String table, String localId) async {
    await _db.customStatement('''
      UPDATE $table
      SET sync_status = 'conflict'
      WHERE id = ${sqlString(localId)};
    ''');
  }

  Future<String> _ensureMerchant(String? merchantId, String name) async {
    if (merchantId != null && merchantId.isNotEmpty) {
      final existing = await _db
          .customSelect(
            'SELECT id FROM merchants WHERE id = ${sqlString(merchantId)} LIMIT 1;',
          )
          .getSingleOrNull();
      if (existing != null) return merchantId;
    }
    final normalized = AppDatabase.normalizeMerchant(name);
    final existing = await _db
        .customSelect(
          'SELECT id FROM merchants WHERE normalized_name = ${sqlString(normalized)} LIMIT 1;',
        )
        .getSingleOrNull();
    if (existing != null) return existing.read<String>('id');

    final id =
        merchantId?.isNotEmpty == true ? merchantId! : IdGenerator.next();
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _db.customStatement('''
      INSERT OR IGNORE INTO merchants(id, raw_name, normalized_name, first_seen_at, last_seen_at)
      VALUES (${sqlString(id)}, ${sqlString(name)}, ${sqlString(normalized)}, ${sqlString(now)}, ${sqlString(now)});
    ''');
    return id;
  }

  String? _dateString(Object? value) {
    if (value is String && value.isNotEmpty) return value;
    return null;
  }

  String _csv(Object? value) {
    if (value is List) {
      return value.map((e) => '$e').where((e) => e.isNotEmpty).join(',');
    }
    if (value is String) return value;
    return '';
  }
}

enum _PlanningPullOutcome { imported, updated, conflict, skipped }
