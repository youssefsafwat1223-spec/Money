import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import 'widgets/neon_illustration.dart';
import 'widgets/onboarding_scaffold.dart';

/// Onboarding step 8 — "Privacy & Data Safety" (info only).
/// Distinct from the Settings privacy screen (which has account deletion).
class PrivacyInfoScreen extends StatelessWidget {
  const PrivacyInfoScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return OnboardingScaffold(
      step: 8,
      onBack: () {
        if (context.canPop()) context.pop();
      },
      title: 'خصوصيتك أولوية',
      subtitle: 'بياناتك آمنة وستبقى تحت تحكمك.',
      primaryLabel: 'التالي',
      onPrimary: () => context.push('/onboarding/method-picker'),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: NeonIllustration(icon: Icons.shield_rounded, size: 175),
          ),
          SizedBox(height: 30),
          _CheckBullet('لا نشارك بياناتك مع أي جهة.'),
          _CheckBullet('تشفير محلي لبياناتك على جهازك.'),
          _CheckBullet('نسخ احتياطي مشفّر اختياري بالكامل.'),
          _CheckBullet('يمكنك استعادة أو حذف بياناتك في أي وقت.'),
        ],
      ),
    );
  }
}

class _CheckBullet extends StatelessWidget {
  const _CheckBullet(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: c.success.withValues(alpha: 0.16),
            ),
            child: Icon(Icons.check_rounded, size: 16, color: c.success),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(text,
                  style: obFont(14, FontWeight.w600, 1.45, c.textPrimary)),
            ),
          ),
        ],
      ),
    );
  }
}
