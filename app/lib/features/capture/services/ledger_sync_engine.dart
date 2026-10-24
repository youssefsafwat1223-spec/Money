import 'package:flutter/foundation.dart';

import '../../../core/sync/sync_health.dart';
import '../../../core/session/admission_authority.dart';
import '../../../core/sync/outbox_failure.dart';
import '../../../data/db/financial_cache_health.dart';
import '../../../data/db/financial_cache_reconcile_map.dart';
import '../../../data/db/legacy_financial_cache_reconciler.dart';
import '../../../data/sync/sync_cursor.dart';
import 'ledger_push_service.dart';
import 'ledger_sync_service.dart';

/// Thin interfaces so the engine can be tested without Supabase / Drift.
abstract class LedgerPushAdapter {
  Future<LedgerPushResult> push();
}

abstract class LedgerPullAdapter {
  /// [from]/[isAdmitted] support a Batch-3 in-slot legacy epoch reconciliation
  /// pull; normal callers pass neither and get today's incremental behaviour.
  Future<LedgerSyncResult> pull(
      {SyncCursor? from, bool Function()? isAdmitted});
}

/// Coordinates push → pull in a single call.
///
/// Order matters: push local edits first so the pull doesn't see a stale
/// server state and mark a locally-edited row as 'synced' before our change
/// reaches the server.
class LedgerSyncEngine {
  LedgerSyncEngine({
    required LedgerPushAdapter pushService,
    required LedgerPullAdapter pullService,
    SyncHealth? health,
  })  : _push = pushService,
        _pull = pullService,
        _health = health;

  final SyncHealth? _health;

  /// Runs one ledger phase and records its outcome in [SyncHealth]. Errors keep
  /// propagating to the caller exactly as before.
  Future<T> _phase<T>(SyncDirection direction, Future<T> Function() body,
      {SyncPhaseBinding? binding}) async {
    final health = _health;
    if (health == null) return body();
    return (await health.runPhase(SyncDomain.ledger, direction, body,
        rethrowErrors: true, binding: binding)) as T;
  }

  final LedgerPushAdapter _push;
  final LedgerPullAdapter _pull;

  /// [reconciler] enables the in-slot legacy epoch reconciliation: at the pull
  /// slot (after push), a dirty ledger cache is re-pulled from epoch (replacing
  /// the normal pull); otherwise the normal incremental pull runs — both under
  /// the exact-generation admission guard. Returns the domain outcome so the
  /// caller aborts the sync body on [ReconcileDomainResult.cancelled].
  Future<ReconcileDomainResult> sync({
    LegacyFinancialCacheReconciler? reconciler,
  }) async {
    SyncPhaseBinding? original;
    bool current() => original == null || original.isCurrent;
    void check() {
      if (!current()) throw const LedgerDeliveryStopped(LedgerDeliveryStopReason.stale);
    }
    try {
      final push = _push;
      if (push is LedgerPushService) {
        final binding = SyncPhaseBinding();
        original = binding;
        final health = _health;
        if (health == null) {
          await push.pushWithPhase(binding);
        } else {
          await health.runPhase(SyncDomain.ledger, SyncDirection.push,
              () => push.pushWithPhase(binding),
              binding: binding, rethrowErrors: true);
        }
      } else {
        await _phase(SyncDirection.push, () => push.push());
      }
    } on LedgerDeliveryStopped {
      return ReconcileDomainResult.cancelled;
    } catch (e) {
      if (kDebugMode) debugPrint('[LedgerEngine] push error: $e');
    }
    if (!current()) return ReconcileDomainResult.cancelled;
    try {
      final supplied = reconciler;
      final boundedReconciler = supplied == null || original == null ? supplied
          : _LedgerBoundReconciler(original, supplied);
      final result = await reconcileOrPull(
      reconciler: boundedReconciler,
      domain: ReconcileDomain(
        name: kReconcileDomainLedger,
        entities: const {transactionsCacheEntityType},
        isEnabled: () => true,
        runFromEpoch: ({required dirtyEntities, required isAdmitted}) async {
          check();
          bool admitted() => current() && isAdmitted();
          final r = await _phase(
              SyncDirection.pull,
              () => _pull.pull(
                  from: const SyncCursor.epoch(), isAdmitted: admitted),
              binding: original?.forNextPhase());
          check();
          return r.status == SyncPullStatus.completed
              ? const {transactionsCacheEntityType}
              : const <String>{};
        },
      ),
      normalPull: (sourceAdmitted) async {
        check();
        bool admitted() => current() && sourceAdmitted();
        try {
          await _phase(
              SyncDirection.pull, () => _pull.pull(isAdmitted: admitted),
              binding: original?.forNextPhase());
          check();
        } on LedgerDeliveryStopped {
          rethrow;
        } catch (e) {
          if (kDebugMode) debugPrint('[LedgerEngine] pull error: $e');
        }
      },
      );
      return current() ? result : ReconcileDomainResult.cancelled;
    } on LedgerDeliveryStopped {
      return ReconcileDomainResult.cancelled;
    } catch (_) {
      if (!current()) return ReconcileDomainResult.cancelled;
      rethrow;
    }
  }
}


/// The original ledger lifetime owns each bounded local operation. Network pull
/// runs outside these reservations; each following clear requires fresh currency.
class _LedgerBoundReconciler extends LegacyFinancialCacheReconciler {
  _LedgerBoundReconciler(this.binding, this.supplied)
      : super(db: binding.database!, generation: 0,
            isAdmitted: (_) => binding.isCurrent && supplied.isAdmitted());
  final SyncPhaseBinding binding;
  final LegacyFinancialCacheReconciler supplied;
  bool get current => binding.isCurrent && supplied.isAdmitted();

  Future<T> local<T>(Future<T> Function() action) {
    if (!current) throw const LedgerDeliveryStopped(LedgerDeliveryStopReason.stale);
    return binding.runLocal(action);
  }

  @override
  Future<ReconcileDomainResult> reconcileDomain(ReconcileDomain domain) async {
    try {
      final dirty = <String>{};
      for (final entity in domain.entities) {
        if (await local(() => isFinancialCacheDirty(binding.database!, entity))) {
          dirty.add(entity);
        }
      }
      if (!current) return ReconcileDomainResult.cancelled;
      if (dirty.isEmpty) return ReconcileDomainResult.noDirtyState;
      if (!domain.isEnabled()) return ReconcileDomainResult.deferred;
      final completed = await domain.runFromEpoch(dirtyEntities: dirty,
          isAdmitted: () => current);
      if (!current) return ReconcileDomainResult.cancelled;
      var allCleared = true;
      for (final entity in dirty) {
        if (completed.contains(entity)) {
          final cleared = await local(() => clearFinancialCacheDirtyIfAdmitted(
              binding.database!, entity, () => current));
          if (!cleared) allCleared = false;
        } else {
          allCleared = false;
        }
      }
      if (!current) return ReconcileDomainResult.cancelled;
      return allCleared ? ReconcileDomainResult.completed : ReconcileDomainResult.failed;
    } on LedgerDeliveryStopped {
      return ReconcileDomainResult.cancelled;
    } on StaleAdmissionException {
      return ReconcileDomainResult.cancelled;
    }
  }
}
