import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../../core/backend/supabase_config.dart';
import '../../core/di/app_providers.dart';
import '../../core/di/rebootstrap_providers.dart' show RebootstrapRuntime;
import '../../core/session/app_session.dart';
import '../../core/sync/sync_health.dart';
import '../../core/sync/sync_pull_proof.dart';
import '../../core/sync/sync_status.dart';
import '../../data/sync/server_capabilities.dart';
import 'settings_providers.dart';

/// A-5: who sync would run as, following [AppSession].
final syncIdentityProvider = Provider.autoDispose<SyncIdentity>((ref) {
  final session = AppSession.instance;
  void changed() => ref.invalidateSelf();
  session.addListener(changed);
  ref.onDispose(() => session.removeListener(changed));
  if (session.isGuest) return SyncIdentity.guest;
  return session.status == SessionStatus.authenticated
      ? SyncIdentity.authenticated
      : SyncIdentity.signedOut;
});

/// A-5: whether an orchestrated sync run is in progress.
final syncRunningProvider = Provider.autoDispose<bool>((ref) {
  final state = SyncRunState.instance;
  void changed() => ref.invalidateSelf();
  state.addListener(changed);
  ref.onDispose(() => state.removeListener(changed));
  return state.running;
});

/// The signed-in cloud uid, or null (no session / backend not configured).
String? currentAuthUid() {
  try {
    if (!SupabaseConfig.isConfigured) return null;
    return supabase.Supabase.instance.client.auth.currentUser?.id;
  } catch (_) {
    return null;
  }
}

/// WP-8: the pull-side head proof for [uid] from what is already known locally
/// (the gate's last plan, the cursors, the cached capability, the rebootstrap
/// marker). No network.
Future<SyncPullProof> _pullProof(Ref ref, String? uid) async {
  if (uid == null) return SyncPullProof.notApplicable;
  var pending = false;
  try {
    pending =
        await RebootstrapRuntime.instance.store?.rebootstrapMarker(uid) != null;
  } catch (_) {}
  return deriveSyncPullProof(
    db: ref.read(appDatabaseProvider),
    uid: uid,
    syncSeq: ref
        .read(serverCapabilitiesServiceProvider)
        .cachedCapability(kCapSyncSeq, uid),
    observation: ref.read(syncHealthProvider).pullObservation,
    rebootstrapPending: pending,
  );
}

/// A-5: the derived [SyncStatus]. Recomputed on every local DB tick (outbox
/// writes, ACKs) and on run start/stop — never polled.
final syncStatusProvider = FutureProvider.autoDispose<SyncStatus>((ref) async {
  ref.watch(dbRevisionProvider);
  final running = ref.watch(syncRunningProvider);
  final identity = ref.watch(syncIdentityProvider);
  final settings = await ref.watch(userSettingsProvider.future);
  final counts = await SyncHealth.queueCounts(ref.watch(appDatabaseProvider));
  return SyncStatus.derive(
    counts: counts,
    health: ref.watch(syncHealthProvider).all,
    cloudConsent: settings.cloudProcessingEnabled,
    identity: identity,
    syncRunning: running,
    pull: await _pullProof(ref, currentAuthUid()),
  );
});
