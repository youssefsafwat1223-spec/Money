import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';

/// شرح خطوة بخطوة لإعداد Automation في تطبيق Shortcuts على iPhone،
/// بحيث تُرسَل رسائل البنك للتطبيق تلقائياً.
class IosShortcutScreen extends StatelessWidget {
  const IosShortcutScreen({super.key});

  static const _steps = <_Step>[
    _Step('احذف أي Automation قديم',
        'افتح تطبيق Shortcuts ← تبويب Automation. لو فيه Automation قديم للتطبيق، اسحب عليه لليسار واضغط Delete.'),
    _Step('أنشئ Automation جديد',
        'اضغط New Automation (+)، ومرّر للأسفل حتى تجد «Message» (تحت Email) واضغط عليه.'),
    _Step('حدّد الرسائل البنكية',
        'اضغط على «Message Contents» واكتب كلمة موجودة في كل رسائل بنكك — غالباً رمز العملة مثل SAR أو EGP أو AED — ثم اضغط Done.'),
    _Step('التشغيل التلقائي',
        'فعّل «Run Immediately» ثم اضغط Next في أعلى الشاشة.'),
    _Step('إنشاء الاختصار',
        'اضغط «New Blank Automation» (بدون البحث عن أي شيء قبلها).'),
    _Step('إرسال الرسالة للتطبيق',
        'ابحث عن «Post Bank Status» واضغط عليه. اضغط حقل «SMS Status» واختر المتغير «Message» من الأسفل، وتأكّد أنه المتغير المحدد.'),
    _Step('التشغيل الصامت',
        'أوقف «Show When Run» حتى يعمل في الخلفية بدون نوافذ.'),
    _Step('الحفظ',
        'اضغط زر الحفظ في أعلى الشاشة. تم الإعداد بنجاح.'),
  ];

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      appBar: AppBar(title: const Text('إعداد اختصار iPhone')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.gutter),
        children: [
          Container(
            padding: const EdgeInsets.all(AppSpacing.s4),
            decoration: BoxDecoration(
              gradient: c.primaryGradient,
              borderRadius: BorderRadius.circular(AppRadius.card),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('ليه الخطوات دي؟',
                    style: AppTypography.headline(Colors.white)),
                const SizedBox(height: AppSpacing.s2),
                Text(
                  'بسبب قيود iOS، التطبيق ما يقدرش يقرأ الرسائل مباشرة. نستخدم تطبيق Shortcuts لإرسال رسائل البنك للتطبيق تلقائياً.',
                  style: AppTypography.callout(
                      Colors.white.withValues(alpha: 0.9)),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.s5),
          for (var i = 0; i < _steps.length; i++) ...[
            _StepCard(index: i + 1, step: _steps[i]),
            const SizedBox(height: AppSpacing.s3),
          ],
          const SizedBox(height: AppSpacing.s3),
          Container(
            padding: const EdgeInsets.all(AppSpacing.s4),
            decoration: BoxDecoration(
              color: c.surface2,
              borderRadius: BorderRadius.circular(AppRadius.card),
              border: Border.all(color: c.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('أكثر من عملة؟',
                    style: AppTypography.bodyStrong(c.textMain)),
                const SizedBox(height: AppSpacing.s2),
                Text(
                  'لو الرسائل تجيك بعملات مختلفة (مثلاً SAR و USD)، كرّر نفس الـ Automation وغيّر الكلمة في «Message Contents» للعملة الثانية.',
                  style: AppTypography.callout(c.textLight),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.s3),
          Row(
            children: [
              Icon(Icons.lock_outline, size: 18, color: c.primary),
              const SizedBox(width: AppSpacing.s2),
              Expanded(
                child: Text(
                  'التطبيق ما يقرأش كل رسائلك — بس الرسائل اللي فيها الكلمات/العملات اللي حدّدتها.',
                  style: AppTypography.caption(c.textLight),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Step {
  const _Step(this.title, this.body);
  final String title;
  final String body;
}

class _StepCard extends StatelessWidget {
  const _StepCard({required this.index, required this.step});

  final int index;
  final _Step step;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s4),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: c.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              gradient: c.primaryGradient,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text('$index',
                style: AppTypography.bodyStrong(Colors.white)),
          ),
          const SizedBox(width: AppSpacing.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(step.title, style: AppTypography.bodyStrong(c.textMain)),
                const SizedBox(height: 4),
                Text(step.body, style: AppTypography.callout(c.textLight)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
