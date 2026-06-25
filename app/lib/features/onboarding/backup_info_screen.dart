import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import 'widgets/neon_illustration.dart';
import 'widgets/onboarding_scaffold.dart';

/// Onboarding step 13 — "Backup & Restore" (info only).
class BackupInfoScreen extends StatelessWidget {
  const BackupInfoScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return OnboardingScaffold(
      step: 13,
      onBack: () {
        if (context.canPop()) context.pop();
      },
      title: 'النسخ الاحتياطي',
      subtitle: 'احفظ بياناتك واستعدها في أي وقت.',
      primaryLabel: 'تفعيل النسخ الاحتياطي',
      onPrimary: () => context.push('/onboarding/ai-consent'),
      secondaryLabel: 'ليس الآن',
      onSecondary: () => context.push('/onboarding/ai-consent'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(
            child: NeonIllustration(icon: Icons.cloud_done_rounded, size: 175),
          ),
          const SizedBox(height: 30),
          _BackupBullet(c, Icons.lock_outline_rounded,
              'نسخ احتياطي مشفّر E2E — اختياري بالكامل.'),
          _BackupBullet(c, Icons.vpn_key_outlined,
              'مفتاحك السري لا نعرفه ولا يصل لخوادمنا.'),
          _BackupBullet(c, Icons.sync_rounded,
              'استعادة سهلة عند تغيير الجهاز.'),
        ],
      ),
    );
  }
}

class _BackupBullet extends StatelessWidget {
  const _BackupBullet(this.c, this.icon, this.text);

  final AppColors c;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s3),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: c.cta.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 18, color: c.cta),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text,
                style: obFont(13.5, FontWeight.w600, 1.45, c.textPrimary)),
          ),
        ],
      ),
    );
  }
}
