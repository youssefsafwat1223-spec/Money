import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../settings/settings_providers.dart';
import 'widgets/onboarding_scaffold.dart';

class LanguageSelectionScreen extends ConsumerStatefulWidget {
  const LanguageSelectionScreen({super.key});

  @override
  ConsumerState<LanguageSelectionScreen> createState() =>
      _LanguageSelectionScreenState();
}

class _LanguageSelectionScreenState
    extends ConsumerState<LanguageSelectionScreen> {
  String _selected = 'ar';

  Future<void> _continue() async {
    await ref.read(saveLanguageUseCaseProvider).call(_selected);
    refreshUserSettings(ref);
    if (mounted) context.go('/onboarding/intro');
  }

  @override
  Widget build(BuildContext context) {
    return OnboardingScaffold(
      step: 2,
      onSkip: _continue,
      title: 'اختر اللغة',
      subtitle: 'يمكنك تغيير اللغة من الإعدادات في أي وقت',
      primaryLabel: 'التالي',
      onPrimary: _continue,
      child: Column(
        children: [
          _LangCard(
            title: 'العربية',
            tag: 'RTL',
            selected: _selected == 'ar',
            onTap: () => setState(() => _selected = 'ar'),
          ),
          const SizedBox(height: AppSpacing.s3),
          _LangCard(
            title: 'English',
            tag: 'LTR',
            selected: _selected == 'en',
            onTap: () => setState(() => _selected = 'en'),
          ),
        ],
      ),
    );
  }
}

class _LangCard extends StatelessWidget {
  const _LangCard({
    required this.title,
    required this.tag,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String tag;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.s5, vertical: AppSpacing.s4),
        decoration: BoxDecoration(
          color: selected ? c.cta.withValues(alpha: 0.12) : c.surfaceCard,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected ? c.cta : c.border,
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style:
                          obFont(18, FontWeight.w800, 1.2, c.textPrimary)),
                  const SizedBox(height: 3),
                  Text(tag,
                      style: obFont(12, FontWeight.w600, 1.2, c.textMuted)),
                ],
              ),
            ),
            _CheckDot(selected: selected),
          ],
        ),
      ),
    );
  }
}

class _CheckDot extends StatelessWidget {
  const _CheckDot({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? c.cta : Colors.transparent,
        border: Border.all(
          color: selected ? c.cta : c.border,
          width: 1.6,
        ),
      ),
      child: selected
          ? const Icon(Icons.check_rounded, size: 16, color: Colors.white)
          : null,
    );
  }
}
