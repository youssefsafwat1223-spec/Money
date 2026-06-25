import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import 'widgets/onboarding_scaffold.dart';

class CaptureMethodPickerScreen extends ConsumerStatefulWidget {
  const CaptureMethodPickerScreen({super.key});

  @override
  ConsumerState<CaptureMethodPickerScreen> createState() =>
      _CaptureMethodPickerScreenState();
}

class _CaptureMethodPickerScreenState
    extends ConsumerState<CaptureMethodPickerScreen> {
  late int _selected = Platform.isAndroid ? 0 : 1;

  void _continue() {
    if (_selected == 2) {
      context.push('/onboarding/manual');
    } else {
      context.push('/onboarding/method');
    }
  }

  @override
  Widget build(BuildContext context) {
    return OnboardingScaffold(
      step: 9,
      onBack: () {
        if (context.canPop()) context.pop();
      },
      title: 'كيف تريد إدخال معاملاتك؟',
      subtitle: 'اختر الطريقة التي تناسبك.',
      primaryLabel: 'التالي',
      onPrimary: _continue,
      child: Column(
        children: [
          _OptionCard(
            icon: Icons.sms_rounded,
            title: 'رسائل البنك (تلقائي)',
            desc: 'نستقبل رسائل البنك ونحللها تلقائياً (أندرويد).',
            selected: _selected == 0,
            onTap: () => setState(() => _selected = 0),
          ),
          const SizedBox(height: 12),
          _OptionCard(
            icon: Icons.ios_share_rounded,
            title: 'اختصار iOS (تلقائي)',
            desc: 'استخدم اختصار آبل لتمرير رسائلك بسهولة (iPhone).',
            selected: _selected == 1,
            onTap: () => setState(() => _selected = 1),
          ),
          const SizedBox(height: 12),
          _OptionCard(
            icon: Icons.content_paste_rounded,
            title: 'لصق يدوي احتياطي',
            desc: 'انسخ الرسالة والصقها في مالي في أي وقت.',
            selected: _selected == 2,
            onTap: () => setState(() => _selected = 2),
          ),
        ],
      ),
    );
  }
}

class _OptionCard extends StatelessWidget {
  const _OptionCard({
    required this.icon,
    required this.title,
    required this.desc,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String desc;
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
        padding: const EdgeInsets.all(AppSpacing.s4),
        decoration: BoxDecoration(
          color: selected ? c.cta.withValues(alpha: 0.10) : c.surfaceCard,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected ? c.cta : c.border,
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: selected ? c.cta.withValues(alpha: 0.16) : c.surfaceMuted,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: selected ? c.cta : c.textMuted, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: obFont(15, FontWeight.w800, 1.2, c.textPrimary)),
                  const SizedBox(height: 3),
                  Text(desc,
                      style: obFont(12, FontWeight.w500, 1.45, c.textMuted)),
                ],
              ),
            ),
            const SizedBox(width: 10),
            _RadioDot(selected: selected),
          ],
        ),
      ),
    );
  }
}

class _RadioDot extends StatelessWidget {
  const _RadioDot({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: selected ? c.cta : c.border, width: 2),
      ),
      child: selected
          ? Center(
              child: Container(
                width: 11,
                height: 11,
                decoration: BoxDecoration(shape: BoxShape.circle, color: c.cta),
              ),
            )
          : null,
    );
  }
}
