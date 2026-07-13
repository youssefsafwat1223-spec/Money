import 'package:drift/drift.dart' show Variable;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/sql_value_codec.dart';
import '../../../domain/errors/repo_exceptions.dart';

class AccountBackfillReport {
  const AccountBackfillReport({
    required this.total,
    required this.created,
    required this.matched,
    required this.mismatchedLocalIds,
    required this.defaultResolved,
    required this.defaultWarning,
  });

  final int total;
  final int created;
  final int matched;
  final List<String> mismatchedLocalIds;
  final bool defaultResolved;
  final String? defaultWarning;

  bool get isClean => mismatchedLocalIds.isEmpty && defaultWarning == null;
}

/// يُرحِّل كل الحسابات المحلية (Drift) إلى user_accounts — بلا ثقة بعمود
/// sync_status (قد يكون قديمًا/غير متسق)، ويشمل الحسابات المحذوفة محليًا
/// (tombstones) حتى لا تُعاد كحسابات نشطة لاحقًا بالخطأ. يجب أن يكتمل
/// وينجح قبل بدء ترحيل العمليات (TransactionsBackfillService).
class AccountsBackfillService {
  AccountsBackfillService({
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

  Future<AccountBackfillReport> run() async {
    final uid = await _getAuthUserId();
    if (uid == null) throw const AuthRepoException();

    // كل الحسابات المحلية — بلا فلترة على sync_status أو deleted_at.
    final localRows = await _db.customSelect('SELECT * FROM accounts;').get();

    var created = 0;
    var matched = 0;
    final mismatched = <String>[];

    for (final local in localRows) {
      final localId = local.read<String>('id');
      final deletedAt = local.readNullable<String>('deleted_at');
      final payload = {
        'user_id': uid,
        'local_id': localId,
        'name': local.read<String>('name'),
        'currency': local.read<String>('currency'),
        'type': local.read<String>('type'),
        'initial_balance': local.readNullable<double>('initial_balance'),
        'current_balance': local.readNullable<double>('current_balance'),
        'is_default': false, // مرحَّل دائمًا false — يُحسم لاحقًا عبر RPC ذرّي
        'sort_order': local.read<int>('sort_order'),
        'created_at': local.read<String>('created_at'),
        'deleted_at': deletedAt, // يحافظ على حالة tombstone كما هي محليًا
      };

      Map<String, dynamic> serverRow;
      try {
        final existing = await _getClient()
            .from('user_accounts')
            .select()
            .eq('user_id', uid)
            .eq('local_id', localId)
            .maybeSingle();
        if (existing != null) {
          serverRow = existing;
          matched++;
        } else {
          serverRow = await _getClient()
              .from('user_accounts')
              .insert(payload)
              .select()
              .single();
          created++;
        }
      } catch (e) {
        throw mapSupabaseError(e);
      }

      final mismatch = serverRow['name'] != payload['name'] ||
          serverRow['currency'] != payload['currency'] ||
          serverRow['type'] != payload['type'] ||
          (serverRow['initial_balance'] as num?)?.toDouble() !=
              payload['initial_balance'] ||
          (serverRow['current_balance'] as num?)?.toDouble() !=
              payload['current_balance'] ||
          serverRow['deleted_at'] != payload['deleted_at'];
      if (mismatch) mismatched.add(localId);

      await _db.customStatement(
        '''
          UPDATE accounts
          SET server_id = ?, synced_at = ?, sync_status = 'synced'
          WHERE id = ?;
        ''',
        [
          serverRow['id'] as String,
          dateTimeToSql(DateTime.now().toUtc()),
          localId,
        ],
      );
    }

    final resolution = await _resolveDefault(uid);

    return AccountBackfillReport(
      total: localRows.length,
      created: created,
      matched: matched,
      mismatchedLocalIds: mismatched,
      defaultResolved: resolution == null,
      defaultWarning: resolution,
    );
  }

  /// يحسم الحساب الافتراضي بعد الترحيل عبر set_default_account (RPC ذرّي)
  /// — لا نرحّل is_default=true مباشرة لتفادي انتهاك الفهرس الجزئي
  /// (حساب افتراضي نشط واحد لكل مستخدم) إن كانت البيانات المحلية غير متسقة.
  /// يعيد رسالة تحذير نصية إن لم يوجد حساب افتراضي محلي واحد بوضوح، ولا
  /// يخمّن أيًا كان.
  Future<String?> _resolveDefault(String uid) async {
    final defaults = await _db
        .customSelect(
          "SELECT id FROM accounts WHERE is_default = 1 AND deleted_at IS NULL;",
        )
        .get();
    if (defaults.length != 1) {
      return 'Expected exactly one local default account, found ${defaults.length}; '
          'skipped default resolution — must be fixed manually before enabling the flag.';
    }
    final localId = defaults.first.read<String>('id');
    final serverIdRow = await _db.customSelect(
      'SELECT server_id FROM accounts WHERE id = ? LIMIT 1;',
      variables: [Variable.withString(localId)],
    ).getSingleOrNull();
    final serverId = serverIdRow?.readNullable<String>('server_id');
    if (serverId == null) {
      return 'Default local account $localId has no server_id after backfill — skipped.';
    }
    try {
      final response = await _getClient()
          .rpc('set_default_account', params: {'p_account_id': serverId});
      final row = response as Map<String, dynamic>;
      await _db.customStatement(
        "UPDATE accounts SET is_default = 1 WHERE id = ?;",
        [localId],
      );
      await _db.customStatement(
        "UPDATE accounts SET is_default = 0 WHERE id != ? AND deleted_at IS NULL;",
        [localId],
      );
      return row['id'] == serverId
          ? null
          : 'set_default_account returned an unexpected row.';
    } catch (e) {
      return 'set_default_account failed during backfill: $e';
    }
  }
}
