import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../../core/backend/supabase_config.dart';
import '../../core/di/app_providers.dart';
import '../../core/session/app_session.dart';
import '../../core/sync/sync_health.dart';
import '../../core/sync/sync_wakeup.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../data/sync/exact_transport_capability.dart';
import 'settings_providers.dart';

/// A-5: the QA sync diagnostics surface exists ONLY in debug builds, reached
/// through the existing debug-only "Developer" group in Settings. The router
/// registers the route behind this guard, so a release build has no route, no
/// entry point and no way to deep-link to it. [debugMode] is injectable so the
/// release behaviour is testable.
bool syncDiagnosticsAvailable({bool debugMode = kDebugMode}) => debugMode;

/// First 4 + last 4 characters of an identifier; never the whole value.
String maskUid(String? uid) {
  if (uid == null || uid.isEmpty) return '—';
  if (uid.length <= 8) return '••••';
  return '${uid.substring(0, 4)}…${uid.substring(uid.length - 4)}';
}

/// Everything the diagnostics screen shows. Counts, states, timestamps and
/// masked identifiers only — no row content, no message text.
class SyncDiagnostics {
  const SyncDiagnostics({
    required this.health,
    required this.counts,
    required this.authUidMasked,
    required this.ownerUidMasked,
    required this.uidsMatch,
    required this.cloudConsent,
    required this.aiConsent,
    required this.capabilities,
  });

  final Map<SyncDomain, SyncDomainHealth> health;
  final SyncQueueCounts counts;
  final String authUidMasked;
  final String ownerUidMasked;
  final bool uidsMatch;
  final bool cloudConsent;
  final bool aiConsent;

  /// Capability label → state name.
  final Map<String, String> capabilities;
}

final syncDiagnosticsProvider =
    FutureProvider.autoDispose<SyncDiagnostics>((ref) async {
  ref.watch(dbRevisionProvider);
  String? authUid;
  try {
    if (SupabaseConfig.isConfigured) {
      authUid = supabase.Supabase.instance.client.auth.currentUser?.id;
    }
  } catch (_) {}
  final ownerUid = await AppSession.instance.readLocalDataOwnerUid();
  final settings = await ref.watch(userSettingsProvider.future);
  final counts = await SyncHealth.queueCounts(ref.watch(appDatabaseProvider));
  final fx = authUid == null
      ? 'unknown'
      : ref
          .read(serverCapabilitiesServiceProvider)
          .cachedAwaitingFx(authUid)
          .name;
  return SyncDiagnostics(
    health: ref.watch(syncHealthProvider).all,
    counts: counts,
    authUidMasked: maskUid(authUid),
    ownerUidMasked: maskUid(ownerUid),
    uidsMatch: authUid != null && authUid == ownerUid,
    cloudConsent: settings.cloudProcessingEnabled,
    aiConsent: settings.aiConsentGranted,
    capabilities: {
      'exact push transport': ref.read(exactPushTransportCapabilityProvider).name,
      'exact pull transport': ref.read(exactPullTransportCapabilityProvider).name,
      'planning currency':
          ref.read(planningServerCurrencyCapabilityProvider).name,
      'awaiting FX': fx,
    },
  );
});

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
            _group(c, 'Identity', {
              'auth uid': d.authUidMasked,
              'local data owner uid': d.ownerUidMasked,
              'match': d.uidsMatch ? 'yes' : 'no',
              'cloud consent': d.cloudConsent ? 'on' : 'off',
              'AI consent': d.aiConsent ? 'on' : 'off',
            }),
            _group(c, 'Capabilities', d.capabilities),
            _group(c, 'Queue', {
              'pending': '${d.counts.pending}',
              'parked': '${d.counts.parked}',
              'dead letter': '${d.counts.deadLetter}',
              'in flight': '${d.counts.inFlight}',
              'sender mappings pending': '${d.counts.senderMappingsPending}',
              'sender mappings failed': '${d.counts.senderMappingsFailed}',
              'smart inbox pending': '${d.counts.smartInboxPendingSync}',
              'next retry': _t(d.counts.nextRetryAt),
              'last local mutation': _t(d.counts.lastLocalMutationAt),
            }),
            _group(c, 'Parked by reason', {
              for (final e in d.counts.parkedByReason.entries)
                e.key: '${e.value}',
            }),
            _group(c, 'Dead letter by reason', {
              for (final e in d.counts.deadLetterByReason.entries)
                e.key: '${e.value}',
            }),
            for (final domain in SyncDomain.values)
              _group(c, 'Domain: ${domain.name}', {
                'last push': _t(d.health[domain]?.lastPushSuccessAt),
                'last pull': _t(d.health[domain]?.lastPullSuccessAt),
                'last error class':
                    d.health[domain]?.lastErrorClass?.name ?? '—',
                'last error at': _t(d.health[domain]?.lastErrorAt),
                'consecutive failures':
                    '${d.health[domain]?.consecutiveFailures ?? 0}',
              }),
          ],
        ),
      ),
    );
  }

  static String _t(DateTime? t) =>
      t == null ? '—' : t.toUtc().toIso8601String();

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
