import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import 'widgets/luxe_starry_bg.dart';

/// Page 1 of onboarding — the cinematic story (replaces the old manifesto).
///
/// Three auto-advancing acts. Tap right = next, tap left = previous.
/// The last act flows into the brand reveal (`/onboarding/brand`). The
/// welcome-seen flag is set there, at the end of the cinematic sequence.
class OnboardingStoryScreen extends StatefulWidget {
  const OnboardingStoryScreen({super.key});

  @override
  State<OnboardingStoryScreen> createState() => _OnboardingStoryScreenState();
}

class _OnboardingStoryScreenState extends State<OnboardingStoryScreen> {
  static const _actDuration = Duration(milliseconds: 4200);
  static const _actCount = 3;

  int _act = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _scheduleAdvance();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _scheduleAdvance() {
    _timer?.cancel();
    _timer = Timer(_actDuration, _next);
  }

  void _next() {
    if (_act < _actCount - 1) {
      setState(() => _act++);
      _scheduleAdvance();
    } else {
      _timer?.cancel();
      context.go('/onboarding/brand');
    }
  }

  void _prev() {
    if (_act > 0) {
      setState(() => _act--);
      _scheduleAdvance();
    }
  }

  void _skip() {
    _timer?.cancel();
    context.go('/onboarding/brand');
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      backgroundColor: c.bg,
      body: Stack(
        children: [
          const Positioned.fill(child: LuxeStarryBackground()),
          // Tap zones: left third = previous, right two-thirds = next.
          Positioned.fill(
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _prev,
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _next,
                  ),
                ),
              ],
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(child: _act3Visual(c)),
          ),
          SafeArea(
            child: Column(
              children: [
                _progressDots(c),
                Expanded(child: Center(child: _actContent(c))),
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: TextButton(
                    onPressed: _skip,
                    child: Text('تخطّي',
                        style: AppTypography.caption(c.textLight)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _progressDots(AppColors c) {
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.gutter, vertical: 16),
      child: Row(
        children: [
          for (var i = 0; i < _actCount; i++) ...[
            Expanded(
              child: Container(
                height: 3,
                decoration: BoxDecoration(
                  color: i <= _act
                      ? c.primary
                      : c.textLight.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            if (i < _actCount - 1) const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }

  Widget _actContent(AppColors c) {
    final (title, sub) = switch (_act) {
      0 => ('رسايل البنك كتير…', 'وفلوسك ضايعة بينها.'),
      1 => ('قِرش بيقراها في ثانية…', 'المبلغ، التاجر، والتصنيف.'),
      _ => ('وبيحوّلها لصورة كاملة لفلوسك.', 'كل جنيه واضح. كل شهر مفهوم.'),
    };
    return Padding(
      key: ValueKey(_act),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_act == 0) _act1Visual(c),
          if (_act == 1) _act2Visual(c),
          const SizedBox(height: 36),
          Text(
            title,
            textAlign: TextAlign.center,
            style: AppTypography.title1(c.textMain)
                .copyWith(fontWeight: FontWeight.w800, height: 1.3),
          ).animate().fadeIn(duration: 600.ms).slideY(begin: 0.15, end: 0),
          const SizedBox(height: 12),
          Text(
            sub,
            textAlign: TextAlign.center,
            style: AppTypography.body(c.textLight),
          ).animate().fadeIn(delay: 300.ms, duration: 600.ms),
        ],
      ),
    );
  }

  // Act 1 — SMS fragments drifting like debris.
  Widget _act1Visual(AppColors c) {
    const fragments = [
      'خصم 250 ج.م …',
      'POS Purchase …',
      'رصيدك المتاح …',
      'CARREFOUR 149 …',
      'OTP 4821 …',
    ];
    return SizedBox(
      height: 180,
      child: Stack(
        alignment: Alignment.center,
        children: [
          for (var i = 0; i < fragments.length; i++)
            Positioned(
              top: (i * 34).toDouble(),
              left: i.isEven ? 20 : null,
              right: i.isOdd ? 20 : null,
              child: Transform.rotate(
                angle: (i.isEven ? -1 : 1) * 0.05,
                child: _fragmentChip(c, fragments[i]),
              )
                  .animate(onPlay: (ctr) => ctr.repeat(reverse: true))
                  .fadeIn(delay: (i * 120).ms, duration: 500.ms)
                  .then()
                  .moveY(begin: 0, end: -8, duration: 1800.ms),
            ),
        ],
      ),
    );
  }

  Widget _fragmentChip(AppColors c, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: c.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: c.border.withValues(alpha: 0.4)),
      ),
      child: Text(text,
          style: AppTypography.caption(c.textLight.withValues(alpha: 0.7))),
    );
  }

  // Act 2 — one message resolves into a clean parsed row.
  Widget _act2Visual(AppColors c) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s4),
      decoration: BoxDecoration(
        color: c.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: c.primary.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              gradient: c.primaryGradient,
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: const Icon(Icons.shopping_bag_outlined, color: Colors.white),
          ),
          const SizedBox(width: AppSpacing.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('CARREFOUR', style: AppTypography.bodyStrong(c.textMain))
                    .animate()
                    .fadeIn(delay: 200.ms),
                Text('بقالة 🛒 · اليوم',
                        style: AppTypography.caption(c.textLight))
                    .animate()
                    .fadeIn(delay: 400.ms),
              ],
            ),
          ),
          Text('−149 ج.م', style: AppTypography.bodyStrong(c.danger))
              .animate()
              .fadeIn(delay: 600.ms)
              .slideX(begin: 0.3, end: 0),
        ],
      ),
    );
  }

  // Act 3 — a rising mini bar chart behind the copy.
  Widget _act3Visual(AppColors c) {
    if (_act != 2) return const SizedBox.shrink();
    const heights = [0.35, 0.6, 0.45, 0.8, 0.55, 0.9, 0.7];
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 120),
        child: SizedBox(
          height: 140,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < heights.length; i++) ...[
                Container(
                  width: 18,
                  height: 140 * heights[i],
                  decoration: BoxDecoration(
                    gradient: c.primaryGradient,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ).animate().scaleY(
                      begin: 0,
                      end: 1,
                      alignment: Alignment.bottomCenter,
                      delay: (i * 90).ms,
                      duration: 600.ms,
                      curve: Curves.easeOutCubic,
                    ),
                if (i < heights.length - 1) const SizedBox(width: 8),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
