import 'package:drift/drift.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/backend/supabase_config.dart';
import '../../core/utils/id_generator.dart';
import '../../domain/entities/budget_entity.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../db/app_database.dart';
import '../db/sql_value_codec.dart';

class SupabasePlanningSupport {
  SupabasePlanningSupport({
    required this.db,
    SupabaseClient Function()? getClient,
    Future<String?> Function()? getAuthUserId,
  })  : client = getClient ?? (() => Supabase.instance.client),
        getAuthUserId = getAuthUserId ?? _defaultUserId;

  final AppDatabase db;
  final SupabaseClient Function() client;
  final Future<String?> Function() getAuthUserId;

  static Future<String?> _defaultUserId() async {
    if (!SupabaseConfig.isConfigured) return null;
    return Supabase.instance.client.auth.currentUser?.id;
  }

  Future<String> requireUserId() async {
    final uid = await getAuthUserId();
    if (uid == null) throw const AuthRepoException();
    return uid;
  }

  Future<List<Map<String, dynamic>>> allServerRows(
    String table,
    String userId,
  ) async {
    final rows = await client().from(table).select().eq('user_id', userId);
    return (rows as List)
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList(growable: false);
  }

  Future<void> forEachMissingServerRow({
    required String localTable,
    required Set<String> serverIds,
    required Future<void> Function(String localId) onMissing,
  }) async {
    final cached = await db
        .customSelect(
          'SELECT id, server_id FROM $localTable WHERE server_id IS NOT NULL;',
        )
        .get();
    for (final row in cached) {
      if (serverIds.contains(row.read<String>('server_id'))) continue;
      await onMissing(row.read<String>('id'));
    }
  }

  Future<String> localIdForServer({
    required String table,
    required String serverId,
    String? preferred,
  }) async {
    if (preferred != null && preferred.isNotEmpty) return preferred;
    final row = await db.customSelect(
      'SELECT id FROM $table WHERE server_id = ? LIMIT 1;',
      variables: [Variable.withString(serverId)],
    ).getSingleOrNull();
    return row?.readNullable<String>('id') ?? IdGenerator.next();
  }

  Future<String?> localAccountId(String? serverId) async {
    if (serverId == null) return null;
    final row = await db.customSelect(
      'SELECT id FROM accounts WHERE server_id = ? LIMIT 1;',
      variables: [Variable.withString(serverId)],
    ).getSingleOrNull();
    return row?.readNullable<String>('id');
  }

  Future<String?> serverAccountId(String? accountId) async {
    if (accountId == null) return null;
    final row = await db.customSelect(
      'SELECT server_id FROM accounts WHERE id = ? OR server_id = ? LIMIT 1;',
      variables: [
        Variable.withString(accountId),
        Variable.withString(accountId),
      ],
    ).getSingleOrNull();
    final serverId = row?.readNullable<String>('server_id');
    if (serverId == null) {
      throw const ValidationRepoException(
        'Account must be migrated before this financial item.',
      );
    }
    return serverId;
  }

  Future<String> categoryKey(String categoryId) async {
    if (categoryId == BudgetEntity.allExpensesCategoryId) {
      return BudgetEntity.allExpensesCategoryKey;
    }
    final row = await db.customSelect(
      'SELECT key FROM categories WHERE id = ? OR key = ? LIMIT 1;',
      variables: [
        Variable.withString(categoryId),
        Variable.withString(categoryId),
      ],
    ).getSingleOrNull();
    return row?.readNullable<String>('key') ?? categoryId;
  }

  Future<String> localCategoryId(String categoryKey) async {
    if (categoryKey == BudgetEntity.allExpensesCategoryKey) {
      return BudgetEntity.allExpensesCategoryId;
    }
    final row = await db.customSelect(
      'SELECT id FROM categories WHERE key = ? LIMIT 1;',
      variables: [Variable.withString(categoryKey)],
    ).getSingleOrNull();
    return row?.readNullable<String>('id') ?? categoryKey;
  }

  Future<String> localMerchantId(String name) async {
    final normalized = AppDatabase.normalizeMerchant(name);
    final existing = await db.customSelect(
      'SELECT id FROM merchants WHERE normalized_name = ? LIMIT 1;',
      variables: [Variable.withString(normalized)],
    ).getSingleOrNull();
    if (existing != null) return existing.read<String>('id');
    final id = IdGenerator.next();
    final now = dateTimeToSql(DateTime.now().toUtc());
    await db.customStatement(
      'INSERT INTO merchants(id, raw_name, normalized_name, first_seen_at, last_seen_at) '
      'VALUES (?, ?, ?, ?, ?);',
      [id, name, normalized, now, now],
    );
    return id;
  }
}
