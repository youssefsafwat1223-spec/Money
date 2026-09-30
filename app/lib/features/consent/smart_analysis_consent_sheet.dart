import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/di/app_providers.dart';
import '../../core/privacy/consent_authority.dart';
import '../../core/privacy/diagnostics_consent_gate.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/app_toast.dart';
import '../../core/utils/l10n_ext.dart';
import '../../domain/entities/supporting_entities.dart';
import '../capture/services/capture_device_registration_service.dart';
import '../settings/settings_providers.dart';

/// Explicit opt-in for Smart Analysis AND Cloud Sync. The existing consent
/// model couples the two, so the disclosure names both. Nothing is
/// pre-selected: only the primary button grants; "Not now", dismissing or going
/// back change nothing. Returns true only if consent was granted.
Future<bool> showSmartAnalysisConsentSheet(
  BuildContext context,
  WidgetRef ref,
) async {
  final granted = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter, AppSpacing.s2, AppSpacing.gutter, AppSpacing.s6),
        child: SmartAnalysisConsentPanel(
          onDone: (granted) => Navigator.of(sheetContext).pop(granted),
        ),
      ),
    ),
  );
  return granted ?? false;
}

/// Disclosure + actions, shared by the sheet and the onboarding step.
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
  bool _granted = false;

  Future<void> _grant() async {
    if (_granting) return;
    setState(() => _granting = true);
    try {
      // Same sequence as PrivacyScreen._setConsent.
      final current = await ref.read(userSettingsRepositoryProvider).getSettings();
      final updated = current.copyWith(
        cloudConsentState: ConsentState.accepted,
        aiConsentState: ConsentState.accepted,
      );
      await ref.read(userSettingsRepositoryProvider).saveSettings(updated);
      ref.invalidate(userSettingsProvider);
      DiagnosticsConsentGate.set(
        ConsentAuthority.decide(EgressClass.diagnostics, updated),
      );
      if (mounted) setState(() => _granted = true);
      await ref.read(captureDeviceRegistrationServiceProvider).retry();
    } catch (_) {
      // Saving failed: nothing was granted; the user can tap Enable again.
      if (mounted) AppToast.showError(context, context.l10n.setupSaveFailed);
    } finally {
      if (mounted) setState(() => _granting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = context.colors;
    final fg = widget.onDark ? Colors.white : c.textPrimary;
    final muted =
        widget.onDark ? Colors.white.withValues(alpha: 0.72) : c.textSecondary;
    final bullets = [
      l10n.smartConsentBullet1,
      l10n.smartConsentBullet2,
      l10n.smartConsentBullet3,
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.smartConsentTitle,
          style: AppTypography.sectionTitle(fg),
        ),
        const SizedBox(height: AppSpacing.s3),
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
        const SizedBox(height: AppSpacing.s3),
        if (_granted)
          SmartAnalysisRegistrationStatus(onDark: widget.onDark)
        else
          SizedBox(
            height: AppSpacing.buttonHeight,
            child: FilledButton(
              onPressed: _granting ? null : _grant,
              style: widget.onDark
                  ? FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: AppBrandBlue.brand,
                    )
                  : null,
              child: Text(l10n.smartConsentEnable),
            ),
          ),
        const SizedBox(height: AppSpacing.s2),
        if (_granted)
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
