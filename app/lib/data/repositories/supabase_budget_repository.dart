import 'package:postgrest/postgrest.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:drift/drift.dart' show Variable;

import '../../core/utils/id_generator.dart';
import '../../domain/entities/budget_entity.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../../domain/repositories/budget_repository.dart';
import '../db/app_database.dart';
import '../db/financial_cache_health.dart';
import '../db/sql_value_codec.dart';
import 'supabase_planning_support.dart';

class SupabaseBudgetRepository implements BudgetRepository {
  SupabaseBudgetRepository({
    required AppDatabase db,
    SupabaseClient Function()? getClient,
    Future<String?> Function()? getAuthUserId,
  }) : _support = SupabasePlanningSupport(
          db: db,
          getClient: getClient,
          getAuthUserId: getAuthUserId,
        );

  final SupabasePlanningSupport _support;

  @override
  Future<List<BudgetEntity>> getAll() async {
    final uid = await _support.requireUserId();
    try {
      final rows = await _support
          .client()
          .from('user_budgets')
          .select()
          .eq('user_id', uid)
          .isFilter('deleted_at', null)
          .order('start_date', ascending: false);
      return Future.wait((rows as List).map(
        (row) => _fromRow(Map<String, dynamic>.from(row as Map)),
      ));
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }

  @override
  Future<BudgetEntity?> getById(String id) async {
    final uid = await _support.requireUserId();
    try {
      final serverId = await _support.resolveServerEntityId(
        localTable: 'budgets',
        serverTable: 'user_budgets',
        userId: uid,
        entityId: id,
      );
      if (serverId == null) return null;
      final row = await _support
          .client()
          .from('user_budgets')
          .select()
          .eq('user_id', uid)
          .eq('id', serverId)
          .isFilter('deleted_at', null)
          .maybeSingle();
      return row == null ? null : _fromRow(row);
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }

  @override
  Future<int> countActive() async =>
      (await getAll()).where((budget) => budget.isActive).length;

  @override
  Future<BudgetEntity> save(BudgetEntity budget) async {
    final uid = await _support.requireUserId();
    final categoryRefs = await _categoryRefs(budget.categoryId);
    final accountId = await _support.serverAccountId(budget.accountId);
    final localId = budget.id.isEmpty ? IdGenerator.next() : budget.id;
    final existingServerId = await _support.resolveServerEntityId(
      localTable: 'budgets',
      serverTable: 'user_budgets',
      userId: uid,
      entityId: budget.id,
    );
    final payload = {
      'category_id': categoryRefs.$1 ?? 'other',
      'user_category_id': categoryRefs.$2,
      'amount': budget.amount,
      'period': budget.period.name,
      'start_date': budget.startDate.toUtc().toIso8601String(),
      'is_active': budget.isActive,
      'alert_80_sent': budget.alert80Sent,
      'alert_100_sent': budget.alert100Sent,
      'show_on_header': budget.showOnHeader,
      'server_account_id': accountId,
      'metadata': <String, dynamic>{},
    };
    Map<String, dynamic>? row;
    var inserted = false;
    try {
      if (existingServerId != null) {
        row = await _support
            .client()
            .from('user_budgets')
            .update(payload)
            .eq('user_id', uid)
            .eq('id', existingServerId)
            .select()
            .maybeSingle();
      } else {
        inserted = true;
        row = await _support
            .client()
            .from('user_budgets')
            .insert({'user_id': uid, 'local_id': localId, ...payload})
            .select()
            .single();
      }
    } on PostgrestException catch (error) {
      if (error.code != '23505') throw mapSupabaseError(error);
      row = await _support
          .client()
          .from('user_budgets')
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
      budgetsCacheEntityType,
      () => _mirror(row!, preferredLocalId: inserted ? localId : null),
    );
    return _fromRow(row);
  }

  @override
  Future<void> delete(String id) async {
    final uid = await _support.requireUserId();
    final deletedAt = DateTime.now().toUtc().toIso8601String();
    try {
      final serverId = await _support.resolveServerEntityId(
        localTable: 'budgets',
        serverTable: 'user_budgets',
        userId: uid,
        entityId: id,
      );
      if (serverId == null) throw const NotFoundRepoException();
      final row = await _support
          .client()
          .from('user_budgets')
          .update({'deleted_at': deletedAt, 'is_active': false})
          .eq('user_id', uid)
          .eq('id', serverId)
          .select('id')
          .maybeSingle();
      if (row == null) throw const NotFoundRepoException();
      await mirrorFinancialCacheSafely(
        _support.db,
        budgetsCacheEntityType,
        () => _support.db.customStatement(
          "UPDATE budgets SET deleted_at = ?, is_active = 0, sync_status = 'synced' WHERE server_id = ?;",
          [deletedAt, serverId],
        ),
      );
    } catch (error) {
      if (error is RepoException) rethrow;
      throw mapSupabaseError(error);
    }
  }

  Future<void> repairLocalCache() async {
    final uid = await _support.requireUserId();
    try {
      final rows = await _support.allServerRows('user_budgets', uid);
      final serverIds = rows.map((row) => row['id'] as String).toSet();
      final now = dateTimeToSql(DateTime.now().toUtc());
      await _support.forEachMissingServerRow(
        localTable: 'budgets',
        serverIds: serverIds,
        onMissing: (localId) => _support.db.customStatement(
          "UPDATE budgets SET deleted_at = ?, is_active = 0, sync_status = 'synced' WHERE id = ?;",
          [now, localId],
        ),
      );
      for (final row in rows) {
        await _mirror(row);
      }
      await clearFinancialCacheDirty(_support.db, budgetsCacheEntityType);
    } catch (error) {
      if (error is RepoException) rethrow;
      throw mapSupabaseError(error);
    }
  }

  Future<BudgetEntity> _fromRow(Map<String, dynamic> row) async {
    return BudgetEntity(
      id: row['id'] as String,
      categoryId: await _localCategoryId(row),
      amount: (row['amount'] as num).toDouble(),
      period: BudgetPeriod.values.firstWhere(
        (value) => value.name == row['period'],
        orElse: () => BudgetPeriod.monthly,
      ),
      startDate: DateTime.parse(row['start_date'] as String).toUtc(),
      isActive: row['is_active'] as bool? ?? true,
      alert80Sent: row['alert_80_sent'] as bool? ?? false,
      alert100Sent: row['alert_100_sent'] as bool? ?? false,
      showOnHeader: row['show_on_header'] as bool? ?? false,
      accountId: row['server_account_id'] as String?,
    );
  }

  Future<void> _mirror(
    Map<String, dynamic> row, {
    String? preferredLocalId,
  }) async {
    final serverId = row['id'] as String;
    final localId = await _support.localIdForServer(
      table: 'budgets',
      serverId: serverId,
      preferred: preferredLocalId ?? row['local_id'] as String?,
    );
    final categoryId = await _localCategoryId(row);
    final localAccountId =
        await _support.localAccountId(row['server_account_id'] as String?);
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _support.db.customStatement('''
      INSERT INTO budgets(
        id, category_id, amount, period, start_date, is_active,
        alert_80_sent, alert_100_sent, show_on_header, account_id,
        server_id, synced_at, server_updated_at, sync_status, deleted_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'synced', ?)
      ON CONFLICT(id) DO UPDATE SET
        category_id = excluded.category_id, amount = excluded.amount,
        period = excluded.period, start_date = excluded.start_date,
        is_active = excluded.is_active, alert_80_sent = excluded.alert_80_sent,
        alert_100_sent = excluded.alert_100_sent,
        show_on_header = excluded.show_on_header, account_id = excluded.account_id,
        server_id = excluded.server_id, synced_at = excluded.synced_at,
        server_updated_at = excluded.server_updated_at,
        sync_status = 'synced', deleted_at = excluded.deleted_at;
    ''', [
      localId,
      categoryId,
      (row['amount'] as num).toDouble(),
      row['period'] as String,
      row['start_date'] as String,
      boolToSql(row['is_active'] as bool? ?? true),
      boolToSql(row['alert_80_sent'] as bool? ?? false),
      boolToSql(row['alert_100_sent'] as bool? ?? false),
      boolToSql(row['show_on_header'] as bool? ?? false),
      localAccountId,
      serverId,
      now,
      row['updated_at'] as String,
      row['deleted_at'] as String?,
    ]);
  }

  Future<(String?, String?)> _categoryRefs(String categoryId) async {
    final row = await _support.db.customSelect(
      'SELECT key, server_id FROM categories WHERE id = ? OR key = ? LIMIT 1;',
      variables: [
        Variable.withString(categoryId),
        Variable.withString(categoryId),
      ],
    ).getSingleOrNull();
    final key = row?.readNullable<String>('key') ?? categoryId;
    final serverId = row?.readNullable<String>('server_id');
    return serverId == null ? (key, null) : (null, serverId);
  }

  Future<String> _localCategoryId(Map<String, dynamic> row) async {
    final customId = row['user_category_id'] as String?;
    if (customId != null) {
      final local = await _support.db.customSelect(
        'SELECT id FROM categories WHERE server_id = ? OR id = ? LIMIT 1;',
        variables: [
          Variable.withString(customId),
          Variable.withString(customId),
        ],
      ).getSingleOrNull();
      if (local != null) return local.read<String>('id');
    }
    return _support.localCategoryId((row['category_id'] as String?) ?? 'other');
  }
}
