import '../sync/sync_cursor.dart';
import 'app_database.dart';
import 'financial_cache_health.dart';

/// Outcome of reconciling one financial-cache pull domain.
enum ReconcileDomainResult {
  /// No dirty marker for any entity in this domain — nothing to do (the steady
  /// state: no marker => no-op forever).
  noDirtyState,

  /// Every dirty entity's forced re-pull reached true EOF under a still-valid
  /// admission generation, and its marker was cleared.
  completed,

  /// The domain's pull capability was disabled this session — not attempted. The
  /// marker and the persisted cursor are left unchanged.
  deferred,

  /// The captured admission generation became invalid (sign-out / relogin under a
  /// new generation) before, during, or after the pull. NOT a transport failure:
  /// callers must not log it as a network error or schedule backoff. The marker
  /// is left set; the next valid generation re-reconciles from epoch.
  cancelled,

  /// Attempted under a valid generation but did not reach EOF for at least one
  /// dirty entity (transport / page / apply error). Marker(s) left set.
  failed,
}

/// Deterministic aggregate across per-domain outcomes. Precedence:
/// cancelled > failed > deferred > completed > noDirtyState. A mixture such as
/// {accounts: completed, planning: deferred} aggregates to `deferred` — never to
/// `completed`. The per-domain map remains authoritative; this is only for a
/// single top-line signal (e.g. deciding whether a stale generation must abort
/// the rest of the sync body).
ReconcileDomainResult aggregateReconcileResult(
  Iterable<ReconcileDomainResult> results,
) {
  const precedence = [
    ReconcileDomainResult.cancelled,
    ReconcileDomainResult.failed,
    ReconcileDomainResult.deferred,
    ReconcileDomainResult.completed,
    ReconcileDomainResult.noDirtyState,
  ];
  for (final level in precedence) {
    if (results.contains(level)) return level;
  }
  return ReconcileDomainResult.noDirtyState;
}

/// One reconcilable pull domain: the financial-cache [entities] it owns, an
/// [isEnabled] capability gate, and [runFromEpoch] which forces a full re-pull of
/// the given dirty entities through the NORMAL pull/merge machinery — starting
/// from epoch (not trusting the incremental high-water cursor) and checking
/// [isAdmitted] at every page boundary — returning the set of entity types that
/// reached TRUE EOF this pass.
class ReconcileDomain {
  const ReconcileDomain({
    required this.name,
    required this.entities,
    required this.isEnabled,
    required this.runFromEpoch,
  });

  final String name;
  final Set<String> entities;
  final bool Function() isEnabled;
  final Future<Set<String>> Function({
    required Set<String> dirtyEntities,
    required bool Function() isAdmitted,
  }) runFromEpoch;
}

/// MALI-034: one-time reconciliation of legacy `financial_cache_health` dirty
/// markers left by the retired Supabase-primary write path. This REPLACES the
/// recurring `FinancialCacheRepairService` — instead of reading Supabase as an
/// authoritative repository and rebuilding the Drift mirror, it drives the normal
/// pull/merge to re-pull the affected domain from epoch and clears a marker only
/// on true-EOF completion under a still-valid admission generation. No new
/// backend migration; no new dirty writers exist after Supabase-primary
/// retirement, so once every marker is cleared this is a permanent no-op.
///
/// Local financial usability MUST NOT depend on this completing — it runs inside
/// the background sync body and its result is observational only.
class LegacyFinancialCacheReconciler {
  const LegacyFinancialCacheReconciler({
    required AppDatabase db,
    required int generation,
    required bool Function(int generation) isAdmitted,
  })  : _db = db,
        _generation = generation,
        _isAdmitted = isAdmitted;

  final AppDatabase _db;
  final int _generation;
  final bool Function(int) _isAdmitted;

  /// Synchronous, in-memory re-validation of the EXACT generation captured when
  /// this reconciliation started. A sign-out (which bumps the generation) makes
  /// this false even if the same user re-authenticates under a later generation.
  bool _admitted() => _isAdmitted(_generation);

  /// Public exact-generation admission check. The in-slot wiring hands this SAME
  /// guard to normal incremental pulls too, so ownership protection is uniform
  /// whether or not a domain is dirty (requirement 2).
  bool isAdmitted() => _admitted();

  /// In-slot reconciliation of ONE domain: reads the domain's dirty markers, and
  /// if any are dirty forces the epoch re-pull (via [ReconcileDomain.
  /// runFromEpoch]) at the caller's existing post-push pull slot, clearing each
  /// marker only on true completion under a still-valid admission generation.
  /// Returns [noDirtyState] (the caller then runs its NORMAL incremental pull)
  /// when nothing in the domain is dirty. This is the single primitive used by
  /// BOTH the production in-slot wiring and the unit tests.
  Future<ReconcileDomainResult> reconcileDomain(ReconcileDomain domain) async {
    final dirty = <String>{};
    for (final entity in domain.entities) {
      if (await isFinancialCacheDirty(_db, entity)) dirty.add(entity);
    }
    if (dirty.isEmpty) return ReconcileDomainResult.noDirtyState;

    // Contract C1 order: verify admission, then capability, BEFORE any pull work.
    if (!_admitted()) return ReconcileDomainResult.cancelled;
    if (!domain.isEnabled()) return ReconcileDomainResult.deferred;

    // Force the full re-pull from epoch through the normal merge, cancellable at
    // every page. Committed pages/cursor are the pull's own durable progress.
    final completedEntities = await domain.runFromEpoch(
      dirtyEntities: dirty,
      isAdmitted: _admitted,
    );

    // Completion -> clear admission race: a stale generation must not clear.
    // Re-validate the captured generation AFTER the pull and immediately before
    // each clear. Do NOT undo committed pages/cursor; the marker simply survives.
    if (!_admitted()) return ReconcileDomainResult.cancelled;

    var allCleared = true;
    for (final entity in dirty) {
      // Clear-only contract: true completion AND still-admitted, checked
      // atomically at the mutation boundary (sync admit + UPDATE in one txn).
      if (completedEntities.contains(entity)) {
        final cleared =
            await clearFinancialCacheDirtyIfAdmitted(_db, entity, _admitted);
        if (!cleared) allCleared = false;
      } else {
        allCleared = false;
      }
    }

    if (!_admitted()) return ReconcileDomainResult.cancelled;
    return allCleared
        ? ReconcileDomainResult.completed
        : ReconcileDomainResult.failed;
  }
}

/// The in-slot pull decision reused at every domain's post-push pull slot:
///  - no reconciler / clean domain -> run [normalPull] (today's behaviour);
///  - dirty domain -> reconcileDomain runs the epoch pull, which REPLACES the
///    normal pull, and clears markers on completion.
///
/// Requirement 2: the SAME exact-generation admission guard is handed to
/// [normalPull] too, so a normal incremental pull also aborts at a page boundary
/// if the invocation's generation is invalidated. Returns the domain outcome;
/// the caller aborts the sync body on [ReconcileDomainResult.cancelled] and
/// suppress-only on failed/deferred.
Future<ReconcileDomainResult> reconcileOrPull({
  required LegacyFinancialCacheReconciler? reconciler,
  required ReconcileDomain domain,
  required Future<void> Function(bool Function() isAdmitted) normalPull,
}) async {
  final admitted = reconciler == null ? alwaysAdmitted : reconciler.isAdmitted;
  if (reconciler == null) {
    await normalPull(admitted);
    return ReconcileDomainResult.noDirtyState;
  }
  final result = await reconciler.reconcileDomain(domain);
  if (result == ReconcileDomainResult.noDirtyState) {
    await normalPull(admitted);
  }
  return result;
}
