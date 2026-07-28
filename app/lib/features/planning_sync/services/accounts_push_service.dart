import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/sql_value_codec.dart';
import 'planning_outbox_queue.dart';

class AccountsPushResult {
  const AccountsPushResult({
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

abstract class AccountsRemoteSink {
  Future<Map<String, dynamic>> upsertAccount(Map<String, dynamic> row);
  Future<Map<String, dynamic>?> findAccountByLocalId(String userId, String id);
  Future<void> tombstoneAccount(String serverId);

  /// Atomically makes [serverAccountId] the user's only default via the
  /// `set_default_account` RPC (MALI-015) — the server demotes the previous
  /// default in the same transaction, so outbox ordering can never trip the
  /// one-active-default unique index.
  Future<void> setDefaultAccount(String serverAccountId);
}

class SupabaseAccountsRemoteSink implements AccountsRemoteSink {
  const SupabaseAccountsRemoteSink();

  SupabaseClient get _client => Supabase.instance.client;

  @override
  Future<Map<String, dynamic>?> findAccountByLocalId(
    String userId,
    String id,
  ) async {
    return await _client
        .from('user_accounts')
        .select('id, updated_at')
        .eq('user_id', userId)
        .eq('local_id', id)
        .maybeSingle();
  }

  @override
  Future<void> tombstoneAccount(String serverId) async {
    await _client.from('user_accounts').update({
      'deleted_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', serverId);
  }

  @override
  Future<Map<String, dynamic>> upsertAccount(Map<String, dynamic> row) async {
    return await _client
        .from('user_accounts')
        .upsert(row, onConflict: 'user_id,local_id')
        .select('id, updated_at')
        .single();
  }

  @override
  Future<void> setDefaultAccount(String serverAccountId) async {
    await _client.rpc<void>(
      'set_default_account',
      params: {'p_account_id': serverAccountId},
    );
  }
}

class AccountsPushService {
  AccountsPushService({
    required AppDatabase db,
    required PlanningOutboxQueue queue,
    required bool Function() isEnabled,
    Future<String?> Function()? getAuthUserId,
    AccountsRemoteSink? remoteSink,
  })  : _db = db,
        _queue = queue,
        _isEnabled = isEnabled,
        _getAuthUserId = getAuthUserId ?? _defaultGetAuthUserId,
        _remoteSink = remoteSink ?? const SupabaseAccountsRemoteSink();

  final AppDatabase _db;
  final PlanningOutboxQueue _queue;
  final bool Function() _isEnabled;
  final Future<String?> Function() _getAuthUserId;
  final AccountsRemoteSink _remoteSink;

  static Future<String?> _defaultGetAuthUserId() async {
    if (!SupabaseConfig.isConfigured) return null;
    try {
      return Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  Future<AccountsPushResult> push() async {
    if (!_isEnabled()) return const AccountsPushResult();
    final userId = await _getAuthUserId();
    if (userId == null) return const AccountsPushResult();

    final items = await _queue.pendingItems(
      entityType: PlanningOutboxQueue.accountsEntityType,
    );
    if (items.isEmpty) return const AccountsPushResult();

    int pushed = 0;
    int conflicts = 0;
    int failed = 0;
    int abandoned = 0;

    for (final item in items) {
      try {
        final outcome = await _processItem(item, userId);
        switch (outcome) {
          case _AccountsPushOutcome.pushed:
            pushed++;
          case _AccountsPushOutcome.conflict:
            conflicts++;
          case _AccountsPushOutcome.abandoned:
            abandoned++;
        }
      } catch (e) {
        failed++;
        await _queue.markFailed(item.id, e.toString());
        if (kDebugMode) debugPrint('[AccountsPush] item error: $e');
      }
    }

    if (kDebugMode) {
      debugPrint(
        '[AccountsPush] done: pushed=$pushed conflicts=$conflicts '
        'failed=$failed abandoned=$abandoned',
      );
    }
    return AccountsPushResult(
      pushed: pushed,
      conflicts: conflicts,
      failed: failed,
      abandoned: abandoned,
    );
  }

  Future<_AccountsPushOutcome> _processItem(
    PlanningOutboxItem item,
    String userId,
  ) async {
    switch (item.operation) {
      case PlanningSyncOperation.create:
      case PlanningSyncOperation.update:
        return _pushUpsert(item, userId);
      case PlanningSyncOperation.delete:
        return _pushDelete(item, userId);
    }
  }

  Future<_AccountsPushOutcome> _pushUpsert(
    PlanningOutboxItem item,
    String userId,
  ) async {
    try {
      final row = _toServerRow(item.payloadJson, userId);
      final response = await _remoteSink.upsertAccount(row);
      final serverId = response['id'] as String;
      // Default flag travels via the atomic RPC, never the upsert (MALI-015):
      // pushing the NEW default's row before the old default's demotion used
      // to violate the one-active-default unique index and drop the switch as
      // a "conflict". The RPC demotes and promotes in one server transaction,
      // so item ordering no longer matters. RPC failure rethrows → the outbox
      // item stays and the whole (idempotent) step retries.
      if (item.payloadJson['is_default'] == true) {
        await _remoteSink.setDefaultAccount(serverId);
      }
      await _attachServerId(
        item.entityId,
        serverId,
        response['updated_at'] as String?,
      );
      await _queue.markSuccess(item.id);
      return _AccountsPushOutcome.pushed;
    } catch (e) {
      if (_isConflict(e)) {
        await _markConflict(item.entityId);
        await _queue.markSuccess(item.id);
        return _AccountsPushOutcome.conflict;
      }
      rethrow;
    }
  }

  Future<_AccountsPushOutcome> _pushDelete(
    PlanningOutboxItem item,
    String userId,
  ) async {
    var serverId = await _serverIdForLocalAccount(item.entityId);
    serverId ??= (await _remoteSink.findAccountByLocalId(
        userId, item.entityId))?['id'] as String?;
    if (serverId != null) {
      await _remoteSink.tombstoneAccount(serverId);
    }
    await _markSynced(item.entityId, serverId);
    await _queue.markSuccess(item.id);
    return _AccountsPushOutcome.pushed;
  }

  Future<String?> _serverIdForLocalAccount(String id) async {
    final row = await _db
        .customSelect(
          'SELECT server_id FROM accounts WHERE id = ${sqlString(id)} LIMIT 1;',
        )
        .getSingleOrNull();
    return row?.readNullable<String>('server_id');
  }

  Future<void> _attachServerId(
    String localId,
    String serverId,
    String? serverUpdatedAt,
  ) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _db.customStatement('''
      UPDATE accounts
      SET server_id = ${sqlString(serverId)},
          synced_at = ${sqlString(now)},
          server_updated_at = ${sqlNullableString(serverUpdatedAt)},
          sync_status = 'synced'
      WHERE id = ${sqlString(localId)};
    ''');
  }

  Future<void> _markSynced(String localId, String? serverId) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _db.customStatement('''
      UPDATE accounts
      SET ${serverId == null ? '' : 'server_id = ${sqlString(serverId)},'}
          synced_at = ${sqlString(now)},
          sync_status = 'synced'
      WHERE id = ${sqlString(localId)};
    ''');
  }

  Future<void> _markConflict(String localId) async {
    await _db.customStatement('''
      UPDATE accounts
      SET sync_status = 'conflict'
      WHERE id = ${sqlString(localId)};
    ''');
  }

  static Map<String, dynamic> _toServerRow(
    Map<String, dynamic> payload,
    String userId,
  ) {
    return {
      'user_id': userId,
      'local_id': payload['local_id'],
      'name': payload['name'],
      'currency': payload['currency'],
      'type': payload['type'],
      'initial_balance': payload['initial_balance'],
      'current_balance': payload['current_balance'],
      'bank_account_number': payload['bank_account_number'],
      'credit_limit': payload['credit_limit'],
      'available_credit': payload['available_credit'],
      'payment_due_day': payload['payment_due_day'],
      'wallet_provider': payload['wallet_provider'],
      'exclude_from_totals': payload['exclude_from_totals'] == true,
      // Older outbox rows may predate the local metadata default. The server
      // column is NOT NULL, so normalize them at send time as well.
      'metadata': payload['metadata'] ?? const <String, dynamic>{},
      // is_default is deliberately NOT part of the upsert row (MALI-015) —
      // it is applied through the atomic set_default_account RPC after the
      // upsert, so the partial unique index can never reject a row because a
      // stale default still exists server-side.
      'sort_order': payload['sort_order'] ?? 0,
      'created_at': payload['created_at'],
    };
  }

  static bool _isConflict(Object e) {
    final msg = e.toString().toLowerCase();
    return msg.contains('409') ||
        msg.contains('conflict') ||
        msg.contains('duplicate');
  }
}

enum _AccountsPushOutcome { pushed, conflict, abandoned }
