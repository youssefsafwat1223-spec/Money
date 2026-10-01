import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/app_toast.dart';
import '../../core/utils/l10n_ext.dart';
import '../consent/smart_analysis_consent_sheet.dart';
import '../settings/settings_providers.dart';

enum OnboardingConsentKind { cloud, smartAnalysis }

/// One explicit consent decision on the navy onboarding surface. Nothing is
/// pre-selected: only the primary button grants; "Not now" writes NOTHING.
/// [onDone] fires with true after a grant and false for "Not now".
class OnboardingConsentStep extends ConsumerStatefulWidget {
  const OnboardingConsentStep({
    super.key,
    required this.kind,
    required this.onDone,
    this.privacyRoute = '/onboarding/privacy',
  });

  final OnboardingConsentKind kind;
  final ValueChanged<bool> onDone;
  final String privacyRoute;

  @override
  ConsumerState<OnboardingConsentStep> createState() =>
      _OnboardingConsentStepState();
}

class _OnboardingConsentStepState extends ConsumerState<OnboardingConsentStep> {
  bool _saving = false;

  Future<void> _grant({required bool cloud, required bool ai}) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await saveConsentChoice(ref, cloud: cloud, ai: ai);
    } catch (_) {
      if (mounted) {
        AppToast.showError(context, context.l10n.setupSaveFailed);
        setState(() => _saving = false);
      }
      return;
    }
    // Consent is saved. Registration is best-effort and never blocks.
    try {
      final service = ref.read(captureDeviceRegistrationServiceProvider);
      if (ai) {
        await service.retry();
      } else {
        await service.syncBackendState();
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() => _saving = false);
    widget.onDone(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final settings = ref.watch(userSettingsProvider).valueOrNull;
    final cloudOn = settings?.cloudProcessingEnabled ?? false;
    final isCloud = widget.kind == OnboardingConsentKind.cloud;

    final String title;
    final String? lead;
    final List<String> bullets;
    final String enableLabel;
    final VoidCallback onEnable;
    if (isCloud) {
      title = l10n.onbCloudTitle;
      lead = null;
      bullets = [
        l10n.onbCloudBullet1,
        l10n.onbCloudBullet2,
        l10n.onbCloudBullet3,
      ];
      enableLabel = l10n.onbCloudEnable;
      onEnable = () => _grant(cloud: true, ai: false);
    } else if (cloudOn) {
      title = l10n.onbAiTitle;
      lead = null;
      bullets = [l10n.onbAiBullet1, l10n.onbAiBullet2];
      enableLabel = l10n.onbAiEnable;
      onEnable = () => _grant(cloud: false, ai: true);
    } else {
      title = l10n.onbAiTitle;
      lead = l10n.onbAiNeedsCloud;
      bullets = [l10n.onbCloudBullet1, l10n.onbAiBullet1, l10n.onbAiBullet2];
      enableLabel = l10n.onbAiEnableBoth;
      onEnable = () => _grant(cloud: true, ai: true);
    }

    final muted = Colors.white.withValues(alpha: 0.72);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter, AppSpacing.s6, AppSpacing.gutter, AppSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: AppTypography.sectionTitle(Colors.white)),
          const SizedBox(height: AppSpacing.s3),
          if (lead != null) ...[
            Text(lead, style: AppTypography.bodyStrong(Colors.white)),
            const SizedBox(height: AppSpacing.s3),
          ],
          for (final bullet in bullets)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.s2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('•  ', style: AppTypography.body(muted)),
                  Expanded(
                      child: Text(bullet, style: AppTypography.body(muted))),
                ],
              ),
            ),
          const SizedBox(height: AppSpacing.s3),
          SizedBox(
            height: AppSpacing.buttonHeight,
            child: FilledButton(
              onPressed: _saving ? null : onEnable,
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: AppBrandBlue.brand,
              ),
              child: Text(enableLabel),
            ),
          ),
          const SizedBox(height: AppSpacing.s2),
          TextButton(
            onPressed: _saving ? null : () => widget.onDone(false),
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            child: Text(l10n.smartConsentNotNow),
          ),
          TextButton(
            onPressed: () => context.push(widget.privacyRoute),
            style: TextButton.styleFrom(foregroundColor: muted),
            child: Text(l10n.smartConsentPrivacyLink),
          ),
        ],
      ),
    );
  }
}

/// Readiness step: live registration status when Cloud Sync is on. Never
/// blocks — Continue is always available.
class OnboardingReadinessStep extends ConsumerWidget {
  const OnboardingReadinessStep({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final cloudOn =
        ref.watch(userSettingsProvider).valueOrNull?.cloudProcessingEnabled ??
            false;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter, AppSpacing.s6, AppSpacing.gutter, AppSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.onbReadyTitle,
              style: AppTypography.sectionTitle(Colors.white)),
          const SizedBox(height: AppSpacing.s3),
          Text(
            cloudOn ? l10n.onbReadyBodyOn : l10n.onbReadyBodyOff,
            style: AppTypography.body(Colors.white.withValues(alpha: 0.72)),
          ),
          if (cloudOn) ...[
            const SizedBox(height: AppSpacing.s4),
            const SmartAnalysisRegistrationStatus(onDark: true),
          ],
          const SizedBox(height: AppSpacing.s5),
          SizedBox(
            height: AppSpacing.buttonHeight,
            child: FilledButton(
              onPressed: onDone,
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: AppBrandBlue.brand,
              ),
              child: Text(l10n.setupCloudCta),
            ),
          ),
        ],
      ),
    );
  }
}
