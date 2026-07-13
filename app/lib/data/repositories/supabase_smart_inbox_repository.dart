import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../domain/entities/smart_inbox_item_entity.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../../domain/repositories/smart_inbox_repository.dart';
import '../db/app_database.dart';
import '../db/financial_cache_health.dart';
import '../db/sql_value_codec.dart';
import 'supabase_planning_support.dart';

class SupabaseSmartInboxRepository implements SmartInboxRepository {
  SupabaseSmartInboxRepository({
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
  Future<List<SmartInboxItemEntity>> getOpen() async {
    final uid = await _support.requireUserId();
    try {
      final rows = await _support
          .client()
          .from('user_smart_inbox')
          .select()
          .eq('user_id', uid)
          .eq('status', 'open')
          .isFilter('deleted_at', null)
          .order('created_at', ascending: false)
          .limit(200);
      final result = <SmartInboxItemEntity>[];
      for (final raw in rows as List) {
        final row = Map<String, dynamic>.from(raw as Map);
        if (!_knownTypes.contains(row['type'])) continue;
        await mirrorFinancialCacheSafely(
          _support.db,
          smartInboxCacheEntityType,
          () => _mirror(row),
        );
        result.add(_fromRow(row));
      }
      return result;
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }

  @override
  Future<void> dismiss(String id) => _setStatus(id, 'dismissed');

  @override
  Future<void> resolve(String id) => _setStatus(id, 'resolved');

  Future<void> _setStatus(String id, String status) async {
    final uid = await _support.requireUserId();
    try {
      final row = await _support
          .client()
          .from('user_smart_inbox')
          .update({'status': status})
          .eq('user_id', uid)
          .eq('id', id)
          .select()
          .maybeSingle();
      if (row == null) throw const NotFoundRepoException();
      await mirrorFinancialCacheSafely(
        _support.db,
        smartInboxCacheEntityType,
        () => _mirror(row),
      );
    } catch (error) {
      if (error is RepoException) rethrow;
      throw mapSupabaseError(error);
    }
  }

  Future<void> repairLocalCache() async {
    final uid = await _support.requireUserId();
    try {
      final rows = (await _support.allServerRows('user_smart_inbox', uid))
          .where((row) => _knownTypes.contains(row['type']))
          .toList(growable: false);
      final serverIds = rows.map((row) => row['id'] as String).toSet();
      final now = dateTimeToSql(DateTime.now().toUtc());
      await _support.forEachMissingServerRow(
        localTable: 'smart_inbox_items',
        serverIds: serverIds,
        onMissing: (localId) => _support.db.customStatement(
          "UPDATE smart_inbox_items SET status = 'dismissed', dismissed_locally = 1, updated_at = ? WHERE id = ?;",
          [now, localId],
        ),
      );
      for (final row in rows) {
        await _mirror(row);
      }
      await clearFinancialCacheDirty(_support.db, smartInboxCacheEntityType);
    } catch (error) {
      if (error is RepoException) rethrow;
      throw mapSupabaseError(error);
    }
  }

  Future<void> _mirror(Map<String, dynamic> row) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    final serverId = row['id'] as String;
    final status = row['deleted_at'] == null
        ? row['status'] as String? ?? 'open'
        : 'dismissed';
    await _support.db.customStatement('''
      INSERT INTO smart_inbox_items(
        id, server_id, transaction_id, payload_id, type, title, body, status,
        confidence, metadata_json, server_created_at, server_updated_at,
        synced_at, dismissed_locally, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(server_id) DO UPDATE SET
        transaction_id = excluded.transaction_id,
        payload_id = excluded.payload_id, type = excluded.type,
        title = excluded.title, body = excluded.body,
        status = excluded.status, confidence = excluded.confidence,
        metadata_json = excluded.metadata_json,
        server_updated_at = excluded.server_updated_at,
        synced_at = excluded.synced_at, updated_at = excluded.updated_at;
    ''', [
      serverId,
      serverId,
      row['transaction_id'] as String?,
      row['payload_id'] as String?,
      row['type'] as String,
      row['title'] as String,
      row['body'] as String?,
      status,
      (row['confidence'] as num?)?.toDouble(),
      jsonEncode(row['metadata'] ?? const <String, dynamic>{}),
      row['created_at'] as String,
      row['updated_at'] as String?,
      now,
      status == 'dismissed' ? 1 : 0,
      now,
      now,
    ]);
  }

  SmartInboxItemEntity _fromRow(Map<String, dynamic> row) =>
      SmartInboxItemEntity(
        id: row['id'] as String,
        transactionId: row['transaction_id'] as String?,
        payloadId: row['payload_id'] as String?,
        type: row['type'] as String,
        title: row['title'] as String,
        body: row['body'] as String?,
        status: row['status'] as String? ?? 'open',
        confidence: (row['confidence'] as num?)?.toDouble(),
        createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
      );
}

const _knownTypes = {
  'needs_review',
  'suspicious_duplicate',
  'low_confidence',
  'budget_warning',
  'insight',
};
