import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';

import '../../core/session/app_session.dart';
import '../../core/theme/app_assets.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import 'widgets/luxe_starry_bg.dart';

const _kGold = Color(0xFFDAA520);

/// Page 2 of onboarding — the brand reveal that closes the cinematic sequence.
///
/// This is where the welcome-seen flag is set (end of the story→brand flow),
/// right before handing off to mandatory auth.
class OnboardingBrandScreen extends StatelessWidget {
  const OnboardingBrandScreen({super.key});

  Future<void> _continue(BuildContext context) async {
    await AppSession.instance.markWelcomeManifestoSeen();
    if (context.mounted) context.go('/onboarding/auth');
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      backgroundColor: c.bg,
      body: Stack(
        children: [
          const Positioned.fill(child: LuxeStarryBackground()),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
              child: Column(
                children: [
                  const Spacer(flex: 3),
                  // Logo condenses in with a single gold glow pulse.
                  Container(
                    padding: const EdgeInsets.all(28),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: _kGold.withValues(alpha: 0.35),
                          blurRadius: 60,
                          spreadRadius: 4,
                        ),
                      ],
                    ),
                    child: Image.asset(AppAssets.qirshCoinGold,
                        width: 120, height: 120),
                  )
                      .animate()
                      .scale(
                        begin: const Offset(0.6, 0.6),
                        end: const Offset(1, 1),
                        duration: 900.ms,
                        curve: Curves.easeOutBack,
                      )
                      .fadeIn(duration: 700.ms),
                  const SizedBox(height: AppSpacing.s5),
                  Text(
                    'قِرش',
                    style: AppTypography.title1(c.textMain).copyWith(
                      fontWeight: FontWeight.w900,
                      fontSize: 40,
                    ),
                  ).animate().fadeIn(delay: 700.ms, duration: 600.ms),
                  const SizedBox(height: 8),
                  Text(
                    'فلوسك واضحة.',
                    style: AppTypography.body(_kGold),
                  ).animate().fadeIn(delay: 1000.ms, duration: 600.ms),
                  const Spacer(flex: 4),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => _continue(context),
                      style: FilledButton.styleFrom(
                        backgroundColor: c.primary,
                        minimumSize: const Size.fromHeight(54),
                      ),
                      child: Text('يلا نبدأ',
                          style: AppTypography.bodyStrong(Colors.white)),
                    ),
                  ).animate().fadeIn(delay: 1400.ms, duration: 500.ms),
                  const SizedBox(height: AppSpacing.s5),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
