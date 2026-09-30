import 'package:flutter/foundation.dart';

import '../../../core/sync/sync_health.dart';
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
  Future<T> _phase<T>(SyncDirection direction, Future<T> Function() body) async {
    final health = _health;
    if (health == null) return body();
    return (await health.runPhase(SyncDomain.ledger, direction, body,
        rethrowErrors: true)) as T;
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
    try {
      await _phase(SyncDirection.push, () => _push.push());
    } catch (e) {
      if (kDebugMode) debugPrint('[LedgerEngine] push error: $e');
    }
    return reconcileOrPull(
      reconciler: reconciler,
      domain: ReconcileDomain(
        name: kReconcileDomainLedger,
        entities: const {transactionsCacheEntityType},
        isEnabled: () => true,
        runFromEpoch: ({required dirtyEntities, required isAdmitted}) async {
          final r = await _phase(
              SyncDirection.pull,
              () => _pull.pull(
                  from: const SyncCursor.epoch(), isAdmitted: isAdmitted));
          return r.status == SyncPullStatus.completed
              ? const {transactionsCacheEntityType}
              : const <String>{};
        },
      ),
      normalPull: (admitted) async {
        try {
          await _phase(
              SyncDirection.pull, () => _pull.pull(isAdmitted: admitted));
        } catch (e) {
          if (kDebugMode) debugPrint('[LedgerEngine] pull error: $e');
        }
      },
    );
  }
}
