import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import 'widgets/premium_ui.dart';

TextStyle _alex(double size, FontWeight weight, double height, Color color, {bool tabular = false}) {
  return GoogleFonts.alexandria(
    fontSize: size,
    fontWeight: weight,
    height: height,
    color: color,
    fontFeatures: tabular ? const [FontFeature.tabularFigures()] : null,
  );
}

class IosShortcutScreen extends StatelessWidget {
  const IosShortcutScreen({super.key});

  static const _steps = <_Step>[
    _Step('احذف القديم', 'افتح تطبيق Shortcuts وروح لتبويب Automation. لو فيه Automation قديم للتطبيق، احذفه.', Icons.delete_outline_rounded),
    _Step('جديد (+)', 'اضغط New Automation (+) ومرّر للأسفل حتى تلقى «Message».', Icons.add_circle_outline_rounded),
    _Step('حدّد الرسائل', 'اضغط على «Message Contents» واكتب رمز عملة البنك (مثال: SAR).', Icons.filter_alt_outlined),
    _Step('بدون تأكيد', 'فعّل «Run Immediately» واضغط Next.', Icons.bolt_rounded),
    _Step('اختصار فارغ', 'اضغط «New Blank Automation».', Icons.insert_drive_file_outlined),
    _Step('إرسال للتطبيق', 'ابحث عن «Post Bank Status»، اختر المتغير «Shortcut Input» وتأكد أنه صحيح.', Icons.send_rounded),
    _Step('تشغيل صامت', 'أوقف «Show When Run» ليشتغل بالخلفية.', Icons.volume_off_rounded),
    _Step('حفظ', 'اضغط زر الحفظ في الأعلى وتم الإعداد.', Icons.check_circle_outline_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return PremiumBackground(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter, vertical: 8.0),
            child: Row(
              children: [
                Container(
                  decoration: BoxDecoration(
                    color: c.surface.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    onPressed: () => context.pop(),
                    icon: Icon(Icons.arrow_forward_rounded, color: c.textMain, size: 20),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
              children: [
                Center(
                  child: GlowingIcon(
                    icon: Icons.apple_rounded,
                    color: c.primary,
                    size: 40,
                  ),
                ),
                const SizedBox(height: 20),
                Text('خطوات الأمان لآبل', textAlign: TextAlign.center, style: _alex(24, FontWeight.w800, 1.2, c.textMain)),
                const SizedBox(height: 8),
                Text(
                  'بسبب قيود نظام iOS، نستخدم تطبيق الاختصارات الرسمي من Apple لتمرير رسائل البنك لـ مالي تلقائياً وبأمان تام.',
                  textAlign: TextAlign.center,
                  style: _alex(13, FontWeight.w500, 1.5, c.textLight),
                ),
                const SizedBox(height: 32),
                
                Text('الخطوات:', style: _alex(15, FontWeight.w800, 1.2, c.textMain)),
                const SizedBox(height: 20),
                GlassCard(
                  padding: const EdgeInsets.all(20),
                  child: ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: _steps.length,
                    separatorBuilder: (context, index) => Padding(
                      padding: const EdgeInsets.only(right: 14.0, top: 4, bottom: 4),
                      child: Container(
                        height: 16,
                        width: 1.5,
                        color: c.border.withValues(alpha: 0.3),
                        alignment: Alignment.centerRight,
                      ),
                    ),
                    itemBuilder: (context, index) {
                      final step = _steps[index];
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              color: c.primary,
                              shape: BoxShape.circle,
                            ),
                            alignment: Alignment.center,
                            child: Text('${index + 1}', style: _alex(12, FontWeight.w800, 1.0, Colors.white)),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Text(step.title, style: _alex(14, FontWeight.w800, 1.2, c.textMain)),
                                      const SizedBox(width: 8),
                                      Icon(step.icon, color: c.textLight, size: 14),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(step.body, style: _alex(12, FontWeight.w500, 1.5, c.textLight)),
                                ],
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                
                const SizedBox(height: 32),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: c.accent.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: c.accent.withValues(alpha: 0.2)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.currency_exchange_rounded, size: 24, color: c.accent),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('تتعامل بأكثر من عملة؟', style: _alex(14, FontWeight.w800, 1.2, c.accent)),
                            const SizedBox(height: 4),
                            Text(
                              'إذا كانت تصلك رسائل بنكية بعملات مختلفة، كرّر نفس الخطوات لكل عملة.',
                              style: _alex(12, FontWeight.w600, 1.5, c.accent.withValues(alpha: 0.8)),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Step {
  const _Step(this.title, this.body, this.icon);
  final String title;
  final String body;
  final IconData icon;
}
