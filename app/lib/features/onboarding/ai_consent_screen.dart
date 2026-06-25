import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../settings/settings_providers.dart';
import 'widgets/neon_illustration.dart';
import 'widgets/onboarding_scaffold.dart';

class AiConsentScreen extends ConsumerStatefulWidget {
  const AiConsentScreen({super.key});

  @override
  ConsumerState<AiConsentScreen> createState() => _AiConsentScreenState();
}

class _AiConsentScreenState extends ConsumerState<AiConsentScreen> {
  bool _consent = true;

  Future<void> _continue() async {
    try {
      final repo = ref.read(userSettingsRepositoryProvider);
      final settings = await repo.getSettings();
      await repo.saveSettings(settings.copyWith(aiConsentGranted: _consent));
      refreshUserSettings(ref);
    } catch (_) {
      // Non-blocking — consent defaults are safe.
    }
    if (mounted) context.push('/onboarding/completion');
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return OnboardingScaffold(
      step: 14,
      onBack: () {
        if (context.canPop()) context.pop();
      },
      title: 'الذكاء الاصطناعي',
      subtitle: 'نستخدمه فقط لتحسين تجربتك وتصنيف عملياتك بدقة.',
      primaryLabel: 'التالي',
      onPrimary: _continue,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(
            child: NeonIllustration(
              icon: Icons.psychology_rounded,
              size: 170,
            ),
          ),
          const SizedBox(height: 28),
          Container(
            padding: const EdgeInsets.all(AppSpacing.s4),
            decoration: BoxDecoration(
              color: c.surfaceCard,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: c.border),
            ),
            child: Text(
              'قد نرسل نص الرسالة (بعد إخفاء البيانات الحساسة مثل أرقام البطاقات والأسماء) لخدمة ذكاء اصطناعي لتحليلها عندما يعجز المحرك المحلي — من أجل تصنيف أدق. تقدر توقفه في أي وقت من الإعدادات.',
              style: obFont(13, FontWeight.w500, 1.65, c.textSecondary),
            ),
          ),
          const SizedBox(height: 16),
          _ConsentToggle(
            value: _consent,
            onChanged: (v) => setState(() => _consent = v),
          ),
        ],
      ),
    );
  }
}

class _ConsentToggle extends StatelessWidget {
  const _ConsentToggle({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s4, vertical: AppSpacing.s3),
      decoration: BoxDecoration(
        color: value ? c.cta.withValues(alpha: 0.10) : c.surfaceCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: value ? c.cta : c.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'أوافق على استخدام الذكاء الاصطناعي',
              style: obFont(14, FontWeight.w700, 1.3, c.textPrimary),
            ),
          ),
          Switch.adaptive(
            value: value,
            onChanged: onChanged,
            activeColor: c.cta,
          ),
        ],
      ),
    );
  }
}
