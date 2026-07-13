import 'package:drift/drift.dart';
import 'package:postgrest/postgrest.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/utils/id_generator.dart';
import '../../domain/entities/plan_entity.dart';
import '../../domain/entities/transaction_entity.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../../domain/repositories/plan_repository.dart';
import '../db/app_database.dart';
import '../db/financial_cache_health.dart';
import '../db/sql_value_codec.dart';
import 'supabase_planning_support.dart';
import 'supabase_transaction_repository.dart';

class SupabasePlanRepository implements PlanRepository {
  SupabasePlanRepository({
    required AppDatabase db,
    SupabaseClient Function()? getClient,
    Future<String?> Function()? getAuthUserId,
  })  : _support = SupabasePlanningSupport(
          db: db,
          getClient: getClient,
          getAuthUserId: getAuthUserId,
        ),
        _transactions = SupabaseTransactionRepository(
          db: db,
          getClient: getClient,
          getAuthUserId: getAuthUserId,
        );

  final SupabasePlanningSupport _support;
  final SupabaseTransactionRepository _transactions;

  @override
  Future<List<PlanEntity>> getAll() async {
    final uid = await _support.requireUserId();
    try {
      final rows = await _support
          .client()
          .from('user_plans')
          .select()
          .eq('user_id', uid)
          .isFilter('deleted_at', null)
          .order('created_at', ascending: false);
      return (rows as List)
          .map((row) => _fromRow(Map<String, dynamic>.from(row as Map)))
          .toList(growable: false);
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }

  @override
  Future<PlanEntity?> getById(String id) async {
    final uid = await _support.requireUserId();
    try {
      final row = await _support
          .client()
          .from('user_plans')
          .select()
          .eq('user_id', uid)
          .eq('id', id)
          .isFilter('deleted_at', null)
          .maybeSingle();
      return row == null ? null : _fromRow(row);
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }

  @override
  Future<PlanEntity> save(PlanEntity plan) async {
    final uid = await _support.requireUserId();
    final localId = plan.id.isEmpty ? IdGenerator.next() : plan.id;
    final serverAccounts = <String>[];
    for (final accountId in plan.accountIds) {
      final serverId = await _support.serverAccountId(accountId);
      if (serverId != null) serverAccounts.add(serverId);
    }
    final payload = {
      'name': plan.name,
      'budget_amount': plan.budgetAmount,
      'currency': plan.currency.toUpperCase(),
      'start_date': plan.startDate.toUtc().toIso8601String(),
      'end_date': plan.endDate.toUtc().toIso8601String(),
      'server_account_ids': serverAccounts,
      'card_last4s': plan.cardLast4s,
      'status': plan.status.name,
      'icon': plan.icon,
      'metadata': <String, dynamic>{},
    };
    Map<String, dynamic>? row;
    var inserted = false;
    try {
      final existing = await _support
          .client()
          .from('user_plans')
          .select('id')
          .eq('user_id', uid)
          .eq('id', plan.id)
          .maybeSingle();
      if (existing != null) {
        row = await _support
            .client()
            .from('user_plans')
            .update(payload)
            .eq('user_id', uid)
            .eq('id', plan.id)
            .select()
            .maybeSingle();
      } else {
        inserted = true;
        row = await _support
            .client()
            .from('user_plans')
            .insert({
              'user_id': uid,
              'local_id': localId,
              'created_at': plan.createdAt.toUtc().toIso8601String(),
              ...payload,
            })
            .select()
            .single();
      }
    } on PostgrestException catch (error) {
      if (error.code != '23505') throw mapSupabaseError(error);
      row = await _support
          .client()
          .from('user_plans')
          .select()
          .eq('user_id', uid)
          .eq('local_id', localId)
          .maybeSingle();
    } catch (error) {
      throw mapSupabaseError(error);
    }
    if (row == null) throw const NotFoundRepoException();
    await mirrorFinancialCacheSafely(
      _support.db,
      plansCacheEntityType,
      () => _mirrorPlan(row!, preferredLocalId: inserted ? localId : null),
    );
    return _fromRow(row);
  }

  @override
  Future<void> delete(String id) async {
    final uid = await _support.requireUserId();
    final deletedAt = DateTime.now().toUtc().toIso8601String();
    try {
      final row = await _support
          .client()
          .from('user_plans')
          .update({'deleted_at': deletedAt, 'status': 'closed'})
          .eq('user_id', uid)
          .eq('id', id)
          .select('id')
          .maybeSingle();
      if (row == null) throw const NotFoundRepoException();
      await mirrorFinancialCacheSafely(
        _support.db,
        plansCacheEntityType,
        () => _support.db.customStatement(
          "UPDATE plans SET deleted_at = ?, status = 'closed', sync_status = 'synced' WHERE server_id = ?;",
          [deletedAt, id],
        ),
      );
    } catch (error) {
      if (error is RepoException) rethrow;
      throw mapSupabaseError(error);
    }
  }

  @override
  Future<double> spentForPlan(PlanEntity plan) async {
    await _support.requireUserId();
    try {
      final value = await _support.client().rpc(
        'plan_spent_summary',
        params: {'p_plan_id': plan.id},
      );
      return (value as num?)?.toDouble() ?? 0;
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }

  @override
  Future<List<TransactionEntity>> transactionsForPlan(PlanEntity plan) async {
    await _support.requireUserId();
    try {
      final rows = await _support.client().rpc(
        'plan_transactions',
        params: {'p_plan_id': plan.id},
      );
      return Future.wait((rows as List).map(
        (row) => _transactions.entityFromServerRow(
          Map<String, dynamic>.from(row as Map),
        ),
      ));
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }

  @override
  Future<void> linkTransactionToPlan({
    required String planId,
    required String transactionId,
  }) async {
    final uid = await _support.requireUserId();
    final requestId = '$planId:$transactionId';
    try {
      final existing = await _support
          .client()
          .from('user_plan_transaction_links')
          .select()
          .eq('user_id', uid)
          .eq('plan_id', planId)
          .eq('transaction_id', transactionId)
          .maybeSingle();
      final Map<String, dynamic> row;
      if (existing == null) {
        row = await _support
            .client()
            .from('user_plan_transaction_links')
            .insert({
              'user_id': uid,
              'plan_id': planId,
              'transaction_id': transactionId,
              'client_request_id': requestId,
            })
            .select()
            .single();
      } else if (existing['deleted_at'] != null) {
        row = await _support
            .client()
            .from('user_plan_transaction_links')
            .update({'deleted_at': null})
            .eq('user_id', uid)
            .eq('id', existing['id'] as String)
            .select()
            .single();
      } else {
        row = existing;
      }
      await mirrorFinancialCacheSafely(
        _support.db,
        plansCacheEntityType,
        () => _mirrorLink(row),
      );
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }

  @override
  Future<void> unlinkTransactionFromPlan({
    required String planId,
    required String transactionId,
  }) async {
    final uid = await _support.requireUserId();
    final deletedAt = DateTime.now().toUtc().toIso8601String();
    try {
      await _support
          .client()
          .from('user_plan_transaction_links')
          .update({'deleted_at': deletedAt})
          .eq('user_id', uid)
          .eq('plan_id', planId)
          .eq('transaction_id', transactionId);
      final planLocal = await _localId('plans', planId);
      final transactionLocal = await _localId('transactions', transactionId);
      if (planLocal != null && transactionLocal != null) {
        await mirrorFinancialCacheSafely(
          _support.db,
          plansCacheEntityType,
          () => _support.db.customStatement(
            "UPDATE plan_transaction_links SET deleted_at = ?, sync_status = 'synced' "
            'WHERE plan_id = ? AND transaction_id = ?;',
            [deletedAt, planLocal, transactionLocal],
          ),
        );
      }
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }

  Future<void> repairLocalCache() async {
    final uid = await _support.requireUserId();
    try {
      final plans = await _support.allServerRows('user_plans', uid);
      final links =
          await _support.allServerRows('user_plan_transaction_links', uid);
      final now = dateTimeToSql(DateTime.now().toUtc());
      await _support.forEachMissingServerRow(
        localTable: 'plans',
        serverIds: plans.map((row) => row['id'] as String).toSet(),
        onMissing: (localId) => _support.db.customStatement(
          "UPDATE plans SET deleted_at = ?, status = 'closed', sync_status = 'synced' WHERE id = ?;",
          [now, localId],
        ),
      );
      for (final row in plans) {
        await _mirrorPlan(row);
      }
      final linkServerIds = links.map((row) => row['id'] as String).toSet();
      final cachedLinks = await _support.db
          .customSelect(
            'SELECT rowid AS local_rowid, server_id FROM plan_transaction_links '
            'WHERE server_id IS NOT NULL;',
          )
          .get();
      for (final cached in cachedLinks) {
        if (linkServerIds.contains(cached.read<String>('server_id'))) continue;
        await _support.db.customStatement(
          "UPDATE plan_transaction_links SET deleted_at = ?, sync_status = 'synced' WHERE rowid = ?;",
          [now, cached.read<int>('local_rowid')],
        );
      }
      for (final row in links) {
        await _mirrorLink(row);
      }
      await clearFinancialCacheDirty(_support.db, plansCacheEntityType);
    } catch (error) {
      if (error is RepoException) rethrow;
      throw mapSupabaseError(error);
    }
  }

  PlanEntity _fromRow(Map<String, dynamic> row) {
    List<String> strings(Object? value) => value is List
        ? value.map((item) => item.toString()).toList(growable: false)
        : const [];
    return PlanEntity(
      id: row['id'] as String,
      name: row['name'] as String,
      budgetAmount: (row['budget_amount'] as num).toDouble(),
      currency: row['currency'] as String,
      startDate: DateTime.parse(row['start_date'] as String).toUtc(),
      endDate: DateTime.parse(row['end_date'] as String).toUtc(),
      accountIds: strings(row['server_account_ids']),
      cardLast4s: strings(row['card_last4s']),
      status: row['status'] == 'closed' ? PlanStatus.closed : PlanStatus.active,
      createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
      icon: row['icon'] as String?,
    );
  }

  Future<String?> _localId(String table, String serverId) async {
    final row = await _support.db.customSelect(
      'SELECT id FROM $table WHERE server_id = ? LIMIT 1;',
      variables: [Variable.withString(serverId)],
    ).getSingleOrNull();
    return row?.readNullable<String>('id');
  }

  Future<void> _mirrorPlan(
    Map<String, dynamic> row, {
    String? preferredLocalId,
  }) async {
    final localId = await _support.localIdForServer(
      table: 'plans',
      serverId: row['id'] as String,
      preferred: preferredLocalId ?? row['local_id'] as String?,
    );
    final localAccounts = <String>[];
    for (final serverId in (row['server_account_ids'] as List? ?? const [])) {
      final local = await _support.localAccountId(serverId.toString());
      if (local != null) localAccounts.add(local);
    }
    final cardLast4s = (row['card_last4s'] as List? ?? const [])
        .map((item) => item.toString())
        .join(',');
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _support.db.customStatement('''
      INSERT INTO plans(
        id, name, budget_amount, currency, start_date, end_date, account_ids,
        card_last4s, status, icon, created_at, server_id, synced_at,
        server_updated_at, sync_status, deleted_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'synced', ?)
      ON CONFLICT(id) DO UPDATE SET
        name = excluded.name, budget_amount = excluded.budget_amount,
        currency = excluded.currency, start_date = excluded.start_date,
        end_date = excluded.end_date, account_ids = excluded.account_ids,
        card_last4s = excluded.card_last4s, status = excluded.status,
        icon = excluded.icon, server_id = excluded.server_id,
        synced_at = excluded.synced_at,
        server_updated_at = excluded.server_updated_at,
        sync_status = 'synced', deleted_at = excluded.deleted_at;
    ''', [
      localId,
      row['name'] as String,
      (row['budget_amount'] as num).toDouble(),
      row['currency'] as String,
      row['start_date'] as String,
      row['end_date'] as String,
      localAccounts.join(','),
      cardLast4s,
      row['status'] as String,
      row['icon'] as String?,
      row['created_at'] as String,
      row['id'] as String,
      now,
      row['updated_at'] as String,
      row['deleted_at'] as String?,
    ]);
  }

  Future<void> _mirrorLink(Map<String, dynamic> row) async {
    final planLocal = await _localId('plans', row['plan_id'] as String);
    final transactionLocal =
        await _localId('transactions', row['transaction_id'] as String);
    if (planLocal == null || transactionLocal == null) return;
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _support.db.customStatement('''
      INSERT INTO plan_transaction_links(
        plan_id, transaction_id, created_at, server_id, synced_at,
        server_updated_at, sync_status, deleted_at
      ) VALUES (?, ?, ?, ?, ?, ?, 'synced', ?)
      ON CONFLICT(plan_id, transaction_id) DO UPDATE SET
        server_id = excluded.server_id, synced_at = excluded.synced_at,
        server_updated_at = excluded.server_updated_at,
        sync_status = 'synced', deleted_at = excluded.deleted_at;
    ''', [
      planLocal,
      transactionLocal,
      row['created_at'] as String,
      row['id'] as String,
      now,
      row['updated_at'] as String,
      row['deleted_at'] as String?,
    ]);
  }
}
