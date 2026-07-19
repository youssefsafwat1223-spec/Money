import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/backend/supabase_config.dart';
import '../../core/utils/id_generator.dart';
import '../../domain/entities/category_entity.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../../domain/repositories/category_repository.dart';
import '../db/app_database.dart';
import '../db/sql_value_codec.dart';
import 'drift_category_repository.dart';

/// Server-first repository for user-owned categories. Qirsh's built-in
/// catalog remains local/shared; only `custom_*` rows are stored per user.
class SupabaseCategoryRepository implements CategoryRepository {
  SupabaseCategoryRepository({
    required AppDatabase db,
    SupabaseClient Function()? getClient,
    Future<String?> Function()? getAuthUserId,
  })  : _db = db,
        _getClient = getClient ?? (() => Supabase.instance.client),
        _getAuthUserId = getAuthUserId ?? _defaultUserId;

  final AppDatabase _db;
  final SupabaseClient Function() _getClient;
  final Future<String?> Function() _getAuthUserId;

  static Future<String?> _defaultUserId() async {
    if (!SupabaseConfig.isConfigured) return null;
    try {
      return Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  Future<String> _requireUserId() async {
    final value = await _getAuthUserId();
    if (value == null) throw const AuthRepoException();
    return value;
  }

  @override
  Future<List<CategoryEntity>> getAll() async {
    final uid = await _requireUserId();
    try {
      final rows = await _getClient()
          .from('user_categories')
          .select()
          .eq('user_id', uid)
          .isFilter('deleted_at', null)
          .order('sort_order');
      final activeServerIds = <String>{};
      for (final raw in rows as List) {
        final row = raw as Map<String, dynamic>;
        activeServerIds.add(row['id'] as String);
        await _mirror(row);
      }
      final mirrored = await _db.customSelect('''
        SELECT id, server_id FROM categories
        WHERE server_id IS NOT NULL
          AND key GLOB 'custom_*'
          AND deleted_at IS NULL;
      ''').get();
      final now = dateTimeToSql(DateTime.now().toUtc());
      for (final row in mirrored) {
        final serverId = row.read<String>('server_id');
        if (!activeServerIds.contains(serverId)) {
          await _db.customStatement(
            'UPDATE categories SET deleted_at = ?, sync_status = ? WHERE id = ?;',
            [now, 'synced', row.read<String>('id')],
          );
        }
      }
      final local = await DriftCategoryRepository(_db).getAll();
      return local;
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }

  @override
  Future<CategoryEntity> createCategory({
    required String nameAr,
    required String icon,
    required String color,
    required bool isIncome,
  }) async {
    final uid = await _requireUserId();
    final localId = IdGenerator.next();
    final key = 'custom_${_slug(nameAr)}_${localId.substring(0, 6)}';
    try {
      final row = await _getClient()
          .from('user_categories')
          .insert({
            'user_id': uid,
            'local_id': localId,
            'key': key,
            'name_ar': nameAr.trim(),
            'icon': icon,
            'color': color,
            'is_income': isIncome,
            'sort_order': await _nextSort(),
          })
          .select()
          .single();
      await _mirror(row);
      return _entity(row);
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }

  @override
  Future<CategoryEntity> updateCategory(CategoryEntity category) async {
    final uid = await _requireUserId();
    try {
      final row = await _getClient()
          .from('user_categories')
          .update({
            'name_ar': category.nameAr.trim(),
            'icon': category.icon,
            'color': category.color,
            'is_income': category.isIncome,
            'sort_order': category.sort,
          })
          .eq('user_id', uid)
          .eq('id', category.id)
          .select()
          .maybeSingle();
      if (row == null) throw const NotFoundRepoException();
      await _mirror(row);
      return _entity(row);
    } catch (error) {
      if (error is RepoException) rethrow;
      throw mapSupabaseError(error);
    }
  }

  @override
  Future<void> deleteCategory(String id) async {
    final uid = await _requireUserId();
    try {
      final response = await _getClient().rpc(
        'delete_user_category_safely',
        params: {'p_category_id': id},
      );
      if (response == null) throw const NotFoundRepoException();
      await _db.customStatement(
        'UPDATE categories SET deleted_at = ? WHERE server_id = ? OR id = ?;',
        [dateTimeToSql(DateTime.now().toUtc()), id, id],
      );
      // Keep uid evaluation server-authoritative; this line also prevents an
      // accidental future call path from treating an anonymous client as OK.
      if (uid.isEmpty) throw const AuthRepoException();
    } catch (error) {
      if (error is RepoException) rethrow;
      throw mapSupabaseError(error);
    }
  }

  Future<int> _nextSort() async {
    final row = await _db
        .customSelect(
          'SELECT COALESCE(MAX(sort_order),0)+1 AS value FROM categories;',
        )
        .getSingle();
    return row.read<int>('value');
  }

  Future<void> _mirror(Map<String, dynamic> row) async {
    final id = row['id'] as String;
    await _db.customStatement('''
      INSERT INTO categories(id,key,name_ar,icon,color,is_income,sort_order,
        server_id,synced_at,server_updated_at,sync_status,deleted_at)
      VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET key=excluded.key,name_ar=excluded.name_ar,
        icon=excluded.icon,color=excluded.color,is_income=excluded.is_income,
        sort_order=excluded.sort_order,server_id=excluded.server_id,
        synced_at=excluded.synced_at,server_updated_at=excluded.server_updated_at,
        sync_status='synced',deleted_at=excluded.deleted_at;
    ''', [
      id,
      row['key'],
      row['name_ar'],
      row['icon'],
      row['color'],
      (row['is_income'] as bool? ?? false) ? 1 : 0,
      row['sort_order'] ?? 0,
      id,
      dateTimeToSql(DateTime.now().toUtc()),
      row['updated_at'],
      'synced',
      row['deleted_at'],
    ]);
  }

  CategoryEntity _entity(Map<String, dynamic> row) => CategoryEntity(
        id: row['id'] as String,
        key: row['key'] as String,
        nameAr: row['name_ar'] as String,
        icon: row['icon'] as String,
        color: row['color'] as String,
        isIncome: row['is_income'] as bool? ?? false,
        sort: row['sort_order'] as int? ?? 0,
      );

  String _slug(String value) => value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9\u0600-\u06ff]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');
}
