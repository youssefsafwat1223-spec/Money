import 'dart:async';

import '../../../core/session/account_fence_authority.dart';
import '../../../core/session/admission_authority.dart';
import '../../../core/session/app_session.dart';
import '../../../core/sync/account_fence_retry.dart';
import '../../../core/sync/sync_health.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../core/sync/guarded_mutation.dart';
import '../../../core/sync/outbox_failure.dart';
import '../../../core/sync/conflict_policy.dart';
import '../../../core/sync/sync_conflict_store.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/planning_cutover.dart';
import '../../../data/db/sql_value_codec.dart';
import '../../../data/sync/exact_transport_capability.dart';
import '../../../data/sync/revision_cas.dart';
import 'planning_outbox_queue.dart';

/// Acknowledgement columns a legacy (non-CAS) account write reads back.
const String _ackCols = 'id, updated_at';

class AccountsPushResult {
  const AccountsPushResult({
    this.pushed = 0,
    this.conflicts = 0,
    this.failed = 0,
    this.abandoned = 0,
    this.parked = 0,
  });

  final int pushed;
  final int conflicts;
  final int failed;
  final int abandoned;
  final int parked;
}

abstract class AccountsRemoteSink {
  Future<Map<String, dynamic>> upsertAccount(Map<String, dynamic> row);
  Future<Map<String, dynamic>?> findAccountByLocalId(String userId, String id);

  /// MALI-022 (Phase-9K) — guarded tombstone without a revision base: sets
  /// `deleted_at` only if the account still matches [expectedUpdatedAt] (or, when
  /// null, only if not already tombstoned). Null when no row matched. Never blind.
  Future<Map<String, dynamic>?> guardedTombstoneAccount(
    String serverId,
    String? expectedUpdatedAt,
  );

  /// MALI-022 (Phase-9K) — the account's current `{deleted_at}` (null if gone),
  /// used to classify a zero-row guarded tombstone.
  Future<Map<String, dynamic>?> fetchAccountState(String serverId);

  /// MALI-022 — the current server `updated_at` for a known account, used as the
  /// optimistic-concurrency compare on a guarded update. Null if the row is gone.
  Future<String?> fetchAccountUpdatedAt(String serverId);

  /// C-6 — ATOMIC guarded update: writes only if the server row still matches
  /// [expectedUpdatedAt], by binding that predicate into the statement itself.
  ///
  /// Replaces fetch-then-blind-update, where the base was read in one round-trip
  /// and the write issued in another: a remote write landing between them was
  /// silently clobbered, because the guard had passed against a value that was
  /// no longer true. Returns null when 0 rows matched — someone else won the
  /// race, which is a conflict to resolve, not an error to swallow.
  ///
  /// Same shape as [guardedTombstoneAccount], which has been atomic all along.
  Future<Map<String, dynamic>?> guardedUpdateAccount(
    String serverId,
    String expectedUpdatedAt,
    Map<String, dynamic> row,
  );

  /// Atomically makes [serverAccountId] the user's only default via the
  /// `set_default_account` RPC (MALI-015) — the server demotes the previous
  /// default in the same transaction, so outbox ordering can never trip the
  /// one-active-default unique index.
  Future<void> setDefaultAccount(String serverAccountId);
}

class SupabaseAccountsRemoteSink implements AccountsRemoteSink {
  const SupabaseAccountsRemoteSink();

  SupabaseClient get _client {
    final invocation = Zone.current[_accountsInvocationKey] as _AccountsInvocation?;
    invocation?.requireCurrent();
    return Supabase.instance.client;
  }

  @override
  Future<Map<String, dynamic>?> findAccountByLocalId(
    String userId,
    String id,
  ) async {
    return await _client
        .from('user_accounts')
        .select('id, updated_at')
        .eq('user_id', userId)
        .eq('local_id', id)
        .maybeSingle();
  }

  @override
  Future<Map<String, dynamic>?> guardedTombstoneAccount(
    String serverId,
    String? expectedUpdatedAt,
  ) async {
    // Never id-only: guard on the last-known updated_at, or (when unknown) on
    // the row not already being tombstoned. Each branch is a single chained
    // statement so the guard predicate always travels with the deleted_at write.
    final deletedAt = DateTime.now().toUtc().toIso8601String();
    final rows = expectedUpdatedAt != null
        ? await retryAccountFenceMutation(() => _client
            .from('user_accounts')
            .update({'deleted_at': deletedAt})
            .eq('id', serverId)
            .eq('updated_at', expectedUpdatedAt)
            .select('id, updated_at'))
        : await retryAccountFenceMutation(() => _client
            .from('user_accounts')
            .update({'deleted_at': deletedAt})
            .eq('id', serverId)
            .isFilter('deleted_at', null)
            .select('id, updated_at'));
    return guardedAck(rows, 'accounts.guardedTombstone');
  }

  @override
  Future<Map<String, dynamic>?> fetchAccountState(String serverId) async {
    return await _client
        .from('user_accounts')
        .select('deleted_at')
        .eq('id', serverId)
        .maybeSingle();
  }

  @override
  Future<Map<String, dynamic>> upsertAccount(Map<String, dynamic> row) async {
    return await _client
        .from('user_accounts')
        .upsert(row, onConflict: 'user_id,local_id')
        .select(_ackCols)
        .single();
  }

  @override
  Future<String?> fetchAccountUpdatedAt(String serverId) async {
    final row = await _client
        .from('user_accounts')
        .select('updated_at')
        .eq('id', serverId)
        .maybeSingle();
    return row?['updated_at'] as String?;
  }

  @override
  Future<Map<String, dynamic>?> guardedUpdateAccount(
    String serverId,
    String expectedUpdatedAt,
    Map<String, dynamic> row,
  ) async {
    // C-6: the predicate travels WITH the write, so the database enforces it.
    final rows = await retryAccountFenceMutation(() => _client
        .from('user_accounts')
        .update(row)
        .eq('id', serverId)
        .eq('updated_at', expectedUpdatedAt)
        .select(_ackCols));
    return guardedAck(rows, 'accounts.atomicGuardedUpdate');
  }

  @override
  Future<void> setDefaultAccount(String serverAccountId) async {
    await _client.rpc<void>(
      'set_default_account',
      params: {'p_account_id': serverAccountId},
    );
  }
}

class AccountsPushService {
  AccountsPushService({
    required AppDatabase db,
    required PlanningOutboxQueue queue,
    required bool Function() isEnabled,
    Future<String?> Function()? getAuthUserId,
    AccountsRemoteSink? remoteSink,
    // WP-5: null (or a legacy plan) keeps the legacy guarded push unchanged.
    RevisionCasGate? casGate,
    CasRemote? casRemote,
    PlanningCutoverCoordinator coordinator =
        const SchemaV29PlanningCutoverCoordinator(),
    ExactTransportCapability Function() pushCapability = _defaultPushCapability,
    /// C-3 — consulted at the moment of egress. Defaults to DENY so a caller
    /// that forgets it gets no network.
    Future<bool> Function()? mayEgress,
    SyncHealth? health,
    AccountFenceRetry? fenceRetry,
  })  : _db = db,
        _fenceRetry = fenceRetry ?? AccountFenceRetry(),
        _health = health,
        _mayEgress = mayEgress ?? _denyEgressByDefault,
        _queue = queue,
        _isEnabled = isEnabled,
        _getAuthUserId = getAuthUserId ?? _defaultGetAuthUserId,
        _remoteSink = remoteSink ?? const SupabaseAccountsRemoteSink(),
        _casGate = casGate,
        _casRemote = casRemote ?? const SupabaseCasRemote(),
        _conflicts = SyncConflictStore(db),
        _coordinator = coordinator,
        _pushCapability = pushCapability;

  static ExactTransportCapability _defaultPushCapability() =>
      ExactTransportCapability.unknown;

  final AppDatabase _db;
  final PlanningOutboxQueue _queue;
  final Future<bool> Function() _mayEgress;
  final SyncHealth? _health;
  final AccountFenceRetry _fenceRetry;
  final bool Function() _isEnabled;
  final Future<String?> Function() _getAuthUserId;
  final AccountsRemoteSink _remoteSink;

  final RevisionCasGate? _casGate;
  final CasRemote _casRemote;
  RevisionCasEngine get _cas => RevisionCasEngine(
      _AccountsCasRemote(_casRemote, _invocation!));
  final SyncConflictStore _conflicts;
  CasPlan _plan = const CasPlan(CasMode.legacy);

  final PlanningCutoverCoordinator _coordinator;
  final ExactTransportCapability Function() _pushCapability;

  static Future<String?> _defaultGetAuthUserId() async {
    if (!SupabaseConfig.isConfigured) return null;
    try {
      return Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  static Future<bool> _denyEgressByDefault() async => false;

  bool _busy = false;
  _AccountsInvocation? _invocation;
  static final _operationId = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

  Future<AccountsPushResult> push() => pushWithPhase(SyncPhaseBinding());

  Future<AccountsPushResult> pushWithPhase(SyncPhaseBinding phase) async {
    if (_busy) throw const AccountsDeliveryStopped(AccountsDeliveryStopReason.overlap);
    _busy = true;
    try {
      final authority = AccountFenceAuthority.shared;
      final handle = await authority.captureForDatabase(AppSession.instance, _db);
      if (handle == null) {
        throw const AccountsDeliveryStopped(AccountsDeliveryStopReason.unbound);
      }
      final invocation = _AccountsInvocation(authority, handle, _db, phase);
      _invocation = invocation;
      phase.bind(invocation);
      final result = await _pushBound();
      _requireCurrent();
      return result;
    } on StaleAdmissionException {
      throw const AccountsDeliveryStopped(AccountsDeliveryStopReason.stale);
    } finally {
      _invocation = null;
      _busy = false;
    }
  }

  void _requireCurrent() => _invocation!.requireCurrent();

  Future<T> _local<T>(Future<T> Function() action) async {
    _requireCurrent();
    try {
      return await _invocation!.runLocal(action);
    } on StaleAdmissionException {
      throw const AccountsDeliveryStopped(AccountsDeliveryStopReason.stale);
    }
  }

  Future<void> _itemLocal(PlanningOutboxItem item,
      Future<void> Function() action) => _local(() => _db.transaction(() async {
    if (!await _queue.accountsHolderCurrent(item)) return;
    await action();
  }));

  Future<T> _remote<T>(Future<T> Function() action) async {
    _requireCurrent();
    try {
      final result = await runZoned(action,
          zoneValues: {_accountsInvocationKey: _invocation!});
      _requireCurrent();
      return result;
    } catch (error) {
      if (decodeAccountsAccountDenial(error) != null) rethrow;
      if (error is AccountFenceDeliveryCancellation) rethrow;
      _requireCurrent();
      rethrow;
    }
  }

  Future<Never> _deny(PlanningOutboxItem item, Object error) async {
    final state = decodeAccountsAccountDenial(error)!;
    final current = _invocation!;
    final result = await current.authority.acceptAccountsDenial(current.handle,
        _db, state, rowId: item.id, entityType: item.entityType,
        entityId: item.entityId, ownerUid: item.ownerUid, opSeq: item.opSeq,
        operationId: item.operationId!,
        park: (ticket) => _queue.parkAccountDenial(item, state, ticket));
    throw AccountsDeliveryStopped(AccountsDeliveryStopReason.denial,
        accepted: result.accepted, parked: result.parked, complete: result.complete);
  }

  void _validateItem(PlanningOutboxItem item) {
    if (item.ownerUid != _invocation!.ownerUid || item.operationId == null ||
        !_operationId.hasMatch(item.operationId!)) {
      throw const AccountsDeliveryStopped(AccountsDeliveryStopReason.provenance);
    }
  }

  Future<AccountsPushResult> _pushBound() async {
    // C-3 — money must not leave the device without cloud consent. This is the
    // headline of F-025: the privacy screen promises the switch disables
    // synchronisation, and it did not.
    if (!await _mayEgress()) {
      _invocation!.phase.noteConsentBlocked(_health);
      return const AccountsPushResult();
    }
    _requireCurrent();
    if (!_isEnabled()) return const AccountsPushResult();
    final userId = await _getAuthUserId();
    _requireCurrent();
    if (userId == null) return const AccountsPushResult();

    if (userId != _invocation!.ownerUid) {
      throw const AccountsDeliveryStopped(AccountsDeliveryStopReason.stale);
    }
    // WP-5: legacy push or revision CAS; unprovable capability = nothing sent.
    _plan = _casGate == null ? const CasPlan(CasMode.legacy) : await _casGate.planForAccounts(userId, authority: _invocation!.authority,
        handle: _invocation!.handle, database: _db);
    _requireCurrent();
    if (_plan.mode == CasMode.stopped) return const AccountsPushResult();

    // D-7: the AuthSessionValid broadcast has no replay, so a cold start can miss
    // it. A valid authenticated session at the start of a cycle re-arms rows
    // parked `auth_required` (cheap UPDATE; no attempt was ever consumed).
    if (outboxHasValidSession()) {
      await _local(() => _queue.reArmAuthParked(entityTypes: const [
        PlanningOutboxQueue.accountsEntityType,
        PlanningOutboxQueue.accountDefaultCommandType,
      ]));
    }

    if (_pushCapability() == ExactTransportCapability.verifiedExact) {
      await _local(() => _queue.reArmParked());
    }
    // A-2 (G18): only rows recorded for THIS identity may be sent.
    final verified = await _queue.ownershipVerified(userId);
    _requireCurrent();
    await _local(() => _queue.reconcileVerifiedOwnership(userId, verified));

    int pushed = 0;
    int conflicts = 0;
    int failed = 0;
    int abandoned = 0;
    int parked = 0;
    var fenceStopped = false;

    // Field syncs FIRST, so a default command can resolve its target's server id
    // (a freshly-created default account is established before the command runs).
    final items = await _local(() => _queue.pendingItems(
      entityType: PlanningOutboxQueue.accountsEntityType,
    ));
    for (final item in items) {
      _validateItem(item);
      try {
        final outcome = await _fenceRetry.runItem(
            isCurrent: () async {
              _requireCurrent();
              if (!_isEnabled()) return false;
              final uid = await _getAuthUserId();
              _requireCurrent();
              if (uid != userId) return false;
              final consent = await _mayEgress();
              _requireCurrent();
              if (!consent) return false;
              final current = await _local(() => _queue.accountFenceCurrent(item));
              _requireCurrent();
              return current;
            },
            body: () => _processItem(item, userId));
        switch (outcome) {
          case _AccountsPushOutcome.pushed:
            pushed++;
          case _AccountsPushOutcome.conflict:
            conflicts++;
          case _AccountsPushOutcome.abandoned:
            abandoned++;
          case _AccountsPushOutcome.deferred:
            break; // edited while examined: stays pending for the next cycle
          case _AccountsPushOutcome.parked:
            parked++;
            _invocation!.phase.noteCapabilityParked(_health);
        }
      } on CasEpochMismatch {
        // Stale epoch: nothing was written; stop the cycle (WP-7 rebootstraps).
        await _itemLocal(item, () => _queue.releaseInFlight(item.id));
        break;
      } on AccountFenceRetryStopped {
        fenceStopped = true;
        break;
      } on AccountFenceDeliveryCancellation {
        rethrow;
      } catch (e) {
        if (decodeAccountsAccountDenial(e) != null) await _deny(item, e);
        _requireCurrent();
        final fence = classifyOutboxError(e);
        if (fence == OutboxFailureClass.accountFenceContention ||
            fence == OutboxFailureClass.accountDeletionPending) {
          final held = await _local(() => _queue.recordAccountFenceFailure(item, fence,
              _fenceRetry.clock().add(_fenceRetry.cooldown)));
          _invocation!.phase.noteFailure(_health, e);
          if (fence == OutboxFailureClass.accountDeletionPending) {
            if (held) parked++; fenceStopped = true; break;
          }
          continue;
        }
        failed++;
        _invocation!.phase.noteFailure(_health, e);
        await _itemLocal(item, () => _queue.markFailed(item.id, e.toString(), classifyOutboxError(e)));
        if (kDebugMode) debugPrint('[AccountsPush] item error: $e');
      }
    }

    // MALI-055n — dedicated default-account commands. Each resolves to the atomic
    // set_default_account RPC; it rewrites no account fields. Idempotent on
    // retry. A target not yet synced defers (missingDependency) for a later pass.
    final commands = fenceStopped ? <PlanningOutboxItem>[] : await _local(() => _queue.pendingItems(
      entityType: PlanningOutboxQueue.accountDefaultCommandType,
    ));
    for (final item in commands) {
      _validateItem(item);
      try {
        final targetLocalId = item.payloadJson['target_local_id'] as String?;
        final serverId = targetLocalId == null
            ? null
            : await _serverIdForLocalAccount(targetLocalId);
        if (serverId == null) {
          await _itemLocal(item, () => _queue.markFailed(item.id, 'default target not yet synced',
              OutboxFailureClass.missingDependency));
          failed++;
          continue;
        }
        await _fenceRetry.runItem(
            isCurrent: () async {
              _requireCurrent();
              if (!_isEnabled()) return false;
              final uid = await _getAuthUserId();
              _requireCurrent();
              if (uid != userId) return false;
              final consent = await _mayEgress();
              _requireCurrent();
              if (!consent) return false;
              final current = await _local(() => _queue.accountFenceCurrent(item));
              _requireCurrent();
              return current;
            },
            body: () => retryAccountFenceMutation(() => _remote(() => _remoteSink.setDefaultAccount(serverId))));
        await _itemLocal(item, () => _queue.markSuccess(item));
        pushed++;
      } on AccountFenceRetryStopped {
        break;
      } on AccountFenceDeliveryCancellation {
        rethrow;
      } catch (e) {
        if (decodeAccountsAccountDenial(e) != null) await _deny(item, e);
        _requireCurrent();
        final fence = classifyOutboxError(e);
        if (fence == OutboxFailureClass.accountFenceContention ||
            fence == OutboxFailureClass.accountDeletionPending) {
          final held = await _local(() => _queue.recordAccountFenceFailure(item, fence,
              _fenceRetry.clock().add(_fenceRetry.cooldown)));
          _invocation!.phase.noteFailure(_health, e);
          if (fence == OutboxFailureClass.accountDeletionPending) { if (held) parked++; break; }
          continue;
        }
        failed++;
        _invocation!.phase.noteFailure(_health, e);
        await _itemLocal(item, () => _queue.markFailed(item.id, e.toString(), classifyOutboxError(e)));
        if (kDebugMode) debugPrint('[AccountsPush] default command error: $e');
      }
    }

    if (kDebugMode) {
      debugPrint(
        '[AccountsPush] done: pushed=$pushed conflicts=$conflicts '
        'failed=$failed abandoned=$abandoned',
      );
    }
    return AccountsPushResult(
      pushed: pushed,
      conflicts: conflicts,
      failed: failed,
      abandoned: abandoned,
      parked: parked,
    );
  }

  Future<_AccountsPushOutcome> _processItem(
    PlanningOutboxItem item,
    String userId,
  ) async {
    if (item.operation != PlanningSyncOperation.delete &&
        shouldParkExactMoneyWrite(
          cutoverState: _coordinator.state(),
          pushCapability: _pushCapability(),
        )) {
      final parkedNow = await _local(() => _queue.park(
          item.id, exactMoneyTransportUnverifiedReason,
          ifOpSeq: item.opSeq));
      return parkedNow
          ? _AccountsPushOutcome.parked
          : _AccountsPushOutcome.deferred;
    }

    switch (item.operation) {
      case PlanningSyncOperation.create:
      case PlanningSyncOperation.update:
        return _plan.isCas ? _casUpsert(item, userId) : _pushUpsert(item, userId);
      case PlanningSyncOperation.delete:
        return _plan.isCas ? _casDelete(item, userId) : _pushDelete(item, userId);
    }
  }

  Future<_AccountsPushOutcome> _pushUpsert(
    PlanningOutboxItem item,
    String userId,
  ) async {
    try {
      final row = _toServerRow(item.payloadJson, userId);
      final existingServerId = await _serverIdForLocalAccount(item.entityId);

      // CREATE (never synced): upsert to establish the server row. The default
      // flag is NOT applied here (MALI-055n) — it travels via the dedicated
      // default command, which create() enqueues alongside this row.
      if (existingServerId == null) {
        final response = await retryAccountFenceMutation(() => _remote(() => _remoteSink.upsertAccount(row)));
        final serverId = response['id'] as String;
        await _attachServerId(
            item.entityId, serverId, response['updated_at'] as String?,
            serverRevision: response['revision'] as int?, item: item);
        return _AccountsPushOutcome.pushed;
      }

      // UPDATE — guarded, NEVER a blind upsert (the previous code upserted
      // unconditionally, silently clobbering a concurrent remote edit).
      final serverId = existingServerId;
      Map<String, dynamic>? response;
      {
        // C-6 — fail-safe guarded path (capability OFF, or revision unknown).
        //
        // This used to READ the server's updated_at, compare it, and then issue
        // a blind write by id. Those are two round-trips, so a remote write
        // landing between them was silently clobbered: the guard had passed
        // against a value that was no longer true when the write executed.
        //
        // The predicate now travels WITH the write, exactly as the tombstone
        // path has always done, so the database enforces it and 0 affected rows
        // IS the conflict signal.
        // A-3 (G17): with no stored base token, fetch the row's CURRENT
        // updated_at and guard on that — never a blind id-only write. The local
        // pending edit wins only if the server row is unchanged since the fetch;
        // zero rows (changed or vanished) → conflict, local edit kept.
        final base = item.payloadJson['server_updated_at'] as String? ??
            await _remote(() => _remoteSink.fetchAccountUpdatedAt(serverId));
        response = base == null
            ? null
            : await retryAccountFenceMutation(() => _remote(() => _remoteSink.guardedUpdateAccount(serverId, base, row)));
      }

      // MALI-026 (Phase-9M): a 0-row guarded update returns null → conflict, not
      // an NPE on the ack.
      if (response == null) {
        await _conflictAndAck(item);
        return _AccountsPushOutcome.conflict;
      }

      // The default flag is NOT applied on a field update (MALI-055n) — default
      // changes go exclusively through the dedicated default command.
      await _attachServerId(
          item.entityId, serverId, response['updated_at'] as String?,
          serverRevision: response['revision'] as int?, item: item);
      return _AccountsPushOutcome.pushed;
    } catch (e) {
      if (isTransportConflict(e)) {
        await _conflictAndAck(item);
        return _AccountsPushOutcome.conflict;
      }
      rethrow;
    }
  }

  Future<_AccountsPushOutcome> _pushDelete(
    PlanningOutboxItem item,
    String userId,
  ) async {
    var serverId = await _serverIdForLocalAccount(item.entityId);
    serverId ??= (await _remote(() => _remoteSink.findAccountByLocalId(
        userId, item.entityId)))?['id'] as String?;
    if (serverId == null) {
      await _markSynced(item.entityId, null, item: item);
      return _AccountsPushOutcome.pushed;
    }

    try {
      // MALI-022 / 0068 (Phase-9K): GUARDED tombstone — never an unconditional
      // id-only overwrite. CAS on revision when known; else optimistic
      // updated_at. A zero-row result is classified, so a stale delete can never
      // clobber a newer accepted update.
      final base = item.payloadJson['server_updated_at'] as String?;
      final target = serverId;
      final ack = await _remote(() => _remoteSink.guardedTombstoneAccount(target, base));
      if (ack != null) {
        await _markSynced(item.entityId, serverId, item: item);
        return _AccountsPushOutcome.pushed;
      }
      return await _resolveDeleteConflict(serverId, item);
    } catch (e) {
      if (isTransportConflict(e)) {
        await _conflictAndAck(item);
        return _AccountsPushOutcome.conflict;
      }
      rethrow;
    }
  }

  // ── WP-5: revision CAS (capability `revision_cas`) ───────────────────────

  Future<_AccountsPushOutcome> _casUpsert(
    PlanningOutboxItem item,
    String userId,
  ) async {
    final row = _toServerRow(item.payloadJson, userId);
    final serverId = await _serverIdForLocalAccount(item.entityId);
    final CasDecision d;
    if (serverId == null) {
      d = await _cas.create(
          table: 'user_accounts',
          epoch: _plan.epoch!,
          opId: item.operationId!,
          row: row);
    } else {
      d = await _cas.update(
        table: 'user_accounts',
        epoch: _plan.epoch!,
        opId: item.operationId!,
        priorOpIds: item.priorOpIds,
        serverId: serverId,
        baseRevision:
            item.baseRevision ?? (item.payloadJson['server_revision'] as int?),
        baseUpdatedAt: item.payloadJson['server_updated_at'] as String?,
        patch: row,
      );
      if (d.kind == CasDecisionKind.missing) {
        // No such cloud row: create it again by identity (never un-deletes).
        final again = await _cas.create(
            table: 'user_accounts',
            epoch: _plan.epoch!,
            opId: item.operationId!,
            row: row);
        return _casFinish(item, again,
            again.cloudTombstoned ? SyncConflictKind.tombstone : SyncConflictKind.create);
      }
    }
    return _casFinish(
        item,
        d,
        d.cloudTombstoned
            ? SyncConflictKind.tombstone
            : serverId == null
                ? SyncConflictKind.create
                : SyncConflictKind.update);
  }

  Future<_AccountsPushOutcome> _casDelete(
    PlanningOutboxItem item,
    String userId,
  ) async {
    var serverId = await _serverIdForLocalAccount(item.entityId);
    serverId ??= (await _remote(() => _remoteSink.findAccountByLocalId(
        userId, item.entityId)))?['id'] as String?;
    if (serverId == null) {
      await _markSynced(item.entityId, null, item: item);
      return _AccountsPushOutcome.pushed;
    }
    final d = await _cas.tombstone(
      table: 'user_accounts',
      epoch: _plan.epoch!,
      opId: item.operationId!,
      priorOpIds: item.priorOpIds,
      serverId: serverId,
      baseRevision:
          item.baseRevision ?? (item.payloadJson['server_revision'] as int?),
      baseUpdatedAt: item.payloadJson['server_updated_at'] as String?,
    );
    if (d.kind == CasDecisionKind.acked || d.kind == CasDecisionKind.gone) {
      await _markSynced(item.entityId, serverId, item: item);
      return _AccountsPushOutcome.pushed;
    }
    return _casFinish(item, d, SyncConflictKind.delete);
  }

  Future<_AccountsPushOutcome> _casFinish(
    PlanningOutboxItem item,
    CasDecision d,
    SyncConflictKind conflictKind,
  ) async {
    if (d.kind == CasDecisionKind.acked) {
      await _attachServerId(item.entityId, d.row!['id'] as String,
          d.row!['updated_at'] as String?,
          serverRevision: (d.row!['revision'] as num?)?.toInt(), item: item);
      return _AccountsPushOutcome.pushed;
    }
    // Stored durably BEFORE the outbox op is consumed, in one local transaction.
    await _itemLocal(item, () async {
      await _conflicts.flag(
        entityType: ConflictEntities.account,
        localId: item.entityId,
        kind: conflictKind,
        serverId: d.row?['id'] as String?,
        theirs: d.row,
        theirsRevision: (d.row?['revision'] as num?)?.toInt(),
        operationId: item.operationId,
      );
      await _queue.markSuccess(item);
    });
    return _AccountsPushOutcome.conflict;
  }

  /// A guarded account tombstone matched zero rows — classify (Phase-9K §5):
  /// already-tombstoned → idempotent success; still-live/absent → conflict
  /// (the local soft-deleted row stays 'conflict', recoverable; server intact).
  Future<_AccountsPushOutcome> _resolveDeleteConflict(
    String serverId,
    PlanningOutboxItem item,
  ) async {
    final state = await _remote(() => _remoteSink.fetchAccountState(serverId));
    if (state != null && state['deleted_at'] != null) {
      await _markSynced(item.entityId, serverId, item: item);
      return _AccountsPushOutcome.pushed;
    }
    await _conflictAndAck(item);
    return _AccountsPushOutcome.conflict;
  }

  Future<String?> _serverIdForLocalAccount(String id) async {
    final row = await _local(() => _db
        .customSelect(
          'SELECT server_id FROM accounts WHERE id = ${sqlString(id)} LIMIT 1;',
        )
        .getSingleOrNull());
    return row?.readNullable<String>('server_id');
  }

  /// A-2 (G3): ACK [item] and persist the server row identity in ONE local
  /// transaction; the account is `synced` only when no outbox row remains for
  /// it (an edit folded in while the push was in flight keeps it pending).
  /// A later local tombstone stays pending even if cloud admission prevented
  /// recording its delete in the outbox while this live write was in flight.
  Future<void> _attachServerId(
    String localId,
    String serverId,
    String? serverUpdatedAt, {
    int? serverRevision,
    required PlanningOutboxItem item,
  }) {
    final now = dateTimeToSql(DateTime.now().toUtc());
    return _itemLocal(item, () async {
      await _queue.acknowledge(
        item,
        serverUpdatedAt: serverUpdatedAt,
        serverRevision: serverRevision,
      );
      await _db.customStatement('''
        UPDATE accounts
        SET server_id = ${sqlString(serverId)},
            synced_at = ${sqlString(now)},
            server_updated_at = ${sqlNullableString(serverUpdatedAt)},
            ${serverRevision != null ? 'server_revision = $serverRevision,' : ''}
            sync_status = CASE WHEN deleted_at IS NOT NULL THEN 'pending'
              WHEN ${_outboxRowExists(localId)}
              THEN sync_status ELSE 'synced' END
        WHERE id = ${sqlString(localId)};
      ''');
    });
  }

  static String _outboxRowExists(String localId) =>
      'EXISTS (SELECT 1 FROM planning_sync_outbox '
      "WHERE entity_type = 'account' AND entity_id = ${sqlString(localId)})";

  Future<void> _markSynced(
    String localId,
    String? serverId, {
    required PlanningOutboxItem item,
  }) {
    final now = dateTimeToSql(DateTime.now().toUtc());
    return _itemLocal(item, () async {
      await _queue.acknowledge(item);
      await _db.customStatement('''
        UPDATE accounts
        SET ${serverId == null ? '' : 'server_id = ${sqlString(serverId)},'}
            synced_at = ${sqlString(now)},
            sync_status = CASE WHEN ${_outboxRowExists(localId)}
              THEN sync_status ELSE 'synced' END
        WHERE id = ${sqlString(localId)};
      ''');
    });
  }

  Future<void> _conflictAndAck(PlanningOutboxItem item) => _itemLocal(item, () async {
    await _markConflict(item.entityId);
    await _queue.markSuccess(item);
  });

  Future<void> _markConflict(String localId) async {
    await _db.customStatement('''
      UPDATE accounts
      SET sync_status = 'conflict'
      WHERE id = ${sqlString(localId)};
    ''');
  }

  static Map<String, dynamic> _toServerRow(
    Map<String, dynamic> payload,
    String userId,
  ) {
    return {
      'user_id': userId,
      'local_id': payload['local_id'],
      'name': payload['name'],
      'currency': payload['currency'],
      'type': payload['type'],
      'initial_balance': payload['initial_balance'],
      'current_balance': payload['current_balance'],
      'bank_account_number': payload['bank_account_number'],
      'credit_limit': payload['credit_limit'],
      'available_credit': payload['available_credit'],
      'payment_due_day': payload['payment_due_day'],
      'wallet_provider': payload['wallet_provider'],
      'exclude_from_totals': payload['exclude_from_totals'] == true,
      // Older outbox rows may predate the local metadata default. The server
      // column is NOT NULL, so normalize them at send time as well.
      'metadata': payload['metadata'] ?? const <String, dynamic>{},
      // is_default is deliberately NOT part of the upsert row (MALI-015) —
      // it is applied through the atomic set_default_account RPC after the
      // upsert, so the partial unique index can never reject a row because a
      // stale default still exists server-side.
      'sort_order': payload['sort_order'] ?? 0,
      'created_at': payload['created_at'],
    };
  }
}

enum _AccountsPushOutcome { pushed, conflict, abandoned, parked, deferred }

final Object _accountsInvocationKey = Object();

class _AccountsInvocation implements SyncPhaseLifecycle {
  _AccountsInvocation(this.authority, this.handle, this.database, this.phase);
  final AccountFenceAuthority authority;
  final AccountFenceHandle handle;
  @override
  final AppDatabase database;
  final SyncPhaseBinding phase;
  void requireCurrent() {
    if (!isCurrent) throw const AccountsDeliveryStopped(AccountsDeliveryStopReason.stale);
  }
  String get ownerUid => authority.ownerUid(handle);
  @override
  bool get isCurrent => authority.isCurrentForDatabase(handle, database);
  @override
  Future<T> runLocal<T>(Future<T> Function() action) =>
      authority.runCurrentLocal(handle, database, action);
}


/// Guard the actual underlying method after the retry predicate's final await.
class _AccountsCasRemote implements CasRemote {
  _AccountsCasRemote(this.delegate, this.invocation);
  final CasRemote delegate;
  final _AccountsInvocation invocation;

  Future<T> _send<T>(Future<T> Function() send) async {
    void check() {
      if (!invocation.isCurrent) {
        throw const AccountsDeliveryStopped(AccountsDeliveryStopReason.stale);
      }
    }
    check();
    try {
      final result = await send();
      check();
      return result;
    } catch (error) {
      if (decodeAccountsAccountDenial(error) != null) rethrow;
      check();
      rethrow;
    }
  }

  @override
  Future<CasResult> insertIfAbsent({required String table, required String epoch,
      required String opId, required Map<String, dynamic> row}) => _send(() =>
      delegate.insertIfAbsent(table: table, epoch: epoch, opId: opId, row: row));

  @override
  Future<CasResult> casUpdate({required String table, required String epoch,
      required String opId, required String serverId, required int expectedRevision,
      required Map<String, dynamic> patch}) => _send(() => delegate.casUpdate(
      table: table, epoch: epoch, opId: opId, serverId: serverId,
      expectedRevision: expectedRevision, patch: patch));

  @override
  Future<CasResult> casTombstone({required String table, required String epoch,
      required String opId, required String serverId, required int expectedRevision}) =>
      _send(() => delegate.casTombstone(table: table, epoch: epoch, opId: opId,
          serverId: serverId, expectedRevision: expectedRevision));

  @override
  Future<Map<String, dynamic>?> fetchRow(String table, String serverId) =>
      _send(() => delegate.fetchRow(table, serverId));
}
