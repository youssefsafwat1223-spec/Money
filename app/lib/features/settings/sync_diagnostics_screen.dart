import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/session/app_session.dart';
import '../../core/di/rebootstrap_providers.dart' show RebootstrapRuntime;
import '../../core/sync/sync_diagnostics_report.dart';
import '../../core/sync/sync_health.dart';
import '../../core/sync/sync_wakeup.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../data/sync/exact_transport_capability.dart';
import '../capture/services/capture_import_ports.dart'
    show NativeCaptureImportQueue;
import '../capture/services/native_capture_bridge.dart'
    show NativeCaptureBridge;
import 'sync_status_providers.dart' show currentAuthUid;
import 'settings_providers.dart';

/// A-5: the QA sync diagnostics surface exists ONLY in debug builds, reached
/// through the existing debug-only "Developer" group in Settings. The router
/// registers the route behind this guard, so a release build has no route, no
/// entry point and no way to deep-link to it. [debugMode] is injectable so the
/// release behaviour is testable.
bool syncDiagnosticsAvailable({bool debugMode = kDebugMode}) => debugMode;

/// WP-8 / CAP-8: the diagnostics are collected into a content-free report (see
/// `sync_diagnostics_report.dart`) that the screen renders and "Copy" exports.
final syncDiagnosticsProvider =
    FutureProvider.autoDispose<SyncDiagnosticsReport>((ref) async {
  ref.watch(dbRevisionProvider);
  final authUid = currentAuthUid();
  final ownerUid = await AppSession.instance.readLocalDataOwnerUid();
  final settings = await ref.watch(userSettingsProvider.future);
  final caps = ref.read(serverCapabilitiesServiceProvider);
  final registration = ref.read(captureDeviceRegistrationServiceProvider);
  final fx = authUid == null ? 'unknown' : caps.cachedAwaitingFx(authUid).name;
  final store = RebootstrapRuntime.instance.store;
  const queue = NativeCaptureImportQueue();
  return collectSyncDiagnostics(SyncDiagnosticsSources(
    db: ref.watch(appDatabaseProvider),
    health: ref.watch(syncHealthProvider),
    settings: settings,
    authUid: authUid,
    ownerUid: ownerUid,
    cachedCapability: (k) => caps.cachedCapability(k, authUid!),
    otherCapabilities: {
      'exact push transport': ref.read(exactPushTransportCapabilityProvider).name,
      'exact pull transport': ref.read(exactPullTransportCapabilityProvider).name,
      'planning currency':
          ref.watch(planningServerCurrencyCapabilityProvider).name,
      for (final e in ref.watch(syncHealthProvider).capabilityStates.entries)
        if (e.key.startsWith('planning currency ('))
          e.key.replaceFirst('planning currency', 'planning currency probe'):
              e.value,
      'awaiting FX': fx,
    },
    replicaEntry: () async {
      if (store == null || authUid == null) return null;
      final hash = await store.uidHash(authUid);
      for (final e in await store.list()) {
        if (e.uidHash == hash) return e;
      }
      return null;
    },
    captureOwner: queue.getOwner,
    peekQueue: queue.peek,
    unboundHinted: (uid) async => (await queue.unboundSummary(uid)).count,
    removalBarrier: NativeCaptureBridge.getCaptureRemovalBarrier,
    consentAck: registration.consentAckSnapshot,
    mirroredConsentVersion: registration.mirroredConsentVersion,
    registration: registration.status.value,
    lastImport: ref.read(captureImportServiceProvider).lastReport,
    captureV3Enabled: _flag('capture_import_v3'),
  ));
});

bool _flag(String key) {
  try {
    return featureFlags.getBool(key);
  } catch (_) {
    return false;
  }
}

class SyncDiagnosticsScreen extends ConsumerWidget {
  const SyncDiagnosticsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final async = ref.watch(syncDiagnosticsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Sync diagnostics')),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Unavailable: ${e.runtimeType}')),
        data: (d) => ListView(
          padding: const EdgeInsets.all(AppSpacing.gutter),
          children: [
            const FilledButton(
              key: ValueKey('run-sync-now'),
              onPressed: SyncWakeup.notify,
              child: Text('Run sync now'),
            ),
            const SizedBox(height: AppSpacing.s3),
            OutlinedButton(
              key: const ValueKey('copy-diagnostics'),
              onPressed: () => Clipboard.setData(
                  ClipboardData(text: d.toRedactedText())),
              child: const Text('Copy diagnostics (redacted)'),
            ),
            const SizedBox(height: AppSpacing.s3),
            for (final section in d.sections)
              _group(c, section.title, section.rows),
          ],
        ),
      ),
    );
  }

  Widget _group(AppColors c, String title, Map<String, String> rows) {
    if (rows.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: AppTypography.footnote(c.textLight)),
          const SizedBox(height: AppSpacing.s1),
          for (final e in rows.entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                      flex: 5,
                      child: Text(e.key,
                          style: AppTypography.caption(c.textLight))),
                  Expanded(
                      flex: 6,
                      child: Text(e.value,
                          style: AppTypography.caption(c.textMain))),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
