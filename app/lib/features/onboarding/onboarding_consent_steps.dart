import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/l10n_ext.dart';
import '../consent/smart_analysis_consent_sheet.dart';
import '../settings/settings_providers.dart';

enum OnboardingConsentKind { cloud, smartAnalysis }

/// One explicit consent decision on the navy onboarding surface. Nothing is
/// pre-selected: Accept grants both; local use persists both denials.
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
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter, AppSpacing.s6, AppSpacing.gutter, AppSpacing.s4),
        child: SmartAnalysisConsentPanel(
            onDone: widget.onDone,
            onDark: true,
            privacyRoute: widget.privacyRoute),
      );
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
