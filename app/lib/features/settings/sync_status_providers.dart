import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/session/app_session.dart';
import '../../core/sync/sync_health.dart';
import '../../core/sync/sync_status.dart';
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
  );
});
