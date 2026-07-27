import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../core/sync/sync_wakeup.dart';
import '../../../data/db/app_database.dart';
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
LedgerOutboxQueue buildLedgerOutboxQueue(AppDatabase db) {
  return LedgerOutboxQueue(
    db: db,
    isPushEnabled: () => true,
    getAuthUserId: currentSupabaseUserId,
    onQueued: SyncWakeup.notify,
  );
}

PlanningOutboxQueue buildPlanningOutboxQueue(AppDatabase db) {
  return PlanningOutboxQueue(
    db: db,
    isSyncEnabled: (_) => true,
    getAuthUserId: currentSupabaseUserId,
    onQueued: SyncWakeup.notify,
  );
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
