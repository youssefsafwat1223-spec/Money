import 'package:flutter/foundation.dart';

import '../../../core/sync/conflict_resolver.dart';
import '../../../core/sync/sync_health.dart';
import '../../../data/db/legacy_financial_cache_reconciler.dart';
import '../../app/legacy_reconcile_domains.dart';
import 'accounts_pull_service.dart';
import 'accounts_push_service.dart';
import 'planning_outbox_queue.dart';
import 'planning_pull_service.dart';
import 'planning_push_service.dart';
import 'planning_child_sync_service.dart';
import 'planning_startup_registration_service.dart';

/// Structured outcome of the planning parent phase, so the sync body drives
/// control flow from explicit results (not inferred generation checks): the
/// accounts and planning in-slot outcomes, and whether the phase was cancelled.
class SyncParentsOutcome {
  const SyncParentsOutcome({
    required this.accounts,
    required this.planning,
  });

  final ReconcileDomainResult accounts;
  final ReconcileDomainResult planning;

  bool get cancelled =>
      accounts == ReconcileDomainResult.cancelled ||
      planning == ReconcileDomainResult.cancelled;
}

class PlanningSyncEngine {
  const PlanningSyncEngine({
    required AccountsPushService accountsPushService,
    required AccountsPullService accountsPullService,
    required PlanningPushService planningPushService,
    required PlanningPullService planningPullService,
    required PlanningChildSyncService planningChildSyncService,
    required PlanningStartupRegistrationService startupRegistrationService,
    required UniversalConflictResolver conflictResolver,
    SyncHealth? health,
    Future<void> Function()? ensureCapabilities,
  })  : _health = health,
        _ensureCapabilities = ensureCapabilities,
        _accountsPush = accountsPushService,
        _accountsPull = accountsPullService,
        _planningPush = planningPushService,
        _planningPull = planningPullService,
        _planningChildren = planningChildSyncService,
        _startupRegistration = startupRegistrationService,
        _conflictResolver = conflictResolver;

  final AccountsPushService _accountsPush;
  final AccountsPullService _accountsPull;
  final PlanningPushService _planningPush;
  final PlanningPullService _planningPull;
  final PlanningChildSyncService _planningChildren;
  final PlanningStartupRegistrationService _startupRegistration;
  final UniversalConflictResolver _conflictResolver;
  final SyncHealth? _health;

  /// Resolves runtime capability probes (planning currency) at the start of a
  /// cycle so the gates below see a fresh answer. Never throws.
  final Future<void> Function()? _ensureCapabilities;

  /// Runs one phase: isolated (never rethrows) and recorded in [SyncHealth].
  Future<void> _phase(
    SyncDomain domain,
    SyncDirection direction,
    Future<void> Function() body,
    String label,
  ) async {
    final health = _health;
    try {
      if (health == null) {
        await body();
      } else {
        await health.runPhase(domain, direction, body, rethrowErrors: true);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[PlanningSync] $label error: $e');
    }
  }

  Future<void> sync({LegacyFinancialCacheReconciler? reconciler}) async {
    final parents = await syncParents(reconciler: reconciler);
    if (parents.cancelled) return;
    await syncChildren();
  }

  /// Accounts and planning parents must sync before ledger rows so foreign
  /// key/server-ID correlation is available on a fresh second device.
  ///
  /// [reconciler] enables the in-slot legacy epoch reconciliation at the accounts
  /// and planning pull slots. Requirement 1: a `cancelled` outcome aborts INSIDE
  /// this method at the exact slot — no later planning push/conflict/pull/
  /// registration runs under a stale generation.
  Future<SyncParentsOutcome> syncParents({
    LegacyFinancialCacheReconciler? reconciler,
  }) async {
    try {
      await _ensureCapabilities?.call();
    } catch (e) {
      if (kDebugMode) debugPrint('[PlanningSync] capability probe error: $e');
    }
    await _phase(SyncDomain.accounts, SyncDirection.push,
        () => _accountsPush.push(), 'accounts push');
    final accounts = await reconcileOrPull(
      reconciler: reconciler,
      domain: accountsReconcileDomain(_accountsPull),
      normalPull: (admitted) async {
        await _phase(SyncDomain.accounts, SyncDirection.pull,
            () => _accountsPull.pull(isAdmitted: admitted), 'accounts pull');
      },
    );
    if (accounts == ReconcileDomainResult.cancelled) {
      return const SyncParentsOutcome(
        accounts: ReconcileDomainResult.cancelled,
        planning: ReconcileDomainResult.noDirtyState,
      );
    }
    await _phase(SyncDomain.planning, SyncDirection.push,
        () => _planningPush.push(), 'planning push');
    // Auto-resolve low-stakes config conflicts (cards/categories/settings) in
    // favour of the server BEFORE the pull, so the pull overwrites the local
    // copy within this same pass — they never sit stuck in `conflict` awaiting a
    // prompt that never comes (MALI-057n). Financial entities are left for the
    // user to resolve.
    try {
      await _conflictResolver.autoResolveDeterministic();
    } catch (e) {
      if (kDebugMode) debugPrint('[PlanningSync] auto-resolve error: $e');
    }
    // Audit NEW-H-4 — the settings-registration authority. Registration may
    // only queue the initial FULL-ROW settings CREATE when the pull POSITIVELY
    // established remote state for the settings singleton in this cycle. The
    // pull swallows per-entity transport errors into its result, so "pull()
    // returned" proves nothing — only `completedEntities` does (an entity that
    // errored mid-page is absent). A failed/cancelled pull, or the legacy
    // reconcile path, leaves this false: UNKNOWN remote existence is NOT
    // absence, and pushing fresh-device defaults over an existing remote row
    // (which this same cycle would do — registration is followed immediately
    // by a push) destroyed the user's real cloud settings/profile.
    var settingsPullCompleted = false;
    final planning = await reconcileOrPull(
      reconciler: reconciler,
      domain: planningReconcileDomain(_planningPull),
      normalPull: (admitted) async {
        await _phase(SyncDomain.planning, SyncDirection.pull, () async {
          final result = await _planningPull.pull(isAdmitted: admitted);
          settingsPullCompleted = result.completedEntities
              .contains(PlanningOutboxQueue.settingsEntityType);
        }, 'planning pull');
      },
    );
    if (planning == ReconcileDomainResult.cancelled) {
      return SyncParentsOutcome(
          accounts: accounts, planning: ReconcileDomainResult.cancelled);
    }
    // Pull first so an existing remote singleton wins over freshly seeded
    // defaults. Only genuinely missing settings/custom categories are queued —
    // and the settings singleton only under the positive authority above.
    await _phase(SyncDomain.planning, SyncDirection.push, () async {
      await _startupRegistration.registerMissingRows(
          settingsPullCompleted: settingsPullCompleted);
      await _planningPush.push();
    }, 'registration');
    return SyncParentsOutcome(accounts: accounts, planning: planning);
  }

  /// Called after ledger sync so bill-payment transaction references and plan
  /// links can resolve both sides on their first pass.
  Future<void> syncChildren() async {
    await _phase(SyncDomain.children, SyncDirection.push,
        () => _planningChildren.sync(), 'children');
  }
}
