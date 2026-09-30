import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../core/session/app_session.dart';
import '../../../core/sync/sync_wakeup.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/planning_cutover.dart';
import '../../../data/db/planning_canonical_invariants.dart';
import '../../capture/services/ledger_outbox_queue.dart';
import 'planning_outbox_queue.dart';

/// Builds the standard [LedgerOutboxQueue] / [PlanningOutboxQueue] for writers
/// that run without Riverpod — the background capture isolate
/// (`CapturedMessageProcessor`, which opens its own [AppDatabase]) and
/// `BootstrapRunner`. The queues are auth-gated internally: a guest (no
/// Supabase session) enqueues nothing and stays local-only, which is why these
/// are safe to hand to every write path.
///
/// Sync is a signed-in capability, so enablement is always `true` here; the
/// auth gate below is the real guard. Every real planning entity type is
/// enabled, so `(_) => true` matches the set-based check used in
/// `app_providers.dart`.
///
/// A-2 (G14): money payload format follows the cutover authority. A writer that
/// runs money-bearing enqueues (the background capture isolate, bootstrap
/// auto-saves/repair) MUST pass the same [coordinator] state the foreground uses
/// (see [resolveCutoverCoordinator]); omitting it yields the legacy JSON-number
/// shape, which is only correct for non-money entities.
LedgerOutboxQueue buildLedgerOutboxQueue(
  AppDatabase db, {
  PlanningCutoverCoordinator? coordinator,
}) {
  return LedgerOutboxQueue(
    db: db,
    isPushEnabled: () => true,
    getAuthUserId: currentSupabaseUserId,
    getOwnerUid: localDataOwnerUid,
    onQueued: SyncWakeup.notify,
    coordinator: coordinator ?? const SchemaV29PlanningCutoverCoordinator(),
  );
}

PlanningOutboxQueue buildPlanningOutboxQueue(
  AppDatabase db, {
  PlanningCutoverCoordinator? coordinator,
}) {
  return PlanningOutboxQueue(
    db: db,
    isSyncEnabled: (_) => true,
    getAuthUserId: currentSupabaseUserId,
    getOwnerUid: localDataOwnerUid,
    onQueued: SyncWakeup.notify,
    coordinator: coordinator ?? const SchemaV29PlanningCutoverCoordinator(),
  );
}

/// The cutover authority for a writer that has no Riverpod container (the
/// background capture isolate). Computes the REAL state from the same durable
/// marker + canonical-invariant postflight the foreground coordinator is seeded
/// from, so both isolates serialize money identically. Fails toward
/// `unresolved` (never canonical, never silently legacy-by-default) if the state
/// cannot be established.
Future<PlanningCutoverCoordinator> resolveCutoverCoordinator(
  AppDatabase db,
) async {
  try {
    return FixedPlanningCutoverCoordinator(
      await computePlanningCutoverState(
        () async => (await db.customSelect('PRAGMA user_version;').getSingle())
            .read<int>('user_version'),
        () async => (await db
                .customSelect(
                    'SELECT planning_cutover_state AS s FROM user_settings;')
                .getSingle())
            .read<int>('s'),
        () async => (await planningCanonicalViolations(db)).length,
      ),
    );
  } catch (_) {
    return const FixedPlanningCutoverCoordinator(
        PlanningCutoverState.unresolved);
  }
}

/// The LOCAL DATA OWNER uid (AppSession's owner marker), or null.
Future<String?> localDataOwnerUid() async {
  try {
    return await AppSession.instance.readLocalDataOwnerUid();
  } catch (_) {
    return null;
  }
}

/// Current Supabase auth user id, or `null` when unconfigured/signed-out.
/// Never throws — a background isolate may not have the client initialized.
Future<String?> currentSupabaseUserId() async {
  if (!SupabaseConfig.isConfigured) return null;
  try {
    return Supabase.instance.client.auth.currentUser?.id;
  } catch (_) {
    return null;
  }
}
