import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/session/app_session.dart';
import '../../core/theme/app_colors.dart';
import 'widgets/neon_illustration.dart';
import 'widgets/onboarding_scaffold.dart';

/// Onboarding step 16 — "Completion / Start". The single place that finishes
/// onboarding and enters the app.
class CompletionScreen extends StatefulWidget {
  const CompletionScreen({super.key});

  @override
  State<CompletionScreen> createState() => _CompletionScreenState();
}

class _CompletionScreenState extends State<CompletionScreen> {
  bool _busy = false;

  Future<void> _start() async {
    if (_busy) return;
    setState(() => _busy = true);
    await AppSession.instance.finishOnboarding();
    if (mounted) context.go('/');
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return OnboardingScaffold(
      step: 16,
      title: 'جاهز للانطلاق؟',
      subtitle: 'استمتع بتجربة مالية ذكية تحت تحكمك بالكامل.',
      primaryLabel: 'ابدأ استخدام مالي',
      primaryLoading: _busy,
      onPrimary: _busy ? null : _start,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 20),
          const NeonIllustration(
            icon: Icons.auto_awesome_rounded,
            size: 200,
          ),
          const SizedBox(height: 32),
          Text(
            'كل حاجة جاهزة. مالي هيتابع مصروفاتك ويصنّفها ويوريك صورة واضحة لفلوسك.',
            textAlign: TextAlign.center,
            style: obFont(14, FontWeight.w500, 1.6, c.textMuted),
          ),
        ],
      ),
    );
  }
}
