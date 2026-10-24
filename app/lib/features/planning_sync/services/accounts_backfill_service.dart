import 'package:drift/drift.dart' show Variable;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../core/privacy/consent_authority.dart';
import '../../../core/session/account_fence_authority.dart';
import '../../../core/session/admission_authority.dart';
import '../../../core/session/app_session.dart';
import '../../../core/sync/account_fence_retry.dart';
import '../../../core/sync/outbox_failure.dart';
import '../../../core/sync/sync_health.dart';
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
    this.failedLocalIds = const [],
  });

  final int total;
  final int created;
  final int matched;
  final List<String> mismatchedLocalIds;
  final bool defaultResolved;
  final String? defaultWarning;

  /// Accounts the server rejected permanently; recorded here and skipped so one
  /// bad row does not stop the others. Counted as unresolved by the reconcile.
  final List<String> failedLocalIds;

  bool get isClean =>
      mismatchedLocalIds.isEmpty &&
      failedLocalIds.isEmpty &&
      defaultWarning == null;
}

/// The ORIGINAL account lifetime a default-account backfill runs under, captured
/// once before any other wait and passed down as one opaque object. A null
/// [handle] is a permanently unbound marker: it is never recaptured and never
/// becomes authority later. A supplied [callerPhase] must already be bound,
/// current and on the same database; otherwise the marker is unbound and
/// [validCallerAtEntry] is false.
class DefaultAccountBackfillScope {
  DefaultAccountBackfillScope._(this.authority, this.database, this.handle,
      this.callerPhase, this.validCallerAtEntry);
  final AccountFenceAuthority authority;
  final AppDatabase database;
  final AccountFenceHandle? handle;
  final SyncPhaseBinding? callerPhase;
  final bool validCallerAtEntry;

  static bool _phaseHolds(SyncPhaseBinding? phase, AppDatabase db) =>
      phase == null ||
      (phase.isBound && phase.isCurrent && identical(phase.database, db));

  static Future<DefaultAccountBackfillScope> capture(AppDatabase db,
      {SyncPhaseBinding? callerPhase}) async {
    final authority = AccountFenceAuthority.shared;
    if (!_phaseHolds(callerPhase, db)) {
      return DefaultAccountBackfillScope._(authority, db, null, null, false);
    }
    // The real capture starts synchronously here, before any other wait.
    final handle = await authority.captureForDatabase(AppSession.instance, db);
    if (!_phaseHolds(callerPhase, db)) {
      return DefaultAccountBackfillScope._(authority, db, null, null, false);
    }
    return DefaultAccountBackfillScope._(authority, db, handle, callerPhase, true);
  }

  /// True once a lifetime that was valid at entry (caller phase and/or the real
  /// original handle) no longer is. An unbound marker with a valid caller is not
  /// "lost": ordinary non-default account paths keep their old contract.
  bool get lost =>
      !validCallerAtEntry ||
      (callerPhase != null && !_phaseHolds(callerPhase, database)) ||
      (handle != null && !authority.isCurrentForDatabase(handle!, database));

  bool get isCurrent => handle != null && !lost;
  String? get uid => handle == null ? null : authority.ownerUid(handle!);

  void requireNotLost() {
    if (lost) throw const AccountsDeliveryStopped(AccountsDeliveryStopReason.stale);
  }

  void requireCurrent() {
    if (handle == null) {
      throw const AccountsDeliveryStopped(AccountsDeliveryStopReason.unbound);
    }
    requireNotLost();
  }

  Future<T> runLocal<T>(Future<T> Function() action) {
    requireCurrent();
    return authority.runCurrentLocal(handle!, database, () {
      requireCurrent();
      return action();
    });
  }
}

/// Proven contention on the immutable default RPC outlasted its bounded budget.
/// Not a durable account denial, queued parking, provenance failure or success.
class DefaultAccountBackfillContentionExhausted
    implements AccountFenceDeliveryCancellation {
  const DefaultAccountBackfillContentionExhausted();
  @override
  String toString() => 'DefaultAccountBackfillContentionExhausted';
}

/// Synchronous builder/preflight/local failure: never proof of a remote request.
class _DefaultUnprovenFailure implements Exception {
  const _DefaultUnprovenFailure(this.error, this.stack);
  final Object error;
  final StackTrace stack;
}

class _DefaultRemoteFailure implements Exception {
  const _DefaultRemoteFailure(this.error);
  final Object error;
}

/// Built ONLY around the awaited actual SDK RPC future.
class _DefaultMutationRefusal implements Exception {
  const _DefaultMutationRefusal(this.scope, this.intent, this.target, this.raw);
  final DefaultAccountBackfillScope scope;
  final AccountFenceDefaultAccountIntent intent;
  final String target;
  final PostgrestException raw;
}

/// Built ONLY around the awaited actual SDK RPC future; the shared retry helper
/// sees a 55P03 code on nothing else.
class _DefaultMutationContention extends PostgrestException {
  _DefaultMutationContention(this.scope, this.intent, this.target, PostgrestException raw)
      : super(message: raw.message, code: raw.code, details: raw.details, hint: raw.hint);
  final DefaultAccountBackfillScope scope;
  final AccountFenceDefaultAccountIntent intent;
  final String target;
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
    // Consulted before every default-account RPC attempt only. Defaults to DENY
    // so a caller that forgets it sends no default-account mutation.
    Future<bool> Function()? mayEgress,
  })  : _db = db,
        _getClient = getClient ?? (() => Supabase.instance.client),
        _getAuthUserId = getAuthUserId ?? _defaultGetAuthUserId,
        _getLocalDataOwnerUid =
            getLocalDataOwnerUid ?? AppSession.instance.readLocalDataOwnerUid,
        _coordinator = coordinator,
        _mayEgress = mayEgress ?? _denyEgressByDefault;

  final AppDatabase _db;
  final SupabaseClient Function() _getClient;
  final Future<String?> Function() _getAuthUserId;
  final Future<String?> Function() _getLocalDataOwnerUid;
  final PlanningCutoverCoordinator _coordinator;
  final Future<bool> Function() _mayEgress;
  final AccountFenceRetry _retry = AccountFenceRetry();

  static Future<bool> _denyEgressByDefault() async => false;

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

  /// [scope] is the ORIGINAL lifetime captured by the caller before its own
  /// waits; only when it is absent is it captured here, at this first entry.
  /// A supplied scope whose handle is null is never recaptured.
  Future<AccountBackfillReport> run({DefaultAccountBackfillScope? scope}) async {
    final original = scope ?? await DefaultAccountBackfillScope.capture(_db);
    final uid = await _getAuthUserId();
    if (uid == null) throw const AuthRepoException();
    await _assertLocalDataOwnership(uid);

    // كل الحسابات المحلية — بلا فلترة على sync_status أو deleted_at.
    final localRows = await _db.customSelect('SELECT * FROM accounts;').get();

    var created = 0;
    var matched = 0;
    final mismatched = <String>[];
    final failed = <String>[];

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
        // Per-row isolation: a permanent server rejection of this account is
        // recorded and skipped; transient / auth / network errors still stop
        // the run (retried later).
        if (e is PostgrestException && classifyOutboxError(e).isPermanent) {
          failed.add(localId);
          continue;
        }
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

    final resolution = await _resolveDefault(uid, original);

    return AccountBackfillReport(
      total: localRows.length,
      created: created,
      matched: matched,
      mismatchedLocalIds: mismatched,
      defaultResolved: resolution == null,
      defaultWarning: resolution,
      failedLocalIds: failed,
    );
  }

  /// يحسم الحساب الافتراضي بعد الترحيل عبر set_default_account (RPC ذرّي)
  /// — لا نرحّل is_default=true مباشرة لتفادي انتهاك الفهرس الجزئي
  /// (حساب افتراضي نشط واحد لكل مستخدم) إن كانت البيانات المحلية غير متسقة.
  /// يعيد رسالة تحذير نصية إن لم يوجد حساب افتراضي محلي واحد بوضوح، ولا
  /// يخمّن أيًا كان.
  Future<String?> _resolveDefault(
      String uid, DefaultAccountBackfillScope scope) async {
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
    // A real default command from here on: it runs only under the ORIGINAL
    // bound lifetime. An unbound marker typed-stops with no RPC.
    final handle = scope.handle;
    if (handle == null || !identical(scope.database, _db)) {
      throw const AccountsDeliveryStopped(AccountsDeliveryStopReason.unbound);
    }
    try {
      scope.requireCurrent();
      if (scope.uid != uid) {
        throw const AccountsDeliveryStopped(AccountsDeliveryStopReason.provenance);
      }
      final intent = await scope.authority.captureDefaultAccountIntent(
          handle, _db, localId: localId, serverId: serverId);
      scope.requireCurrent();
      // The selection moved between the plain read above and the tracked
      // capture: the command is gone, never refreshed or retargeted.
      if (intent == null) {
        throw const AccountsDeliveryStopped(AccountsDeliveryStopReason.stale);
      }
      final response = await _dispatchDefault(scope, handle, intent, uid);
      return await _finalizeDefault(scope, handle, intent, uid, response);
    } on AccountFenceDeliveryCancellation {
      rethrow;
    } on StaleAdmissionException {
      throw const AccountsDeliveryStopped(AccountsDeliveryStopReason.stale);
    } catch (e) {
      // A raw QD from a preflight/local path is not mutation proof.
      if (decodeAccountsAccountDenial(e) != null) {
        throw const AccountsDeliveryStopped(AccountsDeliveryStopReason.provenance);
      }
      return 'set_default_account failed during backfill: $e';
    }
  }

  bool _identityHolds(DefaultAccountBackfillScope scope, String uid,
      {SupabaseClient? client}) {
    if (!scope.isCurrent || scope.uid != uid) return false;
    try {
      return (client ?? _getClient()).auth.currentUser?.id == uid;
    } catch (_) {
      return false;
    }
  }

  /// One bounded retry budget wraps ONLY the immutable default RPC (never the
  /// earlier matching/stamping or reads). Returns the positive response.
  Future<Object?> _dispatchDefault(
    DefaultAccountBackfillScope scope,
    AccountFenceHandle handle,
    AccountFenceDefaultAccountIntent intent,
    String uid,
  ) async {
    Future<bool> isCurrent() async {
      if (!_identityHolds(scope, uid)) return false;
      if (!await _mayEgress()) return false;
      if (!_identityHolds(scope, uid) || ConsentAuthority.egressFrozen) {
        return false;
      }
      final same = await scope.runLocal(() => _db.transaction(
          () => scope.authority.defaultAccountIntentMatches(handle, _db, intent)));
      return same && _identityHolds(scope, uid);
    }

    try {
      return await _retry.runItem<Object?>(
        isCurrent: isCurrent,
        body: () => retryAccountFenceMutation(
            () => _sendDefault(scope, intent, uid)),
      );
    } on _DefaultMutationRefusal catch (refusal) {
      if (!identical(refusal.scope, scope) ||
          !identical(refusal.intent, intent) ||
          refusal.target != intent.serverId) {
        throw const AccountsDeliveryStopped(AccountsDeliveryStopReason.provenance);
      }
      // Negative lifetime is independent of any temporary positive readiness;
      // no local reservation is held here and cleanup is awaited by the authority.
      final result = await scope.authority.acceptDefaultAccountDenial(
          handle, _db, intent, decodeAccountsAccountDenial(refusal.raw)!);
      throw AccountsDeliveryStopped(AccountsDeliveryStopReason.denial,
          accepted: result.accepted, complete: result.complete);
    } on _DefaultMutationContention catch (contention) {
      if (!identical(contention.scope, scope) ||
          !identical(contention.intent, intent) ||
          contention.target != intent.serverId) {
        throw const AccountsDeliveryStopped(AccountsDeliveryStopReason.provenance);
      }
      throw const DefaultAccountBackfillContentionExhausted();
    } on AccountFenceRetryStopped {
      throw const AccountsDeliveryStopped(AccountsDeliveryStopReason.stale);
    } on _DefaultUnprovenFailure catch (failure) {
      // A raw QD from a factory/preflight/local path is not mutation proof.
      if (decodeAccountsAccountDenial(failure.error) != null) {
        throw const AccountsDeliveryStopped(AccountsDeliveryStopReason.provenance);
      }
      Error.throwWithStackTrace(failure.error, failure.stack);
    } on _DefaultRemoteFailure catch (failure) {
      throw failure.error;
    }
  }

  Future<Object?> _sendDefault(
    DefaultAccountBackfillScope scope,
    AccountFenceDefaultAccountIntent intent,
    String uid,
  ) async {
    final PostgrestFilterBuilder<dynamic> call;
    try {
      // ONE client for this attempt: the instance whose user is validated is the
      // instance that builds the RPC.
      final client = _getClient();
      if (!_identityHolds(scope, uid, client: client) ||
          ConsentAuthority.egressFrozen) {
        throw const AccountsDeliveryStopped(AccountsDeliveryStopReason.stale);
      }
      // Only awaiting the actual SDK future below establishes remote origin.
      call = client
          .rpc('set_default_account', params: {'p_account_id': intent.serverId});
    } on AccountFenceDeliveryCancellation {
      rethrow;
    } catch (error, stack) {
      throw _DefaultUnprovenFailure(error, stack);
    }
    try {
      return await call;
    } on PostgrestException catch (error) {
      if (decodeAccountsAccountDenial(error) != null) {
        throw _DefaultMutationRefusal(scope, intent, intent.serverId, error);
      }
      if (error.code == '55P03') {
        throw _DefaultMutationContention(scope, intent, intent.serverId, error);
      }
      throw _DefaultRemoteFailure(error);
    } on AccountFenceDeliveryCancellation {
      rethrow;
    } catch (error) {
      throw _DefaultRemoteFailure(error);
    }
  }

  /// A positive response must name the captured target BEFORE any local write.
  /// Both local default updates share ONE tracked transaction on the original
  /// database; the exact command and lifetime are rechecked across every
  /// awaited SQL boundary, and a failed recheck rolls the transaction back.
  Future<String?> _finalizeDefault(
    DefaultAccountBackfillScope scope,
    AccountFenceHandle handle,
    AccountFenceDefaultAccountIntent intent,
    String uid,
    Object? response,
  ) async {
    if (response is! Map || response['id'] != intent.serverId) {
      return 'set_default_account returned an unexpected row.';
    }
    // Consent is rechecked AFTER the matching positive response and OUTSIDE any
    // local reservation; a genuine negative was already accepted before this.
    if (!_identityHolds(scope, uid) ||
        ConsentAuthority.egressFrozen ||
        !await _mayEgress() ||
        !_identityHolds(scope, uid) ||
        ConsentAuthority.egressFrozen) {
      throw const AccountsDeliveryStopped(AccountsDeliveryStopReason.stale);
    }
    Future<void> exact() async {
      if (!_identityHolds(scope, uid) ||
          ConsentAuthority.egressFrozen ||
          !await scope.authority.defaultAccountIntentMatches(handle, _db, intent) ||
          !_identityHolds(scope, uid) ||
          ConsentAuthority.egressFrozen) {
        throw const AccountsDeliveryStopped(AccountsDeliveryStopReason.stale);
      }
    }

    await scope.runLocal(() => _db.transaction(() async {
          await exact();
          await _db.customStatement(
            "UPDATE accounts SET is_default = 1 WHERE id = ?;",
            [intent.localId],
          );
          await exact();
          await _db.customStatement(
            "UPDATE accounts SET is_default = 0 WHERE id != ? AND deleted_at IS NULL;",
            [intent.localId],
          );
          await exact();
        }));
    if (!_identityHolds(scope, uid)) {
      throw const AccountsDeliveryStopped(AccountsDeliveryStopReason.stale);
    }
    return null;
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
