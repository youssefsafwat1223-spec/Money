import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/di/app_providers.dart';
import '../../core/privacy/consent_authority.dart';
import '../../core/privacy/diagnostics_consent_gate.dart';
import '../../core/session/app_session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/app_toast.dart';
import '../../core/utils/l10n_ext.dart';
import '../../domain/entities/supporting_entities.dart';
import '../capture/services/capture_device_registration_service.dart';
import '../settings/settings_providers.dart';

/// Explicit, SEPARATE opt-ins for Cloud Sync and Smart Analysis (two controls,
/// two actions). Nothing is pre-selected: only an Enable button grants, and only
/// the one it belongs to; Smart Analysis is offered only once Cloud Sync is on
/// (AI needs cloud). "Not now", dismissing or going back change nothing.
/// Returns true only if something was granted. [onAnswered] fires only when the
/// user pressed one of the sheet's buttons (not on a swipe-dismiss).
Future<bool> showSmartAnalysisConsentSheet(
  BuildContext context,
  WidgetRef ref, {
  VoidCallback? onAnswered,
}) async {
  final granted = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter, AppSpacing.s2, AppSpacing.gutter, AppSpacing.s6),
        child: SmartAnalysisConsentPanel(
          onDone: (granted) {
            onAnswered?.call();
            Navigator.of(sheetContext).pop(granted);
          },
        ),
      ),
    ),
  );
  return granted ?? false;
}

/// §4.6 "a new device re-asks": an onboarded account admitted into a replica whose
/// cloud AND AI consent are both still unset (a new device, or after Remove data)
/// is asked once, through the same sheet, before anything can egress. Unset means
/// denied until answered, so nothing is sent while the question is open. A button
/// press (grant or "Not now") records that it was asked; a swipe-dismiss does not,
/// so the question comes back next launch. [seen]/[markSeen] default to the
/// per-uid marker kept by [AppSession].
Future<void> maybeReaskConsent(
  BuildContext context,
  WidgetRef ref, {
  Future<bool> Function()? seen,
  Future<void> Function()? markSeen,
}) async {
  final settings = await ref.read(userSettingsRepositoryProvider).getSettings();
  if (settings.cloudConsentState != ConsentState.unset ||
      settings.aiConsentState != ConsentState.unset) {
    return;
  }
  if (await (seen ?? AppSession.instance.consentPromptSeen)()) return;
  if (!context.mounted) return;
  await showSmartAnalysisConsentSheet(
    context,
    ref,
    onAnswered: () =>
        unawaited((markSeen ?? AppSession.instance.markConsentPromptSeen)()),
  );
}

/// Persists an explicit consent grant (same sequence as
/// PrivacyScreen._setConsent). Only the flags passed as true are changed; it
/// never writes `declined`. Throws if the save fails (nothing granted).
Future<UserSettingsEntity> saveConsentChoice(
  WidgetRef ref, {
  bool cloud = false,
  bool ai = false,
}) async {
  final current = await ref.read(userSettingsRepositoryProvider).getSettings();
  final updated = current.copyWith(
    cloudConsentState: cloud ? ConsentState.accepted : null,
    aiConsentState: ai ? ConsentState.accepted : null,
  );
  await ref.read(userSettingsRepositoryProvider).saveSettings(updated);
  ref.invalidate(userSettingsProvider);
  DiagnosticsConsentGate.set(
    ConsentAuthority.decide(EgressClass.diagnostics, updated),
  );
  return updated;
}

/// Disclosure + actions of the sheet.
/// [onDone] fires with true after a grant (once the user continues past the
/// live status) or false for "Not now".
class SmartAnalysisConsentPanel extends ConsumerStatefulWidget {
  const SmartAnalysisConsentPanel({
    super.key,
    required this.onDone,
    this.onDark = false,
    this.privacyRoute = '/privacy',
  });

  final ValueChanged<bool> onDone;
  final bool onDark;
  final String privacyRoute;

  @override
  ConsumerState<SmartAnalysisConsentPanel> createState() =>
      _SmartAnalysisConsentPanelState();
}

class _SmartAnalysisConsentPanelState
    extends ConsumerState<SmartAnalysisConsentPanel> {
  bool _granting = false;
  bool _grantedAny = false;

  Future<void> _grant({required bool cloud, required bool ai}) async {
    if (_granting) return;
    setState(() => _granting = true);
    try {
      await saveConsentChoice(ref, cloud: cloud, ai: ai);
    } catch (_) {
      // Saving failed: nothing was granted; the user can tap Enable again.
      if (mounted) AppToast.showError(context, context.l10n.setupSaveFailed);
      if (mounted) setState(() => _granting = false);
      return;
    }
    // Consent IS saved from here on. A registration failure is reported by the
    // live status below (connected / failed + Retry), never as a save failure.
    if (mounted) setState(() => _grantedAny = true);
    try {
      final service = ref.read(captureDeviceRegistrationServiceProvider);
      if (ai) {
        await service.retry();
      } else {
        await service.syncBackendState();
      }
    } catch (_) {}
    if (mounted) setState(() => _granting = false);
  }

  Widget _section({
    required String title,
    required List<String> bullets,
    required bool on,
    required Color fg,
    required Color muted,
    String? lead,
    String? enableLabel,
    VoidCallback? onEnable,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          Expanded(child: Text(title, style: AppTypography.bodyStrong(fg))),
          if (on)
            Icon(Icons.check_circle, size: 18, color: context.colors.success),
        ]),
        const SizedBox(height: AppSpacing.s2),
        if (lead != null) ...[
          Text(lead, style: AppTypography.body(muted)),
          const SizedBox(height: AppSpacing.s2),
        ],
        for (final bullet in bullets)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.s2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('•  ', style: AppTypography.body(muted)),
                Expanded(child: Text(bullet, style: AppTypography.body(muted))),
              ],
            ),
          ),
        if (!on && enableLabel != null)
          SizedBox(
            height: AppSpacing.buttonHeight,
            child: FilledButton(
              onPressed: _granting ? null : onEnable,
              style: widget.onDark
                  ? FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: AppBrandBlue.brand,
                    )
                  : null,
              child: Text(enableLabel),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = context.colors;
    final fg = widget.onDark ? Colors.white : c.textPrimary;
    final muted =
        widget.onDark ? Colors.white.withValues(alpha: 0.72) : c.textSecondary;
    final settings = ref.watch(userSettingsProvider).valueOrNull;
    final cloudOn = settings?.cloudProcessingEnabled ?? false;
    final aiOn = settings?.aiConsentGranted ?? false;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.smartConsentTitle,
          style: AppTypography.sectionTitle(fg),
        ),
        const SizedBox(height: AppSpacing.s3),
        _section(
          title: l10n.onbCloudTitle,
          bullets: [
            l10n.onbCloudBullet1,
            l10n.onbCloudBullet2,
            l10n.onbCloudBullet3,
          ],
          on: cloudOn,
          fg: fg,
          muted: muted,
          enableLabel: l10n.onbCloudEnable,
          onEnable: () => _grant(cloud: true, ai: false),
        ),
        const SizedBox(height: AppSpacing.s4),
        _section(
          title: l10n.onbAiTitle,
          bullets: [l10n.onbAiBullet1, l10n.onbAiBullet2],
          on: aiOn,
          fg: fg,
          muted: muted,
          lead: cloudOn ? null : l10n.smartConsentAiNeedsCloud,
          // AI is never granted without cloud: no button until cloud is on.
          enableLabel: cloudOn ? l10n.onbAiEnable : null,
          onEnable: () => _grant(cloud: false, ai: true),
        ),
        const SizedBox(height: AppSpacing.s3),
        if (_grantedAny && cloudOn)
          SmartAnalysisRegistrationStatus(onDark: widget.onDark),
        const SizedBox(height: AppSpacing.s2),
        if (_grantedAny)
          SizedBox(
            height: AppSpacing.buttonHeight,
            child: FilledButton(
              onPressed: _granting ? null : () => widget.onDone(true),
              style: widget.onDark
                  ? FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: AppBrandBlue.brand,
                    )
                  : null,
              child: Text(l10n.setupCloudCta),
            ),
          )
        else
          TextButton(
            onPressed: _granting ? null : () => widget.onDone(false),
            style: TextButton.styleFrom(foregroundColor: fg),
            child: Text(l10n.smartConsentNotNow),
          ),
        TextButton(
          onPressed: () => context.push(widget.privacyRoute),
          style: TextButton.styleFrom(foregroundColor: muted),
          child: Text(l10n.smartConsentPrivacyLink),
        ),
      ],
    );
  }
}

/// Live registration status: connecting spinner / connected / failed + Retry.
class SmartAnalysisRegistrationStatus extends ConsumerWidget {
  const SmartAnalysisRegistrationStatus({super.key, this.onDark = false});

  final bool onDark;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final c = context.colors;
    final status = ref.watch(captureRegistrationStatusProvider);
    final fg = onDark ? Colors.white : c.textPrimary;
    switch (status.phase) {
      case CaptureRegistrationPhase.connected:
        return Row(children: [
          Icon(Icons.check_circle, size: 18, color: c.success),
          const SizedBox(width: AppSpacing.s2),
          Expanded(
            child: Text(l10n.smartConsentStatusConnected,
                style: AppTypography.body(fg)),
          ),
        ]);
      case CaptureRegistrationPhase.failed:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.smartConsentStatusFailed, style: AppTypography.body(fg)),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: () =>
                    ref.read(captureDeviceRegistrationServiceProvider).retry(),
                style: TextButton.styleFrom(foregroundColor: fg),
                child: Text(l10n.smartConsentRetry),
              ),
            ),
          ],
        );
      case CaptureRegistrationPhase.notRequested:
        return const SizedBox.shrink();
      case CaptureRegistrationPhase.connecting:
        return Row(children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: fg),
          ),
          const SizedBox(width: AppSpacing.s2),
          Text(l10n.smartConsentStatusConnecting,
              style: AppTypography.body(fg)),
        ]);
    }
  }
}
