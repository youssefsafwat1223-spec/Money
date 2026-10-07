import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;
import 'package:url_launcher/url_launcher.dart';

import '../../core/backend/supabase_config.dart';
import '../../core/di/app_providers.dart';
import '../../core/router/app_router.dart';
import '../../core/session/app_session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/utils/l10n_ext.dart';
import '../coupons/coupons_providers.dart';
import '../../core/theme/app_typography.dart';
import '../../domain/entities/supporting_entities.dart';
import '../../core/config/legal_urls.dart';
import '../../core/privacy/consent_authority.dart';
import '../../core/privacy/diagnostics_consent_gate.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../capture/services/capture_device_registration_service.dart';
import '../consent/smart_analysis_consent_sheet.dart';
import '../onboarding/widgets/neon_illustration.dart';
import 'settings_providers.dart';
import '../../core/theme/widgets/app_toast.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/theme/widgets/directional_chevron.dart';
import '../common/repo_error_messages.dart';

class PrivacyScreen extends ConsumerWidget {
  const PrivacyScreen({super.key});

  // C-5: configured in one place — see core/config/legal_urls.dart.
  static final Uri _privacyPolicyUrl = kPrivacyPolicyUrl;
  static final Uri _termsUrl = kTermsUrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: c.bg,
      body: Column(
        children: [
          const _PrivacyHeader(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(AppSpacing.gutter),
              children: [
                const SizedBox(height: AppSpacing.s4),
                const Center(
                  child: NeonIllustration(
                    icon: AppLucideIcons.shield,
                    size: 140,
                  ),
                ),
                const SizedBox(height: AppSpacing.s6),
                _PrivacyCard(
                  icon: AppLucideIcons.fileText,
                  title: context.l10n.privPolicy,
                  onTap: () => _openExternalLink(context, _privacyPolicyUrl),
                ),
                _PrivacyCard(
                  icon: AppLucideIcons.gavel,
                  title: context.l10n.privTerms,
                  onTap: () => _openExternalLink(context, _termsUrl),
                ),
                _PrivacyCard(
                  icon: AppLucideIcons.arrowUpDown,
                  title: context.l10n.privTransferMyData,
                  onTap: () => context.push('/data-transfer'),
                ),
                const SizedBox(height: AppSpacing.s5),
                Text(context.l10n.privDataProcessing,
                    style: AppTypography.subhead(c.textMain)),
                const SizedBox(height: AppSpacing.s2),
                ref.watch(userSettingsProvider).maybeWhen(
                      data: (settings) => Column(
                        children: [
                          _ConsentSwitchCard(
                            icon: AppLucideIcons.cloud,
                            title: context.l10n.privCloudProcessing,
                            subtitle:
                                context.l10n.privCloudProcessingBody,
                            value: settings.cloudProcessingEnabled,
                            onChanged: (value) => _setConsent(
                              ref,
                              // MALI-059n: an interaction is an EXPLICIT choice —
                              // record accepted/declined (never left unset).
                              settings.copyWith(
                                cloudConsentState: value
                                    ? ConsentState.accepted
                                    : ConsentState.declined,
                              ),
                            ),
                          ),
                          _ConsentSwitchCard(
                            icon: AppLucideIcons.sparkles,
                            title: context.l10n.privAiAnalysis,
                            subtitle:
                                // This copy is deliberately truthful for both server regimes:
                                // pre-WP4 (AI analyses every consented message) and WP4-Lite
                                // (AI only when deterministic rules cannot resolve the message).
                                // "may be analysed" covers both, so it needs no revisit when
                                // process-ios-sms WP4-Lite is deployed.
                                context.l10n.privAiAnalysisBody,
                            value: settings.aiConsentGranted,
                            onChanged: (value) => _setConsent(
                              ref,
                              settings.copyWith(
                                aiConsentState: value
                                    ? ConsentState.accepted
                                    : ConsentState.declined,
                              ),
                            ),
                          ),
                          if (settings.cloudProcessingEnabled &&
                              ref
                                      .watch(captureRegistrationStatusProvider)
                                      .phase !=
                                  CaptureRegistrationPhase.notRequested)
                            const Padding(
                              padding: EdgeInsets.only(bottom: AppSpacing.s3),
                              child: SmartAnalysisRegistrationStatus(),
                            ),
                          // COUPONS Phase 1 — merchant personalization.
                          //
                          // Sits here, next to the cloud and AI consents,
                          // because it is the same KIND of decision even though
                          // it involves no server: it is the user choosing
                          // whether their spending shapes what they are shown.
                          // Burying it in the Offers screen would make it look
                          // like a display preference rather than a data one.
                          //
                          // Only shown when the capability flag is on — asking
                          // about a feature that cannot run would be noise.
                          // Unlike the two above it never leaves the device, so
                          // the copy says so plainly rather than describing an
                          // upload that does not happen.
                          if (ref.watch(merchantOffersEnabledProvider))
                            _ConsentSwitchCard(
                              icon: AppLucideIcons.store,
                              title: l10n.couponsPersonalizationTitle,
                              subtitle: l10n.couponsPersonalizationBody,
                              value: settings.merchantPersonalizationEnabled,
                              onChanged: (value) => _setConsent(
                                ref,
                                settings.copyWith(
                                    merchantPersonalizationEnabled: value),
                              ),
                            ),
                        ],
                      ),
                      orElse: () => const SizedBox.shrink(),
                    ),
                const SizedBox(height: AppSpacing.s5),
                Text(context.l10n.privDangerZone, style: AppTypography.subhead(c.danger)),
                const SizedBox(height: AppSpacing.s2),
                ref.watch(accountDeletionStatusProvider).maybeWhen(
                      data: (status) => status.isPending
                          ? _PendingDeletionCard(
                              scheduledAt: status.scheduledAt!,
                              onCancel: () =>
                                  _confirmCancelDeletion(context, ref),
                            )
                          : const SizedBox.shrink(),
                      orElse: () => const SizedBox.shrink(),
                    ),
                const SizedBox(height: AppSpacing.s2),
                _PrivacyCard(
                  icon: AppLucideIcons.trash2,
                  title: context.l10n.privDeleteAccountAll,
                  onTap: () => _confirmDelete(context, ref),
                  danger: true,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Persists a consent change and pushes the new state to the native capture
  /// layer immediately (the iOS extension reads it from the App Group), so
  /// revoking cloud processing takes effect without waiting for a restart.
  Future<void> _setConsent(
    WidgetRef ref,
    UserSettingsEntity updated,
  ) async {
    final registration = ref.read(captureDeviceRegistrationServiceProvider);
    Future<void> commit() async {
      await ref.read(userSettingsRepositoryProvider).saveSettings(updated);
      ref.invalidate(userSettingsProvider);
      // OD-05 (C-3) — apply the diagnostics gate IMMEDIATELY, in the same turn as
      // the toggle. Sentry's beforeSend is synchronous and cannot await a settings
      // read, so the gate is pushed rather than pulled: a revocation must take
      // effect before the next crash, not at the next startup.
      DiagnosticsConsentGate.set(
        ConsentAuthority.decide(EgressClass.diagnostics, updated),
      );
    }

    final before = await ref.read(userSettingsRepositoryProvider).getSettings();
    if (registration.isDisablingCloud(before, updated)) {
      // E1: Cloud ON->OFF is a transition, not a plain save: freeze egress, one
      // best-effort revoke, then commit OFF whatever the revoke did.
      DiagnosticsConsentGate.set(false);
      try {
        await registration.disableCloud(commitLocalOff: commit);
      } catch (_) {
        // FAIL CLOSED: the local OFF write failed. Egress stays frozen for this
        // process and the next launch completes OFF; nothing to retry here.
        return;
      }
    } else if (registration.isEnablingCloud(before, updated)) {
      // Astra G: OFF/unset -> ON is an explicit enable (new transition
      // generation and version) and the only way out of the persistent OFF gate.
      try {
        await registration.enableCloud(commitLocalOn: commit);
      } catch (_) {
        return; // not enabled: egress stays denied
      }
    } else {
      await commit();
    }
    try {
      await registration.syncBackendState();
    } catch (_) {
      // Best-effort: the startup sync re-applies the stored value anyway.
    }
  }

  Future<void> _openExternalLink(BuildContext context, Uri url) async {
    final opened = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.privLinkFailed)),
      );
    }
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.l10n.privDeleteAccountTitle),
        content: Text(context.l10n.privDeleteAccountBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(context.l10n.commonCancel)),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(context.l10n.privDeleteAccount)),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await ref.read(accountDeletionServiceProvider).requestDeletion();
    } catch (error) {
      if (context.mounted) {
        final message = error is RepoException
            ? repoErrorMessage(context, error)
            : context.l10n.privScheduleFailed;
        AppToast.show(context, message);
      }
      return;
    }

    // The reset replaces the account scope, which disposes this screen, so the
    // navigation uses the app router rather than this screen's context.
    await AppSession.instance.resetAllLocalData(
      signOutRemote: SupabaseConfig.isConfigured
          ? supabase.Supabase.instance.client.auth.signOut
          : null,
    );
    appRouter.go('/welcome');
  }

  Future<void> _confirmCancelDeletion(
      BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.l10n.privCancelDeleteTitle),
        content: Text(context.l10n.privCancelDeleteBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(context.l10n.privKeepAccount)),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(context.l10n.privCancelDeletion)),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(accountDeletionServiceProvider).cancelDeletion();
      ref.invalidate(accountDeletionStatusProvider);
    } catch (error) {
      if (!context.mounted) return;
      final message = error is RepoException
          ? repoErrorMessage(context, error)
          : context.l10n.privCancelFailed;
      AppToast.show(context, message);
    }
  }
}

class _PendingDeletionCard extends StatelessWidget {
  const _PendingDeletionCard({
    required this.scheduledAt,
    required this.onCancel,
  });

  final DateTime scheduledAt;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final local = scheduledAt.toLocal();
    final label =
        '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s3),
      margin: const EdgeInsets.only(bottom: AppSpacing.s3),
      decoration: BoxDecoration(
        color: c.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.danger.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.l10n.privScheduledForDeletion(label),
              style: AppTypography.bodyStrong(c.danger)),
          const SizedBox(height: AppSpacing.s2),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              onPressed: onCancel,
              child: Text(context.l10n.privCancelDeletion),
            ),
          ),
        ],
      ),
    );
  }
}

class _PrivacyHeader extends StatelessWidget {
  const _PrivacyHeader();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        64,
        AppSpacing.gutter,
        AppSpacing.s5,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            c.cta.withValues(alpha: 0.12),
            c.bg,
          ],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (Navigator.of(context).canPop()) ...[
                BackButton(color: c.textMain),
                const SizedBox(width: AppSpacing.s2),
              ],
              Expanded(
                child: Text(
                  context.l10n.privTitle,
                  style: AppTypography.title1(c.textMain)
                      .copyWith(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            context.l10n.privIntro,
            style: AppTypography.caption(c.textMuted),
          ),
        ],
      ),
    );
  }
}

/// Revocable data-processing consent switch (MALI-001) — same card language
/// as [_PrivacyCard], with an honest subtitle describing what leaves the
/// device and what stops when the switch is off.
class _ConsentSwitchCard extends StatelessWidget {
  const _ConsentSwitchCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: c.surface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        child: SwitchListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          secondary: Icon(icon, color: c.primary),
          title: Text(title, style: AppTypography.bodyStrong(c.textMain)),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(subtitle, style: AppTypography.caption(c.textLight)),
          ),
          value: value,
          activeThumbColor: c.onCta,
          activeTrackColor: c.cta,
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _PrivacyCard extends StatelessWidget {
  const _PrivacyCard({
    required this.icon,
    required this.title,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = danger ? c.danger : c.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: danger ? c.danger.withValues(alpha: 0.05) : c.surface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color:
                danger ? c.danger.withValues(alpha: 0.3) : Colors.transparent,
          ),
        ),
        child: ListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          leading: Icon(icon, color: color),
          title: Text(
            title,
            style: AppTypography.bodyStrong(danger ? c.danger : c.textMain),
          ),
          trailing: DirectionalChevron(color: c.textMuted),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          onTap: onTap,
        ),
      ),
    );
  }
}
