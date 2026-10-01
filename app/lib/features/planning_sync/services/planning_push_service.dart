import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../core/sync/guarded_mutation.dart';
import '../../../core/sync/outbox_failure.dart';
import '../../../core/sync/sync_capabilities.dart';
import '../../../core/sync/sync_health.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/planning_cutover.dart';
import '../../../data/db/sql_value_codec.dart';
import '../../../data/sync/exact_transport_capability.dart';
import 'planning_outbox_queue.dart';

/// Acknowledgement columns a guarded write reads back — includes the server
/// `revision` only when the CAS capability (and thus 0068) is present.
const String _ackCols =
    kServerRevisionCas ? 'id, updated_at, revision' : 'id, updated_at';

/// A-3 (G7): remote tables whose `(user_id, local_id)` uniqueness is only a
/// PARTIAL index (migrations 0021/0055) — `ON CONFLICT (user_id, local_id)`
/// cannot target it, so creates are INSERT + replay-by-lookup, not upsert.
const Set<String> kPartialLocalIdIndexTables = {
  'user_budgets',
  'user_goals',
  'user_plans',
  'user_subscriptions',
};

class PlanningPushResult {
  const PlanningPushResult({
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

  /// MALI-026 (B8-2.10 §8): money rows held for unverified exact transport.
  final int parked;
}

abstract class PlanningRemoteSink {
  Future<Map<String, dynamic>> upsert(
    String table,
    Map<String, dynamic> row,
  );

  Future<Map<String, dynamic>?> findByLocalId(
    String table,
    String userId,
    String localId,
  );

  /// MALI-022 / 0068 (Phase-9K) — atomic compare-and-set tombstone. Sets
  /// `deleted_at` only if the row's server `revision` still equals
  /// [expectedRevision]; returns the ack (id/updated_at/revision), or null when
  /// no row matched — a stale delete that must NOT overwrite a newer update.
  Future<Map<String, dynamic>?> casTombstone(
    String table,
    String serverId,
    int expectedRevision,
  );

  /// MALI-022 (Phase-9K) — guarded tombstone without a revision base. Sets
  /// `deleted_at` only if the row still matches [expectedUpdatedAt] (an
  /// optimistic timestamp compare); when that is null, only if the row is not
  /// already tombstoned. Returns the ack, or null when no row matched. NEVER an
  /// id-only blind overwrite.
  Future<Map<String, dynamic>?> guardedTombstone(
    String table,
    String serverId,
    String? expectedUpdatedAt,
  );

  /// MALI-022 (Phase-9K) — the row's current `{deleted_at}` (null if the row is
  /// gone). Classifies a zero-row guarded tombstone: already-tombstoned (delete
  /// converged) vs still-live (a newer update advanced past our base) vs absent.
  Future<Map<String, dynamic>?> fetchRowState(String table, String serverId);

  /// MALI-022 — the current server `updated_at` for a known server row, used as
  /// the optimistic-concurrency compare on update. Null if the row is gone.
  Future<String?> fetchServerUpdatedAt(String table, String serverId);

  /// MALI-022 — targeted update of a known server row (used only after the
  /// base-token guard passes), returning the new id + updated_at, or null when
  /// 0 rows matched (the row vanished in the race window → a conflict).
  Future<Map<String, dynamic>?> updateByServerId(
    String table,
    String serverId,
    Map<String, dynamic> row,
  );

  /// C-6 — atomic guarded update. Applies [row] only if the server row's
  /// `updated_at` still equals [expectedUpdatedAt], so the comparison and the
  /// write are ONE statement the database evaluates. Returns the ack, or null
  /// when no row matched — a genuine conflict, not a failure.
  Future<Map<String, dynamic>?> guardedUpdateByServerId(
    String table,
    String serverId,
    String expectedUpdatedAt,
    Map<String, dynamic> row,
  );

  /// MALI-022 / 0068 — atomic compare-and-set update. Updates the row only if
  /// its server `revision` still equals [expectedRevision]; returns the new
  /// id/updated_at/revision, or null when no row matched (a genuine conflict).
  Future<Map<String, dynamic>?> casUpdateByServerId(
    String table,
    String serverId,
    int expectedRevision,
    Map<String, dynamic> row,
  );
}

class SupabasePlanningRemoteSink implements PlanningRemoteSink {
  const SupabasePlanningRemoteSink();

  SupabaseClient get _client => Supabase.instance.client;

  @override
  Future<Map<String, dynamic>?> findByLocalId(
    String table,
    String userId,
    String localId,
  ) async {
    return await _client
        .from(table)
        .select(_ackCols)
        .eq('user_id', userId)
        .eq('local_id', localId)
        .maybeSingle();
  }

  @override
  Future<Map<String, dynamic>?> casTombstone(
    String table,
    String serverId,
    int expectedRevision,
  ) async {
    // MALI-026 (Phase-9M): decode the LIST (0/1/>1), never maybeSingle — a 0-row
    // CAS is the conflict branch, not a PGRST116 throw.
    final rows = await _client
        .from(table)
        .update({'deleted_at': DateTime.now().toUtc().toIso8601String()})
        .eq('id', serverId)
        .eq('revision', expectedRevision)
        .select(_ackCols);
    return guardedAck(rows, 'planning.casTombstone[$table]');
  }

  @override
  Future<Map<String, dynamic>?> guardedTombstone(
    String table,
    String serverId,
    String? expectedUpdatedAt,
  ) async {
    // Never id-only: guard on the last-known updated_at, or (when unknown) on
    // the row not already being tombstoned. Each branch is a single chained
    // statement so the guard predicate always travels with the deleted_at write.
    final deletedAt = DateTime.now().toUtc().toIso8601String();
    final rows = expectedUpdatedAt != null
        ? await _client
            .from(table)
            .update({'deleted_at': deletedAt})
            .eq('id', serverId)
            .eq('updated_at', expectedUpdatedAt)
            .select('id, updated_at')
        : await _client
            .from(table)
            .update({'deleted_at': deletedAt})
            .eq('id', serverId)
            .isFilter('deleted_at', null)
            .select('id, updated_at');
    return guardedAck(rows, 'planning.guardedTombstone[$table]');
  }

  @override
  Future<Map<String, dynamic>?> fetchRowState(
    String table,
    String serverId,
  ) async {
    return await _client
        .from(table)
        .select('deleted_at')
        .eq('id', serverId)
        .maybeSingle();
  }

  @override
  Future<Map<String, dynamic>> upsert(
    String table,
    Map<String, dynamic> row,
  ) async {
    // A-3 (G7): these tables only have a PARTIAL unique index
    // `(user_id, local_id) WHERE local_id IS NOT NULL`, which PostgREST's
    // `on_conflict=user_id,local_id` cannot target (42P10). A plain INSERT is
    // used instead; a replay of the same create surfaces as 23505, which the
    // push service resolves by fetching the existing row.
    if (kPartialLocalIdIndexTables.contains(table)) {
      return await _client.from(table).insert(row).select(_ackCols).single();
    }
    return await _client
        .from(table)
        .upsert(row, onConflict: 'user_id,local_id')
        .select(_ackCols)
        .single();
  }

  @override
  Future<Map<String, dynamic>?> casUpdateByServerId(
    String table,
    String serverId,
    int expectedRevision,
    Map<String, dynamic> row,
  ) async {
    final rows = await _client
        .from(table)
        .update(row)
        .eq('id', serverId)
        .eq('revision', expectedRevision)
        .select(_ackCols);
    return guardedAck(rows, 'planning.casUpdate[$table]');
  }

  @override
  Future<String?> fetchServerUpdatedAt(String table, String serverId) async {
    final row = await _client
        .from(table)
        .select('updated_at')
        .eq('id', serverId)
        .maybeSingle();
    return row?['updated_at'] as String?;
  }

  @override
  Future<Map<String, dynamic>?> updateByServerId(
    String table,
    String serverId,
    Map<String, dynamic> row,
  ) async {
    // MALI-026 (Phase-9M): the guarded OFF update runs after the base-token
    // compare; a 0-row result (the row vanished in the race window) is a
    // conflict, decoded from the LIST — never a single-cardinality throw.
    final rows = await _client
        .from(table)
        .update(row)
        .eq('id', serverId)
        .select(_ackCols);
    return guardedAck(rows, 'planning.guardedUpdate[$table]');
  }

  @override
  Future<Map<String, dynamic>?> guardedUpdateByServerId(
    String table,
    String serverId,
    String expectedUpdatedAt,
    Map<String, dynamic> row,
  ) async {
    // C-6: the predicate travels WITH the write, so the database enforces it.
    final rows = await _client
        .from(table)
        .update(row)
        .eq('id', serverId)
        .eq('updated_at', expectedUpdatedAt)
        .select(_ackCols);
    return guardedAck(rows, 'planning.atomicGuardedUpdate[$table]');
  }
}

class PlanningPushService {
  PlanningPushService({
    required AppDatabase db,
    required PlanningOutboxQueue queue,
    required bool Function(String entityType) isEnabled,
    Future<String?> Function()? getAuthUserId,
    PlanningRemoteSink? remoteSink,
    bool revisionCasEnabled = kServerRevisionCas,
    // MALI-026 (B8-2.10 §8/§9): both defaults preserve schema-v29 behavior:
    // legacy authority never parks, regardless of the unknown capability.
    PlanningCutoverCoordinator coordinator =
        const SchemaV29PlanningCutoverCoordinator(),
    ExactTransportCapability Function() pushCapability = _defaultPushCapability,
    // MALI-026 (B8-3 §30): whether the SERVER carries per-row planning currency
    // (0077). Budgets/goals push parks on THIS (they need a server currency
    // column), independent of the exact decimal-string transport capability.
    ExactTransportCapability Function() planningCurrencyCapability =
        _defaultPushCapability,
    /// C-3 / G13 — budgets, goals, plans, subscriptions, cards and categories
    /// are financial data. Consent is asked fresh per push and defaults to
    /// DENY, so a caller that omits it performs no network at all.
    Future<bool> Function()? mayEgress,
    /// `user_settings` carries PII (profile) — a separate egress class. Falls
    /// back to [mayEgress] (and therefore to DENY) when omitted.
    Future<bool> Function()? mayEgressProfile,
    SyncHealth? health,
  })  : _mayEgress = mayEgress ?? _denyEgressByDefault,
        _mayEgressProfile =
            mayEgressProfile ?? mayEgress ?? _denyEgressByDefault,
        _health = health,
        _db = db,
        _queue = queue,
        _isEnabled = isEnabled,
        _getAuthUserId = getAuthUserId ?? _defaultGetAuthUserId,
        _remoteSink = remoteSink ?? const SupabasePlanningRemoteSink(),
        _revisionCasEnabled = revisionCasEnabled,
        _coordinator = coordinator,
        _pushCapability = pushCapability,
        _planningCurrencyCapability = planningCurrencyCapability;

  static ExactTransportCapability _defaultPushCapability() =>
      ExactTransportCapability.unknown;

  static Future<bool> _denyEgressByDefault() async => false;

  final Future<bool> Function() _mayEgress;
  final Future<bool> Function() _mayEgressProfile;
  final SyncHealth? _health;

  /// Outbox ids whose consent revocation was already delivered while consent is
  /// off — the row stays pending (its full payload must not egress) so this
  /// avoids re-sending the same narrow patch on every drain.
  final Set<String> _revocationDelivered = <String>{};

  static const _planningCurrencyEntityTypes = {
    PlanningOutboxQueue.budgetsEntityType,
    PlanningOutboxQueue.goalsEntityType,
  };

  final AppDatabase _db;
  final PlanningOutboxQueue _queue;
  final bool Function(String entityType) _isEnabled;
  final Future<String?> Function() _getAuthUserId;
  final PlanningRemoteSink _remoteSink;

  /// MALI-022 / 0068 — whether to use the atomic revision CAS. Defaults to the
  /// [kServerRevisionCas] capability const (OFF until 0068 verified on staging);
  /// injectable so the ON path is testable.
  final bool _revisionCasEnabled;
  final PlanningCutoverCoordinator _coordinator;
  final ExactTransportCapability Function() _pushCapability;
  final ExactTransportCapability Function() _planningCurrencyCapability;

  static const _moneyEntityTypes = {
    PlanningOutboxQueue.accountsEntityType,
    PlanningOutboxQueue.subscriptionsEntityType,
    PlanningOutboxQueue.plansEntityType,
    PlanningOutboxQueue.billPaymentsEntityType,
    // MALI-026 (B8-3 §30) — budgets/goals become canonical planning money at v30.
    // Their exact push depends on the server per-row currency column (0077, still
    // UNDEPLOYED), so canonical push parks until that capability is verified.
    PlanningOutboxQueue.budgetsEntityType,
    PlanningOutboxQueue.goalsEntityType,
  };

  static const _entityTable = {
    PlanningOutboxQueue.budgetsEntityType: 'user_budgets',
    PlanningOutboxQueue.subscriptionsEntityType: 'user_subscriptions',
    PlanningOutboxQueue.goalsEntityType: 'user_goals',
    PlanningOutboxQueue.plansEntityType: 'user_plans',
    PlanningOutboxQueue.cardsEntityType: 'user_cards',
    PlanningOutboxQueue.categoriesEntityType: 'user_categories',
    PlanningOutboxQueue.settingsEntityType: 'user_settings',
  };

  static const _localTable = {
    PlanningOutboxQueue.budgetsEntityType: 'budgets',
    PlanningOutboxQueue.subscriptionsEntityType: 'subscriptions',
    PlanningOutboxQueue.goalsEntityType: 'goals',
    PlanningOutboxQueue.plansEntityType: 'plans',
    PlanningOutboxQueue.cardsEntityType: 'cards',
    PlanningOutboxQueue.categoriesEntityType: 'categories',
    PlanningOutboxQueue.settingsEntityType: 'user_settings',
  };

  static Future<String?> _defaultGetAuthUserId() async {
    if (!SupabaseConfig.isConfigured) return null;
    try {
      return Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  Future<PlanningPushResult> push() async {
    final userId = await _getAuthUserId();
    if (userId == null) return const PlanningPushResult();

    // MALI-026 (B8-2.10 §9): a verified exact transport re-arms the SAME
    // durable rows before this drain starts.
    if (_pushCapability() == ExactTransportCapability.verifiedExact) {
      await _queue.reArmParked();
    }
    var pushed = 0;
    var conflicts = 0;
    var failed = 0;
    var abandoned = 0;
    var parked = 0;

    // Consent is read fresh, per egress class, before any row is touched. A
    // denied class leaves its rows pending: no network, no attempt consumed.
    final financialAllowed = await _mayEgress();
    final profileAllowed = await _mayEgressProfile();
    if (!financialAllowed || !profileAllowed) {
      _health?.noteConsentBlocked(SyncDomain.planning);
    }

    // A-2: unpark rows whose dependency resolved (settings bound / budget
    // category / card account), THEN enforce row ownership so a dependency row
    // recorded for another owner is parked again before anything is sent (G18).
    // Skipped entirely while BOTH egress classes are denied: with consent off
    // the outbox is left exactly as it is.
    if (financialAllowed || profileAllowed) {
      await _queue.resolveDependencies();
      await _queue.reconcileOwnership(userId);
    }

    for (final entityType in _entityTable.keys) {
      if (!_isEnabled(entityType)) continue;
      final isSettings = entityType == PlanningOutboxQueue.settingsEntityType;
      final allowed = isSettings ? profileAllowed : financialAllowed;
      if (!allowed && !isSettings) continue;
      final items = await _queue.pendingItems(entityType: entityType);
      for (final item in items) {
        try {
          if (!allowed) {
            // The ONE deliberate exception: a consent REVOCATION must still
            // reach the server (user_settings is its consent authority).
            if (_consentOffPatch(item) == null) continue;
            if (item.payloadJson['consent_only'] != true) {
              await _deliverRevocationOnly(item);
              continue;
            }
            // A pre-bind consent-only create carries no other column: send it
            // exactly as before.
          }
          final outcome = await _process(item, userId);
          switch (outcome) {
            case _PlanningPushOutcome.pushed:
              pushed++;
            case _PlanningPushOutcome.conflict:
              conflicts++;
            case _PlanningPushOutcome.abandoned:
              abandoned++;
            case _PlanningPushOutcome.parked:
              // Held durably; not sent, synced, failed, or retried.
              parked++;
              _health?.noteCapabilityParked(SyncDomain.planning);
          }
        } catch (e) {
          failed++;
          _health?.noteFailure(SyncDomain.planning, e);
          await _queue.markFailed(
              item.id, e.toString(), classifyOutboxError(e));
          if (kDebugMode) debugPrint('[PlanningPush] item error: $e');
        }
      }
    }

    if (kDebugMode) {
      debugPrint(
        '[PlanningPush] done: pushed=$pushed conflicts=$conflicts '
        'failed=$failed abandoned=$abandoned',
      );
    }
    return PlanningPushResult(
      pushed: pushed,
      conflicts: conflicts,
      failed: failed,
      abandoned: abandoned,
      parked: parked,
    );
  }

  /// Consent is OFF and this settings row is a revocation whose payload is a
  /// full row (display name, phone, date of birth, ...). Only the consent-OFF
  /// columns may leave the device; the full row stays pending until consent
  /// returns. Needs a bound server row — an unbound singleton is covered by the
  /// separate consent-only create.
  Future<void> _deliverRevocationOnly(PlanningOutboxItem item) async {
    if (_revocationDelivered.contains(item.id)) return;
    final localTable = _localTable[item.entityType]!;
    final serverId = await _serverIdForLocal(localTable, item.entityId);
    if (serverId == null) return;
    final response = await _remoteSink.updateByServerId(
        _entityTable[item.entityType]!, serverId, _consentOffPatch(item)!);
    if (response == null) {
      throw StateError('settings_consent_revocation_not_synced');
    }
    _revocationDelivered.add(item.id);
  }

  Future<_PlanningPushOutcome> _process(
    PlanningOutboxItem item,
    String userId,
  ) async {
    // MALI-026 (B8-2.10 §8 / B8-3 §30): money entities park on the relevant
    // capability. Budgets/goals need BOTH the exact decimal-string transport AND
    // the SERVER per-row currency column (0077), so they park unless BOTH are
    // verified (the weaker of the two) — never unpark on one alone. Everything
    // else parks on the exact decimal-string transport capability. Non-delete
    // writes only.
    final capability = _planningCurrencyEntityTypes.contains(item.entityType)
        ? weakerCapability(_planningCurrencyCapability(), _pushCapability())
        : _pushCapability();
    if (item.operation != PlanningSyncOperation.delete &&
        _moneyEntityTypes.contains(item.entityType) &&
        shouldParkExactMoneyWrite(
          cutoverState: _coordinator.state(),
          pushCapability: capability,
        )) {
      await _queue.park(item.id, exactMoneyTransportUnverifiedReason);
      return _PlanningPushOutcome.parked;
    }

    final remoteTable = _entityTable[item.entityType];
    final localTable = _localTable[item.entityType];
    if (remoteTable == null || localTable == null) {
      await _queue.markSuccess(item);
      return _PlanningPushOutcome.abandoned;
    }

    switch (item.operation) {
      case PlanningSyncOperation.create:
      case PlanningSyncOperation.update:
        return _pushUpsert(item, userId, remoteTable, localTable);
      case PlanningSyncOperation.delete:
        return _pushDelete(item, userId, remoteTable, localTable);
    }
  }

  Future<_PlanningPushOutcome> _pushUpsert(
    PlanningOutboxItem item,
    String userId,
    String remoteTable,
    String localTable,
  ) async {
    final row = _toServerRow(item.entityType, item.payloadJson, userId);
    var serverId = await _serverIdForLocal(localTable, item.entityId);
    // Tokens of the row we are about to update. Normally the locally stored
    // base; after an idempotent create REPLAY they are the freshly fetched ones.
    int? expectedRevision = item.payloadJson['server_revision'] as int?;
    String? base = item.payloadJson['server_updated_at'] as String?;
    try {
      // CREATE (never synced): establish the server row.
      if (serverId == null) {
        Map<String, dynamic> response;
        try {
          response = await _remoteSink.upsert(remoteTable, row);
        } on PostgrestException catch (e) {
          // A-3 (G7/G16): 23505 on a partial-index table is a REPLAY of a create
          // that already landed (the ack was lost) only if the row for this
          // (user_id, local_id) exists. Anything else is a different unique
          // constraint → rethrown and classified duplicate_business_key.
          if (e.code != '23505' ||
              !kPartialLocalIdIndexTables.contains(remoteTable)) {
            rethrow;
          }
          final existing = await _remoteSink.findByLocalId(
              remoteTable, userId, item.entityId);
          if (existing == null) rethrow;
          // Replay: the create landed. Continue as an UPDATE of that row, guarded
          // by the token we just fetched, so a newer local payload (edits folded
          // into the create row) is applied without clobbering a concurrent
          // server change.
          serverId = existing['id'] as String;
          expectedRevision = existing['revision'] as int?;
          base = existing['updated_at'] as String?;
          return await _guardedUpdate(item, serverId, remoteTable, localTable,
              row, expectedRevision, base);
        }
        // Audit NEW-H-3 — a pre-bind CONSENT-ONLY push delivers the revocation
        // and nothing else. It deliberately does NOT bind the local singleton:
        // attaching server_id here would lift the pre-bind guard and let the
        // next automatic full-row update clobber the user's real cloud settings
        // with this device's fresh defaults before the first pull merges them.
        // The row stays unbound; the genuine pull binds it and (for a local
        // revocation) preserves the OFF consent, re-queuing the merged update.
        if (item.payloadJson['consent_only'] == true) {
          await _queue.markSuccess(item);
          return _PlanningPushOutcome.pushed;
        }
        await _attachServerId(localTable, item.entityId,
            response['id'] as String, response['updated_at'] as String?,
            serverRevision: response['revision'] as int?, item: item);
        return _PlanningPushOutcome.pushed;
      }

      return await _guardedUpdate(item, serverId, remoteTable, localTable, row,
          expectedRevision, base);
    } catch (e) {
      if (isTransportConflict(e)) {
        return _resolveUpsertConflict(item, serverId, remoteTable, localTable);
      }
      rethrow;
    }
  }

  /// UPDATE of a known server row — ALWAYS guarded, never a blind write.
  ///
  /// MALI-022 / 0068 — atomic compare-and-set on `revision` when the capability
  /// is on AND a base revision is known. Otherwise the guard is the server
  /// `updated_at`: the locally stored base token, or — A-3 (G17) — when there is
  /// none, the row's CURRENT `updated_at` fetched just now. The guard travels
  /// WITH the write (C-6), so a change landing between the fetch and the write
  /// yields zero rows = conflict. Semantics when no base is held: the local
  /// pending edit wins only if the server row is unchanged since that fetch;
  /// a zero-row result (changed or vanished) takes the conflict path and the
  /// local edit is kept, never discarded and never overwriting the server.
  Future<_PlanningPushOutcome> _guardedUpdate(
    PlanningOutboxItem item,
    String serverId,
    String remoteTable,
    String localTable,
    Map<String, dynamic> row,
    int? expectedRevision,
    String? base,
  ) async {
    if (_revisionCasEnabled && expectedRevision != null) {
      final response = await _remoteSink.casUpdateByServerId(
          remoteTable, serverId, expectedRevision, row);
      if (response == null) {
        return await _resolveUpsertConflict(
            item, serverId, remoteTable, localTable);
      }
      await _attachServerId(localTable, item.entityId,
          response['id'] as String, response['updated_at'] as String?,
          serverRevision: response['revision'] as int?, item: item);
      return _PlanningPushOutcome.pushed;
    }

    base ??= await _remoteSink.fetchServerUpdatedAt(remoteTable, serverId);
    if (base == null) {
      // The server row is gone: nothing to guard against → conflict.
      return await _resolveUpsertConflict(
          item, serverId, remoteTable, localTable);
    }
    final response = await _remoteSink.guardedUpdateByServerId(
        remoteTable, serverId, base, row);
    if (response == null) {
      return await _resolveUpsertConflict(
          item, serverId, remoteTable, localTable);
    }
    await _attachServerId(localTable, item.entityId, response['id'] as String,
        response['updated_at'] as String?,
        serverRevision: response['revision'] as int?, item: item);
    return _PlanningPushOutcome.pushed;
  }

  /// Settings normally keep the deterministic prefer-remote policy. Consent is
  /// the security exception: after a stale full-row write loses its CAS, apply
  /// only the OFF fields as a narrow update. Concurrent non-consent edits are
  /// therefore untouched, while the outbox is consumed only after the server
  /// acknowledges the revocation. A failed acknowledgement throws, retaining
  /// the durable row for normal retry/backoff instead of silently resolving it.
  Future<_PlanningPushOutcome> _resolveUpsertConflict(
    PlanningOutboxItem item,
    String? serverId,
    String remoteTable,
    String localTable,
  ) async {
    final consentOff = _consentOffPatch(item);
    if (consentOff != null && serverId != null) {
      final response =
          await _remoteSink.updateByServerId(remoteTable, serverId, consentOff);
      if (response == null) {
        throw StateError('settings_consent_revocation_not_synced');
      }
      await _attachServerId(
        localTable,
        item.entityId,
        response['id'] as String,
        response['updated_at'] as String?,
        serverRevision: response['revision'] as int?,
        item: item,
      );
      return _PlanningPushOutcome.pushed;
    }

    await _markConflict(localTable, item.entityId);
    await _queue.markSuccess(item);
    return _PlanningPushOutcome.conflict;
  }

  Map<String, dynamic>? _consentOffPatch(PlanningOutboxItem item) {
    if (item.entityType != PlanningOutboxQueue.settingsEntityType) return null;
    final payload = item.payloadJson;
    final aiOff = payload['ai_consent_granted'] == false;
    final cloudOff = payload['cloud_processing_enabled'] == false;
    if (!aiOff && !cloudOff) return null;
    return <String, dynamic>{
      if (aiOff || cloudOff) 'ai_consent_granted': false,
      if (cloudOff) 'cloud_processing_enabled': false,
    };
  }

  Future<_PlanningPushOutcome> _pushDelete(
    PlanningOutboxItem item,
    String userId,
    String remoteTable,
    String localTable,
  ) async {
    var serverId = await _serverIdForLocal(localTable, item.entityId);
    serverId ??= (await _remoteSink.findByLocalId(
      remoteTable,
      userId,
      item.entityId,
    ))?['id'] as String?;
    if (serverId == null) {
      // Never reached the server — nothing to tombstone.
      await _markSynced(localTable, item.entityId, null, item: item);
      return _PlanningPushOutcome.pushed;
    }

    try {
      // MALI-022 / 0068 (Phase-9K): the tombstone is GUARDED, never an
      // unconditional id-only overwrite. CAS on the base revision when we have
      // one; otherwise an optimistic updated_at compare. A zero-row result is
      // classified (already-deleted / advanced / absent) — a stale delete can
      // never clobber a newer accepted update.
      final expectedRevision = item.payloadJson['server_revision'] as int?;
      if (_revisionCasEnabled && expectedRevision != null) {
        final ack = await _remoteSink.casTombstone(
            remoteTable, serverId, expectedRevision);
        if (ack != null) {
          await _markSynced(localTable, item.entityId, serverId, item: item);
          return _PlanningPushOutcome.pushed;
        }
        return await _resolveDeleteConflict(remoteTable, serverId, localTable, item);
      }

      final base = item.payloadJson['server_updated_at'] as String?;
      final ack =
          await _remoteSink.guardedTombstone(remoteTable, serverId, base);
      if (ack != null) {
        await _markSynced(localTable, item.entityId, serverId, item: item);
        return _PlanningPushOutcome.pushed;
      }
      return await _resolveDeleteConflict(remoteTable, serverId, localTable, item);
    } catch (e) {
      if (isTransportConflict(e)) {
        await _markConflict(localTable, item.entityId);
        await _queue.markSuccess(item);
        return _PlanningPushOutcome.conflict;
      }
      rethrow;
    }
  }

  /// A guarded tombstone matched zero rows. Classify it (Phase-9K §5):
  ///   A. already tombstoned  → the delete already converged → idempotent success
  ///   B. still live, advanced → a newer accepted update → conflict, do NOT delete
  ///   C. absent               → fail-closed → conflict (surface, never silent)
  /// On B/C the local (soft-deleted) row stays flagged 'conflict', so the delete
  /// intent is recoverable via keep-mine / keep-theirs and the server is intact.
  Future<_PlanningPushOutcome> _resolveDeleteConflict(
    String remoteTable,
    String serverId,
    String localTable,
    PlanningOutboxItem item,
  ) async {
    final state = await _remoteSink.fetchRowState(remoteTable, serverId);
    if (state != null && state['deleted_at'] != null) {
      await _markSynced(localTable, item.entityId, serverId, item: item); // A
      return _PlanningPushOutcome.pushed;
    }
    await _markConflict(localTable, item.entityId); // B (live) or C (absent)
    await _queue.markSuccess(item);
    return _PlanningPushOutcome.conflict;
  }

  Future<String?> _serverIdForLocal(String table, String localId) async {
    final row = await _db
        .customSelect(
          'SELECT server_id FROM $table WHERE id = ${sqlString(localId)} LIMIT 1;',
        )
        .getSingleOrNull();
    return row?.readNullable<String>('server_id');
  }

  /// A-2 (G3): ACK [item] and persist the server row identity in ONE local
  /// transaction. The entity is marked `synced` only when no outbox row remains
  /// for it (an edit folded in while the push was in flight keeps it pending);
  /// its server id / version are persisted regardless, so the next push is an
  /// update of the same server row.
  Future<void> _attachServerId(
    String table,
    String localId,
    String serverId,
    String? serverUpdatedAt, {
    int? serverRevision,
    required PlanningOutboxItem item,
  }) {
    final now = dateTimeToSql(DateTime.now().toUtc());
    return _db.transaction(() async {
      await _queue.acknowledge(
        item,
        serverUpdatedAt: serverUpdatedAt,
        serverRevision: serverRevision,
      );
      await _db.customStatement('''
        UPDATE $table
        SET server_id = ${sqlString(serverId)},
            synced_at = ${sqlString(now)},
            server_updated_at = ${sqlNullableString(serverUpdatedAt)},
            ${serverRevision != null ? 'server_revision = $serverRevision,' : ''}
            sync_status = CASE WHEN ${_outboxRowExists(item.entityType, localId)}
              THEN sync_status ELSE 'synced' END
        WHERE id = ${sqlString(localId)};
      ''');
    });
  }

  /// SQL predicate: an outbox row still exists for this entity.
  static String _outboxRowExists(String entityType, String localId) =>
      'EXISTS (SELECT 1 FROM planning_sync_outbox '
      'WHERE entity_type = ${sqlString(entityType)} '
      'AND entity_id = ${sqlString(localId)})';

  /// A-2 (G15): a tombstone/idempotent-delete ACK settles the entity (guarded
  /// the same way: never while another edit is still queued for it).
  Future<void> _markSynced(
    String table,
    String localId,
    String? serverId, {
    required PlanningOutboxItem item,
  }) {
    final now = dateTimeToSql(DateTime.now().toUtc());
    return _db.transaction(() async {
      await _queue.acknowledge(item);
      await _db.customStatement('''
        UPDATE $table
        SET ${serverId == null ? '' : 'server_id = ${sqlString(serverId)},'}
            synced_at = ${sqlString(now)},
            sync_status = CASE WHEN ${_outboxRowExists(item.entityType, localId)}
              THEN sync_status ELSE 'synced' END
        WHERE id = ${sqlString(localId)};
      ''');
    });
  }

  Future<void> _markConflict(String table, String localId) async {
    await _db.customStatement('''
      UPDATE $table
      SET sync_status = 'conflict'
      WHERE id = ${sqlString(localId)};
    ''');
  }

  Map<String, dynamic> _toServerRow(
    String entityType,
    Map<String, dynamic> payload,
    String userId,
  ) {
    return switch (entityType) {
      PlanningOutboxQueue.budgetsEntityType => {
          'user_id': userId,
          'local_id': payload['local_id'],
          'local_account_id': payload['local_account_id'],
          'category_id': payload['category_id'],
          'amount': payload['amount'],
          // §7/§30: canonical push carries the row currency (server column 0077).
          // Legacy payloads omit it, so it is only sent when present.
          if (payload['currency'] != null) 'currency': payload['currency'],
          'period': payload['period'],
          'start_date': payload['start_date'],
          'is_active': payload['is_active'] == true,
          'last_notified_spent_amount': payload['last_notified_spent_amount'],
          'last_notified_period_start': payload['last_notified_period_start'],
          'show_on_header': payload['show_on_header'] == true,
        },
      PlanningOutboxQueue.subscriptionsEntityType => {
          'user_id': userId,
          'local_id': payload['local_id'],
          'local_account_id': payload['local_account_id'],
          'merchant_id': payload['merchant_id'],
          'name': payload['name'],
          'amount': payload['amount'],
          'currency': payload['currency'],
          'type': payload['type'],
          'frequency': payload['frequency'],
          'next_due_date': payload['next_due_date'],
          'reminder_on': payload['reminder_on'] == true,
          'is_confirmed': payload['is_confirmed'] == true,
          'custom_interval_days': payload['custom_interval_days'],
          'note': payload['note'],
          'status': payload['status'],
          'total_installments': payload['total_installments'],
          'paid_count': payload['paid_count'],
          'manual_paid_amount': payload['manual_paid_amount'],
          'total_purchase_amount': payload['total_purchase_amount'],
          'lender_name': payload['lender_name'],
          'interest_rate': payload['interest_rate'],
          'created_at': payload['created_at'],
        },
      PlanningOutboxQueue.goalsEntityType => {
          'user_id': userId,
          'local_id': payload['local_id'],
          'local_account_id': payload['local_account_id'],
          'name': payload['name'],
          'target_amount': payload['target_amount'],
          'saved_amount': payload['saved_amount'],
          // §7/§30: canonical push carries the row currency (server column 0077).
          if (payload['currency'] != null) 'currency': payload['currency'],
          'deadline': payload['deadline'],
          'vault_skin': payload['vault_skin'],
          'status': payload['status'],
          'auto_save_amount': payload['auto_save_amount'],
          'auto_save_period': payload['auto_save_period'],
          'auto_save_last_run': payload['auto_save_last_run'],
          'last_notified_saved_amount': payload['last_notified_saved_amount'],
          'created_at': payload['created_at'],
        },
      PlanningOutboxQueue.plansEntityType => {
          'user_id': userId,
          'local_id': payload['local_id'],
          'name': payload['name'],
          'budget_amount': payload['budget_amount'],
          'currency': payload['currency'],
          'start_date': payload['start_date'],
          'end_date': payload['end_date'],
          'local_account_ids': payload['local_account_ids'] ?? const [],
          'card_last4s': payload['card_last4s'] ?? const [],
          'status': payload['status'],
          'icon': payload['icon'],
          'created_at': payload['created_at'],
        },
      PlanningOutboxQueue.cardsEntityType => {
          'user_id': userId,
          'local_id': payload['local_id'],
          'local_account_id': payload['local_account_id'],
          'nickname': payload['nickname'],
          'last4': payload['last4'],
          'network': payload['network'],
          'source': payload['source'],
          // حقول التصميم لا تُرسَل حتى نشر ترقية 0064 (العمودان غير موجودين
          // على الخادم بعد) — انظر kUserCardsCloudV2.
          if (kUserCardsCloudV2) 'color_theme': payload['color_theme'],
          if (kUserCardsCloudV2) 'accent_hex': payload['accent_hex'],
          'created_at': payload['created_at'],
        },
      PlanningOutboxQueue.categoriesEntityType => {
          'user_id': userId,
          'local_id': payload['local_id'],
          'key': payload['key'],
          'name_ar': payload['name_ar'],
          'icon': payload['icon'],
          'color': payload['color'],
          'is_income': payload['is_income'] == true,
        },
      // تفضيلات المستخدم — أعمدة سحابية فقط (لا مفتاح تشفير/أفاتار/ملف شخصي).
      //
      // Audit NEW-H-3: a consent-only payload (pre-bind revocation) must send
      // ONLY the consent authority columns. Every additional key here would be
      // written by the merge-upsert — on a fresh/wiped device those values are
      // reseeded defaults/nulls and would destroy the user's real cloud
      // settings and profile. user_id is the AUTHENTICATED uid (never caller
      // input), so RLS scope is preserved.
      PlanningOutboxQueue.settingsEntityType when payload['consent_only'] == true => {
          'user_id': userId,
          'local_id': payload['local_id'],
          'ai_consent_granted': payload['ai_consent_granted'] == true,
          'cloud_processing_enabled':
              payload['cloud_processing_enabled'] == true,
        },
      PlanningOutboxQueue.settingsEntityType => {
          'user_id': userId,
          'local_id': payload['local_id'],
          'display_name': payload['display_name'],
          'phone_number': payload['phone_number'],
          'date_of_birth': payload['date_of_birth'],
          'theme': payload['theme'],
          'currency': payload['currency'],
          'language': payload['language'],
          'country': payload['country'],
          'input_method': payload['input_method'],
          'notifications_json': payload['notifications_json'],
          'privacy_mode_enabled': payload['privacy_mode_enabled'] == true,
          // These booleans authorize the JWT cloud/AI endpoints. The outbox
          // already normalizes AI OFF when the cloud master gate is OFF.
          // CREATE carries an explicit local choice too; this leaves the server
          // column defaults unchanged for rows created without client values.
          if (payload.containsKey('ai_consent_granted'))
            'ai_consent_granted': payload['ai_consent_granted'] == true,
          if (payload.containsKey('cloud_processing_enabled'))
            'cloud_processing_enabled':
                payload['cloud_processing_enabled'] == true,
        },
      _ => throw ArgumentError('Unsupported planning entity: $entityType'),
    };
  }
}

enum _PlanningPushOutcome { pushed, conflict, abandoned, parked }
