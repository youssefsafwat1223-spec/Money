import 'package:postgrest/postgrest.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/utils/id_generator.dart';
import '../../domain/entities/goal_entity.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../../domain/repositories/goal_repository.dart';
import '../db/app_database.dart';
import '../db/financial_cache_health.dart';
import '../db/sql_value_codec.dart';
import 'supabase_planning_support.dart';

class SupabaseGoalRepository implements GoalRepository {
  SupabaseGoalRepository({
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
  Future<List<GoalEntity>> getAll() async {
    final uid = await _support.requireUserId();
    try {
      final rows = await _support
          .client()
          .from('user_goals')
          .select()
          .eq('user_id', uid)
          .isFilter('deleted_at', null)
          .order('created_at', ascending: false);
      return (rows as List)
          .map((row) => _goalFromRow(Map<String, dynamic>.from(row as Map)))
          .toList(growable: false);
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }

  @override
  Future<GoalEntity?> getById(String id) async {
    final uid = await _support.requireUserId();
    try {
      final serverId = await _support.resolveServerEntityId(
        localTable: 'goals',
        serverTable: 'user_goals',
        userId: uid,
        entityId: id,
      );
      if (serverId == null) return null;
      final row = await _support
          .client()
          .from('user_goals')
          .select()
          .eq('user_id', uid)
          .eq('id', serverId)
          .isFilter('deleted_at', null)
          .maybeSingle();
      return row == null ? null : _goalFromRow(row);
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }

  @override
  Future<int> countAll() async => (await getAll()).length;

  @override
  Future<GoalEntity> save(GoalEntity goal) async {
    final uid = await _support.requireUserId();
    final localId = goal.id.isEmpty ? IdGenerator.next() : goal.id;
    final existingServerId = await _support.resolveServerEntityId(
      localTable: 'goals',
      serverTable: 'user_goals',
      userId: uid,
      entityId: goal.id,
    );
    final accountId = await _support.serverAccountId(goal.accountId);
    final payload = {
      'name': goal.name,
      'server_account_id': accountId,
      'target_amount': goal.targetAmount,
      'saved_amount': goal.savedAmount,
      'deadline': goal.deadline?.toUtc().toIso8601String(),
      'vault_skin': goal.vaultSkin,
      'status': goal.status,
      'auto_save_amount': goal.autoSaveAmount,
      'auto_save_period': goal.autoSavePeriod,
      'auto_save_last_run': goal.autoSaveLastRun?.toUtc().toIso8601String(),
      'metadata': <String, dynamic>{},
    };
    Map<String, dynamic>? row;
    var inserted = false;
    try {
      if (existingServerId != null) {
        row = await _support
            .client()
            .from('user_goals')
            .update(payload)
            .eq('user_id', uid)
            .eq('id', existingServerId)
            .select()
            .maybeSingle();
      } else {
        inserted = true;
        row = await _support
            .client()
            .from('user_goals')
            .insert({
              'user_id': uid,
              'local_id': localId,
              'created_at': goal.createdAt.toUtc().toIso8601String(),
              ...payload,
            })
            .select()
            .single();
      }
    } on PostgrestException catch (error) {
      if (error.code != '23505') throw mapSupabaseError(error);
      row = await _support
          .client()
          .from('user_goals')
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
      goalsCacheEntityType,
      () => _mirrorGoal(row!, preferredLocalId: inserted ? localId : null),
    );
    return _goalFromRow(row);
  }

  @override
  Future<void> delete(String id) async {
    final uid = await _support.requireUserId();
    final deletedAt = DateTime.now().toUtc().toIso8601String();
    try {
      final serverId = await _support.resolveServerEntityId(
        localTable: 'goals',
        serverTable: 'user_goals',
        userId: uid,
        entityId: id,
      );
      if (serverId == null) throw const NotFoundRepoException();
      final row = await _support
          .client()
          .from('user_goals')
          .update({'deleted_at': deletedAt, 'status': 'archived'})
          .eq('user_id', uid)
          .eq('id', serverId)
          .select('id')
          .maybeSingle();
      if (row == null) throw const NotFoundRepoException();
      await mirrorFinancialCacheSafely(
        _support.db,
        goalsCacheEntityType,
        () => _support.db.customStatement(
          "UPDATE goals SET deleted_at = ?, status = 'archived', sync_status = 'synced' WHERE server_id = ?;",
          [deletedAt, serverId],
        ),
      );
    } catch (error) {
      if (error is RepoException) rethrow;
      throw mapSupabaseError(error);
    }
  }

  @override
  Future<List<GoalContributionEntity>> getContributions(String goalId) async {
    final uid = await _support.requireUserId();
    try {
      final serverGoalId = await _support.resolveServerEntityId(
        localTable: 'goals',
        serverTable: 'user_goals',
        userId: uid,
        entityId: goalId,
      );
      if (serverGoalId == null) return const [];
      final rows = await _support
          .client()
          .from('user_goal_contributions')
          .select()
          .eq('user_id', uid)
          .eq('goal_id', serverGoalId)
          .isFilter('deleted_at', null)
          .order('created_at', ascending: false);
      return (rows as List)
          .map((row) => _contributionFromRow(
                Map<String, dynamic>.from(row as Map),
              ))
          .toList(growable: false);
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }

  @override
  Future<GoalContributionEntity> addContribution(
    GoalContributionEntity contribution,
  ) async {
    final uid = await _support.requireUserId();
    final requestId =
        contribution.id.isEmpty ? IdGenerator.next() : contribution.id;
    try {
      final serverGoalId = await _support.resolveServerEntityId(
        localTable: 'goals',
        serverTable: 'user_goals',
        userId: uid,
        entityId: contribution.goalId,
      );
      if (serverGoalId == null) throw const NotFoundRepoException();
      final response = await _support.client().rpc(
        'add_goal_contribution',
        params: {
          'p_goal_id': serverGoalId,
          'p_client_request_id': requestId,
          'p_local_id': requestId,
          'p_amount': contribution.amount,
          'p_created_at': contribution.createdAt.toUtc().toIso8601String(),
          'p_note': contribution.note,
        },
      );
      final result = Map<String, dynamic>.from(response as Map);
      final contributionRow = Map<String, dynamic>.from(
        result['contribution'] as Map,
      );
      final goalRow = Map<String, dynamic>.from(result['goal'] as Map);
      await mirrorFinancialCacheSafely(
        _support.db,
        goalsCacheEntityType,
        () async {
          await _mirrorGoal(goalRow);
          await _mirrorContribution(
            contributionRow,
            preferredLocalId: requestId,
          );
        },
      );
      return _contributionFromRow(contributionRow);
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }

  Future<void> repairLocalCache() async {
    final uid = await _support.requireUserId();
    try {
      final goals = await _support.allServerRows('user_goals', uid);
      final contributions =
          await _support.allServerRows('user_goal_contributions', uid);
      final now = dateTimeToSql(DateTime.now().toUtc());
      await _support.forEachMissingServerRow(
        localTable: 'goals',
        serverIds: goals.map((row) => row['id'] as String).toSet(),
        onMissing: (localId) => _support.db.customStatement(
          "UPDATE goals SET deleted_at = ?, status = 'archived', sync_status = 'synced' WHERE id = ?;",
          [now, localId],
        ),
      );
      for (final row in goals) {
        await _mirrorGoal(row);
      }
      await _support.forEachMissingServerRow(
        localTable: 'goal_contributions',
        serverIds: contributions.map((row) => row['id'] as String).toSet(),
        onMissing: (localId) => _support.db.customStatement(
          "UPDATE goal_contributions SET deleted_at = ?, sync_status = 'synced' WHERE id = ?;",
          [now, localId],
        ),
      );
      for (final row in contributions) {
        await _mirrorContribution(row);
      }
      await clearFinancialCacheDirty(_support.db, goalsCacheEntityType);
    } catch (error) {
      if (error is RepoException) rethrow;
      throw mapSupabaseError(error);
    }
  }

  GoalEntity _goalFromRow(Map<String, dynamic> row) {
    return GoalEntity(
      id: row['id'] as String,
      name: row['name'] as String,
      accountId: row['server_account_id'] as String?,
      targetAmount: (row['target_amount'] as num).toDouble(),
      savedAmount: (row['saved_amount'] as num).toDouble(),
      deadline: _date(row['deadline']),
      vaultSkin: row['vault_skin'] as String,
      status: row['status'] as String,
      createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
      autoSaveAmount: (row['auto_save_amount'] as num?)?.toDouble(),
      autoSavePeriod: row['auto_save_period'] as String?,
      autoSaveLastRun: _date(row['auto_save_last_run']),
    );
  }

  GoalContributionEntity _contributionFromRow(Map<String, dynamic> row) {
    return GoalContributionEntity(
      id: row['id'] as String,
      goalId: row['goal_id'] as String,
      amount: (row['amount'] as num).toDouble(),
      createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
      note: row['note'] as String?,
    );
  }

  DateTime? _date(Object? value) => value is String && value.isNotEmpty
      ? DateTime.tryParse(value)?.toUtc()
      : null;

  Future<void> _mirrorGoal(
    Map<String, dynamic> row, {
    String? preferredLocalId,
  }) async {
    final serverId = row['id'] as String;
    final localId = await _support.localIdForServer(
      table: 'goals',
      serverId: serverId,
      preferred: preferredLocalId ?? row['local_id'] as String?,
    );
    final accountId =
        await _support.localAccountId(row['server_account_id'] as String?);
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _support.db.customStatement('''
      INSERT INTO goals(
        id, name, account_id, target_amount, saved_amount, deadline,
        vault_skin, status, created_at, auto_save_amount, auto_save_period,
        auto_save_last_run, server_id, synced_at, server_updated_at,
        sync_status, deleted_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'synced', ?)
      ON CONFLICT(id) DO UPDATE SET
        name = excluded.name, account_id = excluded.account_id,
        target_amount = excluded.target_amount, saved_amount = excluded.saved_amount,
        deadline = excluded.deadline, vault_skin = excluded.vault_skin,
        status = excluded.status, auto_save_amount = excluded.auto_save_amount,
        auto_save_period = excluded.auto_save_period,
        auto_save_last_run = excluded.auto_save_last_run,
        server_id = excluded.server_id, synced_at = excluded.synced_at,
        server_updated_at = excluded.server_updated_at,
        sync_status = 'synced', deleted_at = excluded.deleted_at;
    ''', [
      localId,
      row['name'] as String,
      accountId,
      (row['target_amount'] as num).toDouble(),
      (row['saved_amount'] as num).toDouble(),
      row['deadline'] as String?,
      row['vault_skin'] as String,
      row['status'] as String,
      row['created_at'] as String,
      (row['auto_save_amount'] as num?)?.toDouble(),
      row['auto_save_period'] as String?,
      row['auto_save_last_run'] as String?,
      serverId,
      now,
      row['updated_at'] as String,
      row['deleted_at'] as String?,
    ]);
  }

  Future<void> _mirrorContribution(
    Map<String, dynamic> row, {
    String? preferredLocalId,
  }) async {
    final goalLocal = await _support.localIdForServer(
      table: 'goals',
      serverId: row['goal_id'] as String,
    );
    final localId = await _support.localIdForServer(
      table: 'goal_contributions',
      serverId: row['id'] as String,
      preferred: preferredLocalId ?? row['local_id'] as String?,
    );
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _support.db.customStatement('''
      INSERT INTO goal_contributions(
        id, goal_id, amount, created_at, note, server_id, synced_at,
        server_updated_at, sync_status, deleted_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'synced', ?)
      ON CONFLICT(id) DO UPDATE SET
        goal_id = excluded.goal_id, amount = excluded.amount,
        created_at = excluded.created_at, note = excluded.note,
        server_id = excluded.server_id, synced_at = excluded.synced_at,
        server_updated_at = excluded.server_updated_at,
        sync_status = 'synced', deleted_at = excluded.deleted_at;
    ''', [
      localId,
      goalLocal,
      (row['amount'] as num).toDouble(),
      row['created_at'] as String,
      row['note'] as String?,
      row['id'] as String,
      now,
      row['updated_at'] as String,
      row['deleted_at'] as String?,
    ]);
  }
}
