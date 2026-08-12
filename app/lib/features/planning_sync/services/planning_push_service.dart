import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../core/sync/outbox_failure.dart';
import '../../../core/sync/sync_capabilities.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/planning_cutover.dart';
import '../../../data/db/sql_value_codec.dart';
import '../../../data/sync/exact_transport_capability.dart';
import 'planning_outbox_queue.dart';

/// Acknowledgement columns a guarded write reads back — includes the server
/// `revision` only when the CAS capability (and thus 0068) is present.
const String _ackCols =
    kServerRevisionCas ? 'id, updated_at, revision' : 'id, updated_at';

class PlanningPushResult {
  const PlanningPushResult({
    this.pushed = 0,
    this.conflicts = 0,
    this.failed = 0,
    this.abandoned = 0,
    this.parked = 0,
  });

  final int pushed;
  final int conflicts;
  final int failed;
  final int abandoned;

  /// MALI-026 (B8-2.10 §8): money rows held for unverified exact transport.
  final int parked;
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

  /// MALI-022 — the current server `updated_at` for a known server row, used as
  /// the optimistic-concurrency compare on update. Null if the row is gone.
  Future<String?> fetchServerUpdatedAt(String table, String serverId);

  /// MALI-022 — targeted update of a known server row (used only after the
  /// base-token guard passes), returning the new id + updated_at.
  Future<Map<String, dynamic>> updateByServerId(
    String table,
    String serverId,
    Map<String, dynamic> row,
  );

  /// MALI-022 / 0068 — atomic compare-and-set update. Updates the row only if
  /// its server `revision` still equals [expectedRevision]; returns the new
  /// id/updated_at/revision, or null when no row matched (a genuine conflict).
  Future<Map<String, dynamic>?> casUpdateByServerId(
    String table,
    String serverId,
    int expectedRevision,
    Map<String, dynamic> row,
  );
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
        .select(_ackCols)
        .single();
  }

  @override
  Future<Map<String, dynamic>?> casUpdateByServerId(
    String table,
    String serverId,
    int expectedRevision,
    Map<String, dynamic> row,
  ) async {
    return await _client
        .from(table)
        .update(row)
        .eq('id', serverId)
        .eq('revision', expectedRevision)
        .select(_ackCols)
        .maybeSingle();
  }

  @override
  Future<String?> fetchServerUpdatedAt(String table, String serverId) async {
    final row = await _client
        .from(table)
        .select('updated_at')
        .eq('id', serverId)
        .maybeSingle();
    return row?['updated_at'] as String?;
  }

  @override
  Future<Map<String, dynamic>> updateByServerId(
    String table,
    String serverId,
    Map<String, dynamic> row,
  ) async {
    return await _client
        .from(table)
        .update(row)
        .eq('id', serverId)
        .select(_ackCols)
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
    bool revisionCasEnabled = kServerRevisionCas,
    // MALI-026 (B8-2.10 §8/§9): both defaults preserve schema-v29 behavior:
    // legacy authority never parks, regardless of the unknown capability.
    PlanningCutoverCoordinator coordinator =
        const SchemaV29PlanningCutoverCoordinator(),
    ExactTransportCapability Function() pushCapability = _defaultPushCapability,
    // MALI-026 (B8-3 §30): whether the SERVER carries per-row planning currency
    // (0077). Budgets/goals push parks on THIS (they need a server currency
    // column), independent of the exact decimal-string transport capability.
    ExactTransportCapability Function() planningCurrencyCapability =
        _defaultPushCapability,
  })  : _db = db,
        _queue = queue,
        _isEnabled = isEnabled,
        _getAuthUserId = getAuthUserId ?? _defaultGetAuthUserId,
        _remoteSink = remoteSink ?? const SupabasePlanningRemoteSink(),
        _revisionCasEnabled = revisionCasEnabled,
        _coordinator = coordinator,
        _pushCapability = pushCapability,
        _planningCurrencyCapability = planningCurrencyCapability;

  static ExactTransportCapability _defaultPushCapability() =>
      ExactTransportCapability.unknown;

  static const _planningCurrencyEntityTypes = {
    PlanningOutboxQueue.budgetsEntityType,
    PlanningOutboxQueue.goalsEntityType,
  };

  final AppDatabase _db;
  final PlanningOutboxQueue _queue;
  final bool Function(String entityType) _isEnabled;
  final Future<String?> Function() _getAuthUserId;
  final PlanningRemoteSink _remoteSink;

  /// MALI-022 / 0068 — whether to use the atomic revision CAS. Defaults to the
  /// [kServerRevisionCas] capability const (OFF until 0068 verified on staging);
  /// injectable so the ON path is testable.
  final bool _revisionCasEnabled;
  final PlanningCutoverCoordinator _coordinator;
  final ExactTransportCapability Function() _pushCapability;
  final ExactTransportCapability Function() _planningCurrencyCapability;

  static const _moneyEntityTypes = {
    PlanningOutboxQueue.accountsEntityType,
    PlanningOutboxQueue.subscriptionsEntityType,
    PlanningOutboxQueue.plansEntityType,
    PlanningOutboxQueue.billPaymentsEntityType,
    // MALI-026 (B8-3 §30) — budgets/goals become canonical planning money at v30.
    // Their exact push depends on the server per-row currency column (0077, still
    // UNDEPLOYED), so canonical push parks until that capability is verified.
    PlanningOutboxQueue.budgetsEntityType,
    PlanningOutboxQueue.goalsEntityType,
  };

  static const _entityTable = {
    PlanningOutboxQueue.budgetsEntityType: 'user_budgets',
    PlanningOutboxQueue.subscriptionsEntityType: 'user_subscriptions',
    PlanningOutboxQueue.goalsEntityType: 'user_goals',
    PlanningOutboxQueue.plansEntityType: 'user_plans',
    PlanningOutboxQueue.cardsEntityType: 'user_cards',
    PlanningOutboxQueue.categoriesEntityType: 'user_categories',
    PlanningOutboxQueue.settingsEntityType: 'user_settings',
  };

  static const _localTable = {
    PlanningOutboxQueue.budgetsEntityType: 'budgets',
    PlanningOutboxQueue.subscriptionsEntityType: 'subscriptions',
    PlanningOutboxQueue.goalsEntityType: 'goals',
    PlanningOutboxQueue.plansEntityType: 'plans',
    PlanningOutboxQueue.cardsEntityType: 'cards',
    PlanningOutboxQueue.categoriesEntityType: 'categories',
    PlanningOutboxQueue.settingsEntityType: 'user_settings',
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

    // MALI-026 (B8-2.10 §9): a verified exact transport re-arms the SAME
    // durable rows before this drain starts.
    if (_pushCapability() == ExactTransportCapability.verifiedExact) {
      await _queue.reArmParked();
    }

    var pushed = 0;
    var conflicts = 0;
    var failed = 0;
    var abandoned = 0;
    var parked = 0;

    for (final entityType in _entityTable.keys) {
      if (!_isEnabled(entityType)) continue;
      final items = await _queue.pendingItems(entityType: entityType);
      for (final item in items) {
        try {
          final outcome = await _process(item, userId);
          switch (outcome) {
            case _PlanningPushOutcome.pushed:
              pushed++;
            case _PlanningPushOutcome.conflict:
              conflicts++;
            case _PlanningPushOutcome.abandoned:
              abandoned++;
            case _PlanningPushOutcome.parked:
              // Held durably; not sent, synced, failed, or retried.
              parked++;
          }
        } catch (e) {
          failed++;
          await _queue.markFailed(item.id, e.toString(), classifyOutboxError(e));
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
      parked: parked,
    );
  }

  Future<_PlanningPushOutcome> _process(
    PlanningOutboxItem item,
    String userId,
  ) async {
    // MALI-026 (B8-2.10 §8 / B8-3 §30): money entities park on the relevant
    // capability. Budgets/goals need BOTH the exact decimal-string transport AND
    // the SERVER per-row currency column (0077), so they park unless BOTH are
    // verified (the weaker of the two) — never unpark on one alone. Everything
    // else parks on the exact decimal-string transport capability. Non-delete
    // writes only.
    final capability = _planningCurrencyEntityTypes.contains(item.entityType)
        ? weakerCapability(_planningCurrencyCapability(), _pushCapability())
        : _pushCapability();
    if (item.operation != PlanningSyncOperation.delete &&
        _moneyEntityTypes.contains(item.entityType) &&
        shouldParkExactMoneyWrite(
          cutoverState: _coordinator.state(),
          pushCapability: capability,
        )) {
      await _queue.park(item.id, exactMoneyTransportUnverifiedReason);
      return _PlanningPushOutcome.parked;
    }

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
    final row = _toServerRow(item.entityType, item.payloadJson, userId);
    try {
      final serverId = await _serverIdForLocal(localTable, item.entityId);

      // CREATE (never synced): upsert to establish the server row.
      if (serverId == null) {
        final response = await _remoteSink.upsert(remoteTable, row);
        await _attachServerId(localTable, item.entityId,
            response['id'] as String, response['updated_at'] as String?,
            serverRevision: response['revision'] as int?);
        await _queue.markSuccess(item.id);
        return _PlanningPushOutcome.pushed;
      }

      // UPDATE. MALI-022 / 0068 — atomic compare-and-set when the capability is
      // on AND a base revision is known: the server updates only if `revision`
      // still matches; a zero-row result is a genuine conflict.
      final expectedRevision = item.payloadJson['server_revision'] as int?;
      if (_revisionCasEnabled && expectedRevision != null) {
        final response = await _remoteSink.casUpdateByServerId(
            remoteTable, serverId, expectedRevision, row);
        if (response == null) {
          await _markConflict(localTable, item.entityId);
          await _queue.markSuccess(item.id);
          return _PlanningPushOutcome.conflict;
        }
        await _attachServerId(localTable, item.entityId,
            response['id'] as String, response['updated_at'] as String?,
            serverRevision: response['revision'] as int?);
        await _queue.markSuccess(item.id);
        return _PlanningPushOutcome.pushed;
      }

      // Fail-safe guarded path (capability OFF, or revision unknown). Only
      // overwrite the remote row if it hasn't moved since the base version this
      // edit was made against — otherwise flag a conflict WITHOUT clobbering the
      // remote edit and WITHOUT discarding the local edit (MALI-009). Never a
      // blind overwrite.
      final base = item.payloadJson['server_updated_at'] as String?;
      if (base != null) {
        final current =
            await _remoteSink.fetchServerUpdatedAt(remoteTable, serverId);
        if (current != null && current != base) {
          await _markConflict(localTable, item.entityId);
          await _queue.markSuccess(item.id);
          return _PlanningPushOutcome.conflict;
        }
      }
      final response =
          await _remoteSink.updateByServerId(remoteTable, serverId, row);
      await _attachServerId(localTable, item.entityId, response['id'] as String,
          response['updated_at'] as String?,
          serverRevision: response['revision'] as int?);
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
    String? serverUpdatedAt, {
    int? serverRevision,
  }) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _db.customStatement('''
      UPDATE $table
      SET server_id = ${sqlString(serverId)},
          synced_at = ${sqlString(now)},
          server_updated_at = ${sqlNullableString(serverUpdatedAt)},
          ${serverRevision != null ? 'server_revision = $serverRevision,' : ''}
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
          // §7/§30: canonical push carries the row currency (server column 0077).
          // Legacy payloads omit it, so it is only sent when present.
          if (payload['currency'] != null) 'currency': payload['currency'],
          'period': payload['period'],
          'start_date': payload['start_date'],
          'is_active': payload['is_active'] == true,
          'last_notified_spent_amount': payload['last_notified_spent_amount'],
          'last_notified_period_start': payload['last_notified_period_start'],
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
          // §7/§30: canonical push carries the row currency (server column 0077).
          if (payload['currency'] != null) 'currency': payload['currency'],
          'deadline': payload['deadline'],
          'vault_skin': payload['vault_skin'],
          'status': payload['status'],
          'auto_save_amount': payload['auto_save_amount'],
          'auto_save_period': payload['auto_save_period'],
          'auto_save_last_run': payload['auto_save_last_run'],
          'last_notified_saved_amount': payload['last_notified_saved_amount'],
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
      PlanningOutboxQueue.cardsEntityType => {
          'user_id': userId,
          'local_id': payload['local_id'],
          'local_account_id': payload['local_account_id'],
          'nickname': payload['nickname'],
          'last4': payload['last4'],
          'network': payload['network'],
          'source': payload['source'],
          // حقول التصميم لا تُرسَل حتى نشر ترقية 0064 (العمودان غير موجودين
          // على الخادم بعد) — انظر kUserCardsCloudV2.
          if (kUserCardsCloudV2) 'color_theme': payload['color_theme'],
          if (kUserCardsCloudV2) 'accent_hex': payload['accent_hex'],
          'created_at': payload['created_at'],
        },
      PlanningOutboxQueue.categoriesEntityType => {
          'user_id': userId,
          'local_id': payload['local_id'],
          'key': payload['key'],
          'name_ar': payload['name_ar'],
          'icon': payload['icon'],
          'color': payload['color'],
          'is_income': payload['is_income'] == true,
        },
      // تفضيلات المستخدم — أعمدة سحابية فقط (لا مفتاح تشفير/أفاتار/ملف شخصي).
      PlanningOutboxQueue.settingsEntityType => {
          'user_id': userId,
          'local_id': payload['local_id'],
          'display_name': payload['display_name'],
          'phone_number': payload['phone_number'],
          'date_of_birth': payload['date_of_birth'],
          'theme': payload['theme'],
          'currency': payload['currency'],
          'language': payload['language'],
          'country': payload['country'],
          'input_method': payload['input_method'],
          'notifications_json': payload['notifications_json'],
          'privacy_mode_enabled': payload['privacy_mode_enabled'] == true,
          // MALI-059n: consent is device-local + explicit — never pushed to the
          // server (so it can't cross devices as implicit authorization).
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

enum _PlanningPushOutcome { pushed, conflict, abandoned, parked }
