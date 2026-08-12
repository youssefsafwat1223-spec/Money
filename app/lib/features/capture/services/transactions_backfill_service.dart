import 'package:drift/drift.dart' show Variable;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../core/session/app_session.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/money_codec.dart';
import '../../../data/db/planning_cutover.dart';
import '../../../data/db/sql_value_codec.dart';
import '../../../domain/finance/money.dart';
import '../../../data/sync/transaction_server_mappers.dart';
import '../../../domain/entities/transaction_entity.dart';
import '../../../domain/errors/repo_exceptions.dart';
import '../../../domain/finance/money_transport.dart';

const _transactionMoneySelect =
    '*, amount_text:amount::text, balance_after_text:balance_after::text, '
    'foreign_amount_text:foreign_amount::text';

class TransactionBackfillReport {
  const TransactionBackfillReport({
    required this.total,
    required this.created,
    required this.matched,
    required this.mismatchedLocalIds,
    required this.unresolvedAccountLocalIds,
  });

  final int total;
  final int created;
  final int matched;
  final List<String> mismatchedLocalIds;
  final List<String> unresolvedAccountLocalIds;

  bool get isClean =>
      mismatchedLocalIds.isEmpty && unresolvedAccountLocalIds.isEmpty;
}

/// يُرحِّل كل العمليات المحلية (Drift) إلى user_transactions — بلا ثقة
/// بعمود sync_status، ويشمل العمليات المحذوفة محليًا (status='ignored')
/// حتى لا تُعاد كعمليات نشطة لاحقًا. يجب ألا يبدأ قبل نجاح واكتمال
/// AccountsBackfillService والتحقق منه (كل حساب محلي غير محذوف له server_id).
class TransactionsBackfillService {
  TransactionsBackfillService({
    required AppDatabase db,
    SupabaseClient Function()? getClient,
    Future<String?> Function()? getAuthUserId,
    Future<String?> Function()? getLocalDataOwnerUid,
    // MALI-026 (B8-3 §12): defaults to schema-v29 legacy — the historical
    // backfill keeps the JSON-number wire shape until canonical, matching the
    // LedgerOutboxQueue. At canonical it serializes money as the EXACT decimal
    // STRING (never a JSON number for a canonical Money push).
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

  static Future<String?> _defaultGetAuthUserId() async {
    if (!SupabaseConfig.isConfigured) return null;
    try {
      return Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  /// يتحقق أن كل حساب محلي غير محذوف قد رُحِّل (له server_id) قبل السماح
  /// ببدء ترحيل العمليات — يرفض البدء بدل التخمين.
  Future<bool> accountsBackfillVerified() async {
    final unresolved = await _db
        .customSelect(
          "SELECT COUNT(*) AS n FROM accounts WHERE deleted_at IS NULL AND server_id IS NULL;",
        )
        .getSingle();
    return unresolved.read<int>('n') == 0;
  }

  /// دفاع في العمق: يرفض الترحيل إن كانت البيانات المحلية مسجَّلة كملك لهوية
  /// Supabase مختلفة عن الهوية الحالية — حماية إضافية إن فشل مسح تسجيل
  /// الخروج بصمت (انظر AppSession.signOut). `null` (لا تعارض معروف بعد) يُسمح
  /// به عمداً، وإلا لتعطّل أول ترحيل لمستخدم حالي قبل هذا التحديث.
  Future<void> _assertLocalDataOwnership(String uid) async {
    final ownerUid = await _getLocalDataOwnerUid();
    if (ownerUid != null && ownerUid != uid) {
      throw const ValidationRepoException(
        'Local transactions are recorded as owned by a different signed-in '
        'identity than the one currently authenticated — refusing to '
        'upload them to avoid cross-account data leakage.',
      );
    }
  }

  Future<TransactionBackfillReport> run() async {
    final uid = await _getAuthUserId();
    if (uid == null) throw const AuthRepoException();
    await _assertLocalDataOwnership(uid);
    if (!await accountsBackfillVerified()) {
      throw const ValidationRepoException(
        'Accounts backfill is not verified complete — refusing to start transactions backfill.',
      );
    }

    // Only rows that never reached the server (server_id IS NULL). A pulled/
    // pushed row already exists server-side; re-pushing it here would mint a
    // DUPLICATE, because pull-imports regenerate the local id on every
    // sign-in cycle so 'backfill_transaction_<localId>' never matches the
    // existing server row (observed in production: one extra server copy of
    // every transaction per reconcile run — 6 → 12 rows).
    // Rows already queued on the ledger outbox are likewise the outbox push's
    // responsibility — it keys server rows on client_request_id = local_id.
    final localRows = await _db
        .customSelect('SELECT * FROM transactions t '
            'WHERE t.server_id IS NULL '
            'AND t.id NOT IN (SELECT transaction_id FROM ledger_sync_outbox);')
        .get();

    var created = 0;
    var matched = 0;
    final mismatched = <String>[];
    final unresolvedAccounts = <String>[];

    for (final local in localRows) {
      final localId = local.read<String>('id');
      final localAccountId = local.readNullable<String>('account_id');

      String? serverAccountId;
      if (localAccountId != null) {
        final row = await _db.customSelect(
          'SELECT server_id FROM accounts WHERE id = ? LIMIT 1;',
          variables: [Variable.withString(localAccountId)],
        ).getSingleOrNull();
        serverAccountId = row?.readNullable<String>('server_id');
        if (serverAccountId == null) {
          // لا نخمّن العلاقة أبدًا — نتخطى هذا الصف ونبلّغ عنه.
          unresolvedAccounts.add(localId);
          continue;
        }
      }

      final categoryLocalId = local.readNullable<String>('category_id');
      final categoryKey = await _categoryKeyForLocalId(categoryLocalId);
      final direction =
          _directionFromSql(local.readNullable<String>('direction'));
      final type = TransactionTypeEntity.values.firstWhere(
          (t) => t.name == local.read<String>('type'),
          orElse: () => TransactionTypeEntity.unknown);
      final cardLast4 = local.readNullable<String>('card_last4');
      final isDeleted = local.read<String>('status') == 'ignored';
      final clientRequestId = 'backfill_transaction_$localId';
      final localCurrency = local.read<String>('currency');
      final localAmount =
          kMoneyCodec.readColumn(local, 'amount', localCurrency);
      final localBalance =
          kMoneyCodec.readColumnNullable(local, 'balance_after', localCurrency);
      final localForeignCurrency =
          local.readNullable<String>('foreign_currency');
      final localForeignAmount = localForeignCurrency == null
          ? null
          : kMoneyCodec.readColumnNullable(
              local,
              'foreign_amount',
              localForeignCurrency,
            );

      // §12: canonical mode serializes money as the EXACT decimal STRING
      // (Money -> moneyToNumericText -> NUMERIC); legacy keeps the JSON number.
      // Never a JSON-number for a canonical Money push; no Money.toDouble() runs
      // on the canonical path.
      final canonical = _coordinator.state() == PlanningCutoverState.canonical;
      Object amountWire(Money m) =>
          canonical ? moneyToNumericText(m) : moneyToLegacyJsonNumber(m);
      Object? amountWireOrNull(Money? m) => canonical
          ? moneyToNumericTextOrNull(m)
          : moneyToLegacyJsonNumberOrNull(m);
      final payload = <String, dynamic>{
        'user_id': uid,
        'client_request_id': clientRequestId,
        'amount': amountWire(localAmount),
        'currency': localCurrency,
        'merchant': local.readNullable<String>('raw_merchant'),
        'description': local.readNullable<String>('note'),
        'category_id': categoryKey,
        'occurred_at': dateTimeFromSql(local.read<String>('occurred_at'))
            .toIso8601String(),
        'source': transactionSourceToServer(
          TransactionSourceEntity.values.firstWhere(
            (s) => s.name == local.read<String>('source'),
            orElse: () => TransactionSourceEntity.unknown,
          ),
        ),
        'confidence': local.read<double>('parse_confidence'),
        'direction': transactionDirectionToServer(direction),
        'transaction_type': transactionTypeToServer(type, direction),
        'server_account_id': serverAccountId,
        'balance_after': amountWireOrNull(localBalance),
        'status': isDeleted ? 'ignored' : local.read<String>('status'),
        'foreign_amount': amountWireOrNull(localForeignAmount),
        'foreign_currency': localForeignCurrency,
        'comparison_timestamp':
            local.readNullable<String>('comparison_timestamp'),
        'comparison_timestamp_source':
            local.readNullable<String>('comparison_timestamp_source') ??
                'received_at',
        'deleted_at': isDeleted ? dateTimeToSql(DateTime.now().toUtc()) : null,
        'metadata': {
          'transaction_source': local.read<String>('source'),
          if (cardLast4 != null) 'last4': cardLast4,
          if (local.readNullable<String>('transaction_time_from_sms') != null)
            'transaction_time_from_sms':
                local.read<String>('transaction_time_from_sms'),
          if (local.readNullable<String>('sms_received_at') != null)
            'sms_received_at': local.read<String>('sms_received_at'),
          'duplicate_status':
              local.readNullable<String>('duplicate_status') ?? 'normal',
          if (local.readNullable<String>(
                  'possible_duplicate_of_transaction_id') !=
              null)
            'possible_duplicate_of_transaction_id':
                local.read<String>('possible_duplicate_of_transaction_id'),
          if (local.readNullable<String>('duplicate_reason') != null)
            'duplicate_reason': local.read<String>('duplicate_reason'),
        },
      };

      Map<String, dynamic> serverRow;
      try {
        final existing = await _getClient()
            .from('user_transactions')
            .select(_transactionMoneySelect)
            .eq('user_id', uid)
            .eq('client_request_id', clientRequestId)
            .maybeSingle();
        if (existing != null) {
          serverRow = existing;
          matched++;
        } else {
          serverRow = await _getClient()
              .from('user_transactions')
              .insert(payload)
              .select(_transactionMoneySelect)
              .single();
          created++;
        }
      } catch (e) {
        throw mapSupabaseError(e);
      }

      final serverAmount = moneyFromPulledValueRequired(
          serverRow['amount_text'], localCurrency);
      final mismatch =
          serverAmount != localAmount ||
              serverRow['currency'] != payload['currency'] ||
              serverRow['direction'] != payload['direction'] ||
              serverRow['transaction_type'] != payload['transaction_type'];
      if (mismatch) mismatched.add(localId);

      await _db.customStatement(
        '''
          UPDATE transactions
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

    return TransactionBackfillReport(
      total: localRows.length,
      created: created,
      matched: matched,
      mismatchedLocalIds: mismatched,
      unresolvedAccountLocalIds: unresolvedAccounts,
    );
  }

  Future<String?> _categoryKeyForLocalId(String? categoryId) async {
    if (categoryId == null) return null;
    final row = await _db.customSelect(
      'SELECT key FROM categories WHERE id = ? LIMIT 1;',
      variables: [Variable.withString(categoryId)],
    ).getSingleOrNull();
    return row?.readNullable<String>('key');
  }

  static TransactionDirectionEntity _directionFromSql(String? value) {
    switch (value) {
      case 'credit':
        return TransactionDirectionEntity.credit;
      case 'debit':
        return TransactionDirectionEntity.debit;
      default:
        return TransactionDirectionEntity.unknown;
    }
  }
}
