import 'package:drift/drift.dart' show Variable;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../core/session/app_session.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/money_codec.dart';
import '../../../data/db/planning_cutover.dart';
import '../../../data/db/sql_value_codec.dart';
import '../../../domain/errors/repo_exceptions.dart';
import '../../../domain/finance/money.dart';
import '../../../domain/finance/money_transport.dart';

const _accountMoneySelect = '*, initial_balance_text:initial_balance::text, '
    'current_balance_text:current_balance::text, '
    'credit_limit_text:credit_limit::text, '
    'available_credit_text:available_credit::text';

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
    Future<String?> Function()? getLocalDataOwnerUid,
    // MALI-026 (B8-3 §13): read all account money as EXACT Money (from `_minor`,
    // never the REAL shadow as authority) and serialize canonical → exact decimal
    // STRING, matching the primary account outbox push (planning_outbox_queue).
    PlanningCutoverCoordinator coordinator =
        const SchemaV29PlanningCutoverCoordinator(),
  })  : _db = db,
        _getClient = getClient ?? (() => Supabase.instance.client),
        _getAuthUserId = getAuthUserId ?? _defaultGetAuthUserId,
        _getLocalDataOwnerUid =
            getLocalDataOwnerUid ?? AppSession.instance.readLocalDataOwnerUid,
        _coordinator = coordinator;

  final AppDatabase _db;
  final SupabaseClient Function() _getClient;
  final Future<String?> Function() _getAuthUserId;
  final Future<String?> Function() _getLocalDataOwnerUid;
  final PlanningCutoverCoordinator _coordinator;

  bool get _canonical => _coordinator.state() == PlanningCutoverState.canonical;

  /// Serialize a balance for the wire exactly as the primary push does:
  /// canonical → exact decimal STRING, legacy → JSON number.
  Object? _amountWireOrNull(Money? m) => _canonical
      ? moneyToNumericTextOrNull(m)
      : moneyToLegacyJsonNumberOrNull(m);

  static Future<String?> _defaultGetAuthUserId() async {
    if (!SupabaseConfig.isConfigured) return null;
    try {
      return Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  /// دفاع في العمق: يرفض الترحيل إن كانت البيانات المحلية مسجَّلة كملك لهوية
  /// Supabase مختلفة عن الهوية الحالية. انظر النسخة المطابقة في
  /// TransactionsBackfillService لشرح لماذا `null` مسموح به عمداً.
  Future<void> _assertLocalDataOwnership(String uid) async {
    final ownerUid = await _getLocalDataOwnerUid();
    if (ownerUid != null && ownerUid != uid) {
      throw const ValidationRepoException(
        'Local accounts are recorded as owned by a different signed-in '
        'identity than the one currently authenticated — refusing to '
        'upload them to avoid cross-account data leakage.',
      );
    }
  }

  Future<AccountBackfillReport> run() async {
    final uid = await _getAuthUserId();
    if (uid == null) throw const AuthRepoException();
    await _assertLocalDataOwnership(uid);

    // كل الحسابات المحلية — بلا فلترة على sync_status أو deleted_at.
    final localRows = await _db.customSelect('SELECT * FROM accounts;').get();

    var created = 0;
    var matched = 0;
    final mismatched = <String>[];

    for (final local in localRows) {
      final localId = local.read<String>('id');
      final deletedAt = local.readNullable<String>('deleted_at');
      final currency = local.read<String>('currency');
      final initialM =
          kMoneyCodec.readColumnNullable(local, 'initial_balance', currency);
      final currentM =
          kMoneyCodec.readColumnNullable(local, 'current_balance', currency);
      final creditLimitM =
          kMoneyCodec.readColumnNullable(local, 'credit_limit', currency);
      final availableCreditM =
          kMoneyCodec.readColumnNullable(local, 'available_credit', currency);
      final payload = {
        'user_id': uid,
        'local_id': localId,
        'name': local.read<String>('name'),
        'currency': currency,
        'type': local.read<String>('type'),
        'initial_balance': _amountWireOrNull(initialM),
        'current_balance': _amountWireOrNull(currentM),
        'credit_limit': _amountWireOrNull(creditLimitM),
        'available_credit': _amountWireOrNull(availableCreditM),
        'is_default': false, // مرحَّل دائمًا false — يُحسم لاحقًا عبر RPC ذرّي
        'sort_order': local.read<int>('sort_order'),
        'created_at': local.read<String>('created_at'),
        'deleted_at': deletedAt, // يحافظ على حالة tombstone كما هي محليًا
      };

      Map<String, dynamic> serverRow;
      try {
        final existing = await _getClient()
            .from('user_accounts')
            .select(_accountMoneySelect)
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
              .select(_accountMoneySelect)
              .single();
          created++;
        }
      } catch (e) {
        throw mapSupabaseError(e);
      }

      final mismatch = serverRow['name'] != payload['name'] ||
          !_requiredCurrencyMatches(serverRow['currency'], currency) ||
          serverRow['type'] != payload['type'] ||
          !_moneyTextMatches(
              serverRow, 'initial_balance_text', initialM, currency) ||
          !_moneyTextMatches(
              serverRow, 'current_balance_text', currentM, currency) ||
          !_moneyTextMatches(
              serverRow, 'credit_limit_text', creditLimitM, currency) ||
          !_moneyTextMatches(
              serverRow, 'available_credit_text', availableCreditM, currency) ||
          serverRow['deleted_at'] != payload['deleted_at'];
      if (mismatch) {
        mismatched.add(localId);
        // Audit H-2: a detected mismatch must NEVER be stamped `synced`. The
        // remote row exists but disagrees with the local one, so local money is
        // NOT proven persisted. Marking it synced hid it from
        // hasUnsyncedLocalData() and from the pre-sign-out inventory, and let a
        // later pull replace local money with the remote value.
        //
        // `conflict` is the existing durable state: accounts have an
        // interactive conflict policy, accounts_pull_service refuses to
        // overwrite a conflict row, and the conflict picker offers
        // keep-mine/keep-theirs. server_id is still recorded (we know the
        // counterpart); synced_at is deliberately left unset.
        await _db.customStatement(
          '''
            UPDATE accounts
            SET server_id = ?, synced_at = NULL, sync_status = 'conflict'
            WHERE id = ?;
          ''',
          [serverRow['id'] as String, localId],
        );
      } else {
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

/// A reconciliation value is proven only when the requested `NUMERIC::text`
/// alias is present and parses exactly to the canonical local Money. Explicit
/// SQL NULL still matches nullable local money; a missing response key does not.
bool _moneyTextMatches(
  Map<String, dynamic> serverRow,
  String key,
  Money? local,
  String currency,
) {
  if (!serverRow.containsKey(key)) return false;
  try {
    return moneyFromPulledValue(serverRow[key], currency) == local;
  } catch (_) {
    return false;
  }
}

bool _requiredCurrencyMatches(Object? remote, String local) =>
    remote is String && remote.toUpperCase() == local.toUpperCase();
