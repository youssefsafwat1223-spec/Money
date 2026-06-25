import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../common/app_button.dart';
import 'premium_ui.dart';

TextStyle obFont(double size, FontWeight w, double h, Color color) {
  return GoogleFonts.inter(
    fontSize: size,
    fontWeight: w,
    height: h,
    color: color,
  ).copyWith(
    fontFamilyFallback: [
      GoogleFonts.ibmPlexSansArabic().fontFamily!,
      GoogleFonts.alexandria().fontFamily!,
    ],
  );
}

/// Shared chrome for every onboarding screen so all 16 steps match:
/// back / progress bar / skip on top, big title + subtitle, a body, and a
/// full-width purple primary button (with optional secondary text) at the
/// bottom. Background is the purple [PremiumBackground].
class OnboardingScaffold extends StatelessWidget {
  const OnboardingScaffold({
    super.key,
    required this.title,
    required this.primaryLabel,
    required this.child,
    this.subtitle,
    this.onBack,
    this.onSkip,
    this.step,
    this.totalSteps = 16,
    this.onPrimary,
    this.primaryLoading = false,
    this.primaryDisabled = false,
    this.secondaryLabel,
    this.onSecondary,
    this.scrollableBody = true,
    this.centerTitle = false,
  });

  final String title;
  final String? subtitle;
  final String primaryLabel;
  final Widget child;
  final VoidCallback? onBack;
  final VoidCallback? onSkip;
  final int? step;
  final int totalSteps;
  final VoidCallback? onPrimary;
  final bool primaryLoading;
  final bool primaryDisabled;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;
  final bool scrollableBody;
  final bool centerTitle;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isRtl = Directionality.of(context) == TextDirection.rtl;

    final header = Column(
      crossAxisAlignment:
          centerTitle ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      children: [
        Text(
          title,
          textAlign: centerTitle ? TextAlign.center : TextAlign.start,
          style: obFont(26, FontWeight.w800, 1.25, c.textPrimary),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: AppSpacing.s2),
          Text(
            subtitle!,
            textAlign: centerTitle ? TextAlign.center : TextAlign.start,
            style: obFont(14, FontWeight.w500, 1.55, c.textMuted),
          ),
        ],
      ],
    );

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppSpacing.s3),
        header,
        const SizedBox(height: AppSpacing.s6),
        child,
        const SizedBox(height: AppSpacing.s4),
      ],
    );

    return PremiumBackground(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
        child: Column(
          children: [
            // ── Top bar: back · progress · skip ──────────────────────────────
            SizedBox(
              height: 46,
              child: Row(
                children: [
                  if (onBack != null)
                    _RoundIconButton(
                      icon: isRtl
                          ? Icons.arrow_forward_rounded
                          : Icons.arrow_back_rounded,
                      onTap: onBack!,
                    )
                  else
                    const SizedBox(width: 40),
                  Expanded(
                    child: step == null
                        ? const SizedBox()
                        : Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.s4),
                            child: _ProgressBar(
                                step: step!, total: totalSteps),
                          ),
                  ),
                  if (onSkip != null)
                    TextButton(
                      onPressed: onSkip,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(40, 40),
                      ),
                      child: Text('تخطّى',
                          style: obFont(13, FontWeight.w700, 1, c.textMuted)),
                    )
                  else
                    const SizedBox(width: 40),
                ],
              ),
            ),

            // ── Body ─────────────────────────────────────────────────────────
            Expanded(
              child: scrollableBody
                  ? SingleChildScrollView(
                      physics: const BouncingScrollPhysics(),
                      child: body,
                    )
                  : body,
            ),

            // ── Bottom: primary button (+ optional secondary) ────────────────
            Padding(
              padding: const EdgeInsets.only(
                top: AppSpacing.s3,
                bottom: AppSpacing.s4,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppPrimaryButton(
                    label: primaryLabel,
                    onTap: onPrimary,
                    loading: primaryLoading,
                    disabled: primaryDisabled,
                    height: 56,
                  ),
                  if (secondaryLabel != null) ...[
                    const SizedBox(height: AppSpacing.s2),
                    TextButton(
                      onPressed: onSecondary,
                      child: Text(
                        secondaryLabel!,
                        style:
                            obFont(13, FontWeight.w700, 1.2, c.textMuted),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: c.surfaceCard,
      shape: CircleBorder(side: BorderSide(color: c.border)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(icon, size: 20, color: c.textPrimary),
        ),
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.step, required this.total});

  final int step;
  final int total;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final fraction = (step / total).clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(99),
      child: LinearProgressIndicator(
        value: fraction,
        minHeight: 5,
        backgroundColor: c.textMuted.withValues(alpha: 0.18),
        valueColor: AlwaysStoppedAnimation(c.cta),
      ),
    );
  }
}
