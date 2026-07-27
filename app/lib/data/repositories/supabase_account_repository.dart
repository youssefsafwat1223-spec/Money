import 'dart:convert';

import 'package:drift/drift.dart' show Variable;
import 'package:postgrest/postgrest.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/backend/supabase_config.dart';
import '../../core/utils/id_generator.dart';
import '../../domain/entities/account_entity.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../../domain/repositories/account_repository.dart';
import '../db/app_database.dart';
import '../db/financial_cache_health.dart';
import '../db/sql_value_codec.dart';

/// مستودع الحسابات المباشر على Supabase — يُستخدم فقط عندما تكون علامة
/// accounts_supabase_primary مفعّلة لهذا المستخدم. القراءة والكتابة كلاهما
/// مباشر على user_accounts (لا اعتماد على Drift إلا كمرآة كاش بعد النجاح،
/// أنظر _mirror*).
class SupabaseAccountRepository implements AccountRepository {
  SupabaseAccountRepository({
    required AppDatabase db,
    SupabaseClient Function()? getClient,
    Future<String?> Function()? getAuthUserId,
  })  : _db = db,
        _getClient = getClient ?? (() => Supabase.instance.client),
        _getAuthUserId = getAuthUserId ?? _defaultGetAuthUserId;

  final AppDatabase _db;
  final SupabaseClient Function() _getClient;
  final Future<String?> Function() _getAuthUserId;

  static Future<String?> _defaultGetAuthUserId() async {
    if (!SupabaseConfig.isConfigured) return null;
    try {
      return Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  Future<String> _requireUserId() async {
    final uid = await _getAuthUserId();
    if (uid == null) throw const AuthRepoException();
    return uid;
  }

  // ── قراءة ──

  @override
  Future<List<AccountEntity>> getAll() async {
    final uid = await _requireUserId();
    try {
      final rows = await _getClient()
          .from('user_accounts')
          .select()
          .eq('user_id', uid)
          .isFilter('deleted_at', null)
          .order('sort_order')
          .order('created_at');
      return (rows as List)
          .map((r) => _fromServerRow(r as Map<String, dynamic>))
          .toList();
    } catch (e) {
      throw mapSupabaseError(e);
    }
  }

  @override
  Future<AccountEntity?> getById(String id) async {
    final uid = await _requireUserId();
    try {
      final row = await _getClient()
          .from('user_accounts')
          .select()
          .eq('user_id', uid)
          .eq('id', id)
          .isFilter('deleted_at', null)
          .maybeSingle();
      return row == null ? null : _fromServerRow(row);
    } catch (e) {
      throw mapSupabaseError(e);
    }
  }

  @override
  Future<AccountEntity?> getDefault() async {
    final uid = await _requireUserId();
    try {
      final row = await _getClient()
          .from('user_accounts')
          .select()
          .eq('user_id', uid)
          .eq('is_default', true)
          .isFilter('deleted_at', null)
          .maybeSingle();
      return row == null ? null : _fromServerRow(row);
    } catch (e) {
      throw mapSupabaseError(e);
    }
  }

  // ── كتابة ──

  @override
  Future<AccountEntity> create(AccountEntity account) async {
    final uid = await _requireUserId();
    // يُولَّد المعرّف المحلي مرّة واحدة قبل أي طلب شبكة — لا يُعاد توليده
    // أبدًا بعد بدء الطلب (حتى عند إعادة المحاولة).
    final localId = account.id.isEmpty ? IdGenerator.next() : account.id;

    Map<String, dynamic> row;
    try {
      row = await _getClient()
          .from('user_accounts')
          .insert({
            'user_id': uid,
            'local_id': localId,
            'name': account.name,
            'currency': account.currency,
            'type': account.type.name,
            'initial_balance': account.initialBalance,
            'current_balance': account.currentBalance,
            'is_default': false,
            'sort_order': account.sortOrder,
            ..._extendedFields(account),
          })
          .select()
          .single();
    } on PostgrestException catch (e) {
      if (e.code == '23505') {
        // تعافي من التكرار: إعادة محاولة بعد timeout قد تكون أرسلت الصف
        // بالفعل — نجلبه ونعيده، لا نُحدّثه أبدًا هنا.
        final existing = await _getClient()
            .from('user_accounts')
            .select()
            .eq('user_id', uid)
            .eq('local_id', localId)
            .maybeSingle();
        if (existing == null) throw mapSupabaseError(e);
        row = existing;
      } else {
        throw mapSupabaseError(e);
      }
    } catch (e) {
      throw mapSupabaseError(e);
    }

    final isFirstAccount = await _activeAccountCount(uid) <= 1;
    if (account.isDefault || isFirstAccount) {
      try {
        final response = await _getClient()
            .rpc('set_default_account', params: {'p_account_id': row['id']});
        row = response as Map<String, dynamic>;
      } catch (e) {
        throw mapSupabaseError(e);
      }
      await _mirrorFullDefaultChange(row);
    } else {
      await _mirrorUpsertRow(localId: localId, row: row);
    }

    return _fromServerRow(row);
  }

  @override
  Future<AccountEntity> update(AccountEntity account) async {
    final uid = await _requireUserId();
    Map<String, dynamic>? row;
    try {
      row = await _getClient()
          .from('user_accounts')
          .update({
            'name': account.name,
            'currency': account.currency,
            'type': account.type.name,
            'initial_balance': account.initialBalance,
            'current_balance': account.currentBalance,
            'sort_order': account.sortOrder,
            ..._extendedFields(account),
          })
          .eq('user_id', uid)
          .eq('id', account.id)
          .select()
          .maybeSingle();
    } catch (e) {
      throw mapSupabaseError(e);
    }
    if (row == null) throw const NotFoundRepoException();
    await _mirrorUpsertRow(localId: null, row: row);
    return _fromServerRow(row);
  }

  @override
  Future<void> delete(String id) async {
    await _requireUserId();
    try {
      await _getClient().rpc(
        'delete_user_account_safely',
        params: {'p_account_id': id},
      );
    } catch (e) {
      throw mapSupabaseError(e);
    }
    await _mirrorDeleteByServerId(id);
  }

  @override
  Future<void> setDefault(String id) async {
    Map<String, dynamic> row;
    try {
      final response = await _getClient()
          .rpc('set_default_account', params: {'p_account_id': id});
      row = response as Map<String, dynamic>;
    } catch (e) {
      throw mapSupabaseError(e);
    }
    await _mirrorFullDefaultChange(row);
  }

  /// عملية إصلاح كاش لمرّة واحدة: تجلب كل صفوف Supabase الموثوقة لهذا
  /// المستخدم وتُعيد بناء مرآة Drift منها بالكامل — تُستدعى بعد فشل مرآة
  /// (financial_cache_dirty=true) لإعادة الثقة بالكاش قبل السماح بتراجع
  /// آمن لعلامة الميزة. لا تُستخدم كمسار قراءة عادي.
  Future<void> repairLocalCache() async {
    final uid = await _requireUserId();
    List<dynamic> rows;
    try {
      rows =
          await _getClient().from('user_accounts').select().eq('user_id', uid);
    } catch (e) {
      throw mapSupabaseError(e);
    }
    final serverIds = rows.map((row) => row['id'] as String).toSet();
    final cached = await _db
        .customSelect(
          'SELECT id, server_id FROM accounts WHERE server_id IS NOT NULL;',
        )
        .get();
    final now = dateTimeToSql(DateTime.now().toUtc());
    for (final local in cached) {
      final serverId = local.read<String>('server_id');
      if (serverIds.contains(serverId)) continue;
      await _db.customStatement(
        '''
          UPDATE accounts
          SET deleted_at = ?, is_default = 0, sync_status = 'synced'
          WHERE id = ?;
        ''',
        [now, local.read<String>('id')],
      );
    }
    for (final rawRow in rows) {
      final row = rawRow as Map<String, dynamic>;
      await _mirrorUpsertRow(
        localId: row['local_id'] as String?,
        row: row,
      );
    }
    await clearFinancialCacheDirty(_db, accountsCacheEntityType);
  }

  Future<int> _activeAccountCount(String uid) async {
    try {
      final rows = await _getClient()
          .from('user_accounts')
          .select('id')
          .eq('user_id', uid)
          .isFilter('deleted_at', null);
      return (rows as List).length;
    } catch (e) {
      throw mapSupabaseError(e);
    }
  }

  // ── مرآة الكاش المحلي (Drift) — بعد النجاح فقط، لسلامة التراجع المؤقتة ──

  /// الحقول الممتدة للإرسال إلى Supabase (insert/update). metadata كـ jsonb
  /// (Map)، والباقي أعمدة قياسية. آمنة رجعيًا: قيم null/false للحسابات القديمة.
  Map<String, dynamic> _extendedFields(AccountEntity account) => {
        'bank_account_number': account.bankAccountNumber,
        'credit_limit': account.creditLimit,
        'available_credit': account.availableCredit,
        'payment_due_day': account.paymentDueDay,
        'wallet_provider': account.walletProvider,
        'exclude_from_totals': account.excludeFromTotals,
        'metadata': account.metadata,
      };

  AccountEntity _fromServerRow(Map<String, dynamic> row) {
    return AccountEntity(
      id: row['id'] as String,
      name: row['name'] as String,
      currency: row['currency'] as String,
      type: accountTypeFromKey(row['type'] as String),
      initialBalance: (row['initial_balance'] as num?)?.toDouble(),
      currentBalance: (row['current_balance'] as num?)?.toDouble(),
      bankAccountNumber: row['bank_account_number'] as String?,
      creditLimit: (row['credit_limit'] as num?)?.toDouble(),
      availableCredit: (row['available_credit'] as num?)?.toDouble(),
      paymentDueDay: (row['payment_due_day'] as num?)?.toInt(),
      walletProvider: row['wallet_provider'] as String?,
      excludeFromTotals: row['exclude_from_totals'] as bool? ?? false,
      metadata: row['metadata'] is Map<String, dynamic>
          ? row['metadata'] as Map<String, dynamic>
          : null,
      isDefault: row['is_default'] as bool? ?? false,
      sortOrder: row['sort_order'] as int? ?? 0,
      createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
      updatedAt: DateTime.parse(row['updated_at'] as String).toUtc(),
    );
  }

  Future<String?> _localIdForServerId(String serverId) async {
    final row = await _db.customSelect(
      'SELECT id FROM accounts WHERE server_id = ? LIMIT 1;',
      variables: [Variable.withString(serverId)],
    ).getSingleOrNull();
    return row?.readNullable<String>('id');
  }

  /// يُدرج/يُحدّث صفًا واحدًا في الكاش المحلي بعد نجاح إنشاء/تعديل عبر
  /// Supabase. [localId] معروف فقط عند الإنشاء (نفس المعرّف المُرسَل كـ
  /// local_id)؛ عند التعديل نبحث عنه عبر server_id، وإن لم نجده (صف لم
  /// يُمرَّر محليًا من قبل) نولّد معرّفًا محليًا جديدًا للكاش فقط — هذا لا
  /// يمسّ مفتاح المطابقة مع الخادم (local_id/server_id) بأي شكل.
  Future<void> _mirrorUpsertRow({
    required String? localId,
    required Map<String, dynamic> row,
  }) async {
    try {
      final serverId = row['id'] as String;
      final resolvedLocalId =
          localId ?? await _localIdForServerId(serverId) ?? IdGenerator.next();
      final now = dateTimeToSql(DateTime.now().toUtc());
      final metadata = row['metadata'];
      await _db.customStatement(
        '''
          INSERT INTO accounts(
            id, name, currency, type, initial_balance, current_balance,
            bank_account_number, credit_limit, available_credit,
            payment_due_day, wallet_provider, exclude_from_totals, metadata,
            is_default, sort_order, created_at, updated_at,
            server_id, synced_at, server_updated_at, sync_status, deleted_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'synced', ?)
          ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            currency = excluded.currency,
            type = excluded.type,
            initial_balance = excluded.initial_balance,
            current_balance = excluded.current_balance,
            bank_account_number = excluded.bank_account_number,
            credit_limit = excluded.credit_limit,
            available_credit = excluded.available_credit,
            payment_due_day = excluded.payment_due_day,
            wallet_provider = excluded.wallet_provider,
            exclude_from_totals = excluded.exclude_from_totals,
            metadata = excluded.metadata,
            is_default = excluded.is_default,
            sort_order = excluded.sort_order,
            updated_at = excluded.updated_at,
            server_id = excluded.server_id,
            synced_at = excluded.synced_at,
            server_updated_at = excluded.server_updated_at,
            sync_status = 'synced',
            deleted_at = excluded.deleted_at;
        ''',
        [
          resolvedLocalId,
          row['name'] as String,
          row['currency'] as String,
          row['type'] as String,
          (row['initial_balance'] as num?)?.toDouble(),
          (row['current_balance'] as num?)?.toDouble(),
          row['bank_account_number'] as String?,
          (row['credit_limit'] as num?)?.toDouble(),
          (row['available_credit'] as num?)?.toDouble(),
          (row['payment_due_day'] as num?)?.toInt(),
          row['wallet_provider'] as String?,
          boolToSql(row['exclude_from_totals'] as bool? ?? false),
          metadata == null ? null : jsonEncode(metadata),
          boolToSql(row['is_default'] as bool? ?? false),
          row['sort_order'] as int? ?? 0,
          row['created_at'] as String,
          row['updated_at'] as String,
          serverId,
          now,
          row['updated_at'] as String,
          row['deleted_at'] as String?,
        ],
      );
      await clearFinancialCacheDirty(_db, accountsCacheEntityType);
    } catch (e) {
      await markFinancialCacheDirty(_db, accountsCacheEntityType, e);
    }
  }

  Future<void> _mirrorDeleteByServerId(String serverId) async {
    try {
      final localId = await _localIdForServerId(serverId);
      if (localId == null) return;
      final now = dateTimeToSql(DateTime.now().toUtc());
      await _db.customStatement(
        '''
          UPDATE accounts
          SET deleted_at = ?, is_default = 0, synced_at = ?, sync_status = 'synced'
          WHERE id = ?;
        ''',
        [now, now, localId],
      );
      await clearFinancialCacheDirty(_db, accountsCacheEntityType);
    } catch (e) {
      await markFinancialCacheDirty(_db, accountsCacheEntityType, e);
    }
  }

  /// يعكس تغيير الحساب الافتراضي بالكامل محليًا: مسح is_default عن كل
  /// حسابات المستخدم محليًا، ثم تفعيله فقط على الحساب المختار — بخطوة
  /// واحدة atomically، حتى لا يظهر حسابان افتراضيان محليًا إذا حدث تراجع
  /// (rollback) لاحقًا لعلامة الميزة.
  Future<void> _mirrorFullDefaultChange(
      Map<String, dynamic> selectedRow) async {
    try {
      await _db.transaction(() async {
        await _db.customStatement('UPDATE accounts SET is_default = 0;');
        final serverId = selectedRow['id'] as String;
        final localId = await _localIdForServerId(serverId);
        final now = dateTimeToSql(DateTime.now().toUtc());
        if (localId != null) {
          await _db.customStatement(
            '''
              UPDATE accounts
              SET is_default = 1, server_id = ?, synced_at = ?, sync_status = 'synced'
              WHERE id = ?;
            ''',
            [serverId, now, localId],
          );
        } else {
          await _mirrorUpsertRow(localId: IdGenerator.next(), row: selectedRow);
        }
      });
      await clearFinancialCacheDirty(_db, accountsCacheEntityType);
    } catch (e) {
      await markFinancialCacheDirty(_db, accountsCacheEntityType, e);
    }
  }
}
