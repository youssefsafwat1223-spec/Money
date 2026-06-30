import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../capture/services/android_sms_capture_service.dart';
import 'widgets/onboarding_scaffold.dart';

/// Onboarding step 9 — "How to add your transactions".
/// Three expandable explanation sections (SMS auto / iOS Shortcut / manual
/// paste). Tapping a section reveals its details inline. Continues to the
/// backup step; no separate "waiting" or bottom-sheet setup screen.
class CaptureMethodPickerScreen extends ConsumerStatefulWidget {
  const CaptureMethodPickerScreen({super.key});

  @override
  ConsumerState<CaptureMethodPickerScreen> createState() =>
      _CaptureMethodPickerScreenState();
}

class _CaptureMethodPickerScreenState
    extends ConsumerState<CaptureMethodPickerScreen> {
  late int? _open = Platform.isAndroid ? 0 : 1;
  bool _granting = false;

  void _toggle(int i) => setState(() => _open = _open == i ? null : i);

  void _continue() => context.push('/onboarding/ai-consent');

  Future<void> _grantSms() async {
    if (_granting) return;
    setState(() => _granting = true);
    final granted =
        await AndroidSmsCaptureService.instance.requestPermissions();
    if (!mounted) return;
    setState(() => _granting = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(granted
            ? 'تم تفعيل قراءة رسائل البنك ✓'
            : 'تقدر تفعّلها لاحقاً من الإعدادات.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return OnboardingScaffold(
      step: 9,
      onBack: () {
        if (context.canPop()) context.pop();
      },
      title: 'كيفية إدخال معاملاتك',
      subtitle: 'قرش يضيف عملياتك بـ 3 طرق. اضغط على كل طريقة لمعرفة التفاصيل.',
      primaryLabel: 'التالي',
      onPrimary: _continue,
      child: Column(
        children: [
          _ExpandableMethod(
            icon: Icons.sms_rounded,
            color: c.cta,
            title: 'رسائل البنك (تلقائي)',
            platformTag: 'Android',
            summary:
                'للأندرويد: نقرأ رسائل البنك على جهازك ونضيف العملية تلقائياً.',
            expanded: _open == 0,
            onTap: () => _toggle(0),
            body: _SmsBody(granting: _granting, onGrant: _grantSms),
          ),
          const SizedBox(height: 12),
          _ExpandableMethod(
            icon: Icons.ios_share_rounded,
            color: c.accent,
            title: 'اختصار iOS (تلقائي)',
            platformTag: 'iPhone',
            summary: 'على iPhone نستخدم اختصار آبل لتمرير رسائل البنك لقرش.',
            expanded: _open == 1,
            onTap: () => _toggle(1),
            body: const _ShortcutBody(),
          ),
          const SizedBox(height: 12),
          _ExpandableMethod(
            icon: Icons.content_paste_rounded,
            color: c.success,
            title: 'اللصق اليدوي',
            summary: 'حل احتياطي دائم: انسخ أي رسالة بنك والصقها في قرش.',
            expanded: _open == 2,
            onTap: () => _toggle(2),
            body: const _ManualBody(),
          ),
        ],
      ),
    );
  }
}

// ── Expandable shell ─────────────────────────────────────────────────────────

class _ExpandableMethod extends StatelessWidget {
  const _ExpandableMethod({
    required this.icon,
    required this.color,
    required this.title,
    required this.summary,
    required this.expanded,
    required this.onTap,
    required this.body,
    this.platformTag,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String summary;
  final bool expanded;
  final VoidCallback onTap;
  final Widget body;
  final String? platformTag;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      decoration: BoxDecoration(
        color: expanded ? color.withValues(alpha: 0.08) : c.surfaceCard,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: expanded ? color : c.border),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(18),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.s4),
              child: Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Color.lerp(color, Colors.white, 0.18)!,
                          color,
                          Color.lerp(color, const Color(0xFF021B79), 0.42)!,
                        ],
                      ),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(icon, color: Colors.white, size: 22),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(title,
                                  style: obFont(
                                      15, FontWeight.w800, 1.2, c.textPrimary)),
                            ),
                            if (platformTag != null) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: color.withValues(alpha: 0.16),
                                  borderRadius: BorderRadius.circular(99),
                                ),
                                child: Text(platformTag!,
                                    textDirection: TextDirection.ltr,
                                    style:
                                        obFont(10, FontWeight.w800, 1, color)),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(summary,
                            style:
                                obFont(12, FontWeight.w500, 1.4, c.textMuted)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  AnimatedRotation(
                    turns: expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: Icon(Icons.keyboard_arrow_down_rounded,
                        color: c.textMuted, size: 24),
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 220),
            crossFadeState:
                expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            firstChild: const SizedBox(width: double.infinity),
            secondChild: Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.s4, 0, AppSpacing.s4, AppSpacing.s4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Divider(color: c.border, height: 18),
                  body,
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Section bodies ───────────────────────────────────────────────────────────

class _SmsBody extends StatelessWidget {
  const _SmsBody({required this.granting, required this.onGrant});

  final bool granting;
  final VoidCallback onGrant;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _DetailStep('1', 'فعّل إذن الرسائل',
            'اضغط الزر بالأسفل واسمح لقرش بقراءة رسائل البنك (أندرويد فقط).'),
        const _DetailStep('2', 'استقبل رسالة البنك',
            'بعد أي عملية، تصلك رسالة من بنكك على نفس الجهاز.'),
        const _DetailStep('3', 'تحليل تلقائي على الجهاز',
            'قرش يقرأ الرسالة محلياً ويحدّد المبلغ والتاجر والتصنيف — بدون إنترنت.'),
        const _DetailStep('4', 'مراجعة عند الحاجة',
            'لو قرش مش متأكد، يفتح لك مراجعة سريعة قبل إضافة العملية.'),
        if (Platform.isAndroid) ...[
          const SizedBox(height: 6),
          SizedBox(
            height: 48,
            child: FilledButton.icon(
              onPressed: granting ? null : onGrant,
              style: FilledButton.styleFrom(backgroundColor: c.cta),
              icon: granting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.lock_open_rounded, size: 18),
              label: const Text('السماح بقراءة الرسائل'),
            ),
          ),
        ],
      ],
    );
  }
}

class _ShortcutBody extends StatelessWidget {
  const _ShortcutBody();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DetailStep('1', 'افتح تطبيق الاختصارات',
            'ادخل على Shortcuts ثم تبويب Automation من الأسفل.'),
        _DetailStep('2', 'أنشئ Automation جديد',
            'اضغط New Automation أو علامة +، ثم اختر Message.'),
        _DetailStep('3', 'حدّد رسائل البنك',
            'في Message Contents اكتب رمز العملة مثل SAR، وكرّر لاحقاً لأي عملة إضافية.'),
        _DetailStep(
            '4', 'خلّيه يعمل فوراً', 'اختَر Run Immediately ثم اضغط Next.'),
        _DetailStep('5', 'اختَر اختصار قرش',
            'اضغط New Blank Automation، وابحث عن Process Bank SMS.'),
        _DetailStep('6', 'مرّر نص الرسالة',
            'لازم يظهر حقل SMS Text. اختَر له Shortcut Input.'),
        _DetailStep('7', 'طابق الشكل النهائي',
            'لازم يكون: Receive messages as input ثم Process Bank SMS وفيها SMS Text = Shortcut Input.'),
        _DetailStep('8', 'احفظ الاختصار',
            'اضغط Done. بعدها أي رسالة بنك مطابقة هتتحول لعملية داخل قرش.'),
      ],
    );
  }
}

class _ManualBody extends StatelessWidget {
  const _ManualBody();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DetailStep('1', 'انسخ نص الرسالة',
            'من تطبيق الرسائل، انسخ رسالة البنك بالكامل.'),
        _DetailStep(
            '2', 'افتح قرش واضغط إضافة', 'من زر + اختر «لصق رسالة بنك».'),
        _DetailStep('3', 'الصق وحلّل',
            'الصق النص، وقرش يحلله على جهازك ويضيف العملية بعد مراجعة سريعة.'),
      ],
    );
  }
}

class _DetailStep extends StatelessWidget {
  const _DetailStep(this.n, this.title, this.body);

  final String n;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: c.cta.withValues(alpha: 0.14),
            ),
            child: Text(n, style: obFont(12, FontWeight.w800, 1, c.cta)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: obFont(13.5, FontWeight.w800, 1.25, c.textPrimary)),
                const SizedBox(height: 2),
                Text(body,
                    style: obFont(12, FontWeight.w500, 1.5, c.textMuted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
