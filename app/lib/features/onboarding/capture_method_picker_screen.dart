import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../capture/manual_paste_screen.dart';
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

  void _continue() => context.push('/onboarding/backup-info');

  Future<void> _grantSms() async {
    if (_granting) return;
    setState(() => _granting = true);
    final granted = await AndroidSmsCaptureService.instance.requestPermissions();
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
      subtitle: 'مالي يضيف عملياتك بـ 3 طرق. اضغط على كل طريقة لمعرفة التفاصيل.',
      primaryLabel: 'التالي',
      onPrimary: _continue,
      child: Column(
        children: [
          _ExpandableMethod(
            icon: Icons.sms_rounded,
            color: c.cta,
            title: 'رسائل البنك (تلقائي)',
            summary: 'نقرأ رسائل البنك على جهازك ونضيف العملية تلقائياً.',
            expanded: _open == 0,
            onTap: () => _toggle(0),
            body: _SmsBody(granting: _granting, onGrant: _grantSms),
          ),
          const SizedBox(height: 12),
          _ExpandableMethod(
            icon: Icons.ios_share_rounded,
            color: c.accent,
            title: 'اختصار iOS (تلقائي)',
            summary: 'على iPhone نستخدم اختصار آبل لتمرير رسائل البنك لمالي.',
            expanded: _open == 1,
            onTap: () => _toggle(1),
            body: const _ShortcutBody(),
          ),
          const SizedBox(height: 12),
          _ExpandableMethod(
            icon: Icons.content_paste_rounded,
            color: c.success,
            title: 'اللصق اليدوي',
            summary: 'حل احتياطي دائم: انسخ أي رسالة بنك والصقها في مالي.',
            expanded: _open == 2,
            onTap: () => _toggle(2),
            body: _ManualBody(
              onTry: () => ManualPasteScreen.showSheet(context),
            ),
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
  });

  final IconData icon;
  final Color color;
  final String title;
  final String summary;
  final bool expanded;
  final VoidCallback onTap;
  final Widget body;

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
                          Color.lerp(color, const Color(0xFF120A2E), 0.42)!,
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
                        Text(title,
                            style:
                                obFont(15, FontWeight.w800, 1.2, c.textPrimary)),
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
        const _Step('1', 'تصلك رسالة من البنك بعد أي عملية.'),
        const _Step('2', 'مالي يقرأها على جهازك فقط — مفيش بيانات بتطلع برّه.'),
        const _Step('3', 'العملية تتضاف وتتصنّف تلقائياً.'),
        if (Platform.isAndroid) ...[
          const SizedBox(height: 12),
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
              label: const Text('منح إذن قراءة الرسائل'),
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
        _Step('1', 'افتح تطبيق «الاختصارات» (Shortcuts) على الـ iPhone.'),
        _Step('2', 'أنشئ Automation جديد من نوع «رسالة» (Message).'),
        _Step('3', 'اجعله يعمل تلقائياً عند وصول رسائل البنك.'),
        _Step('4', 'اختر إجراء «مشاركة» ووجّهه إلى مالي.'),
        _Step('5', 'احفظ الاختصار — وأي رسالة بنك هتتحوّل لعملية في مالي.'),
      ],
    );
  }
}

class _ManualBody extends StatelessWidget {
  const _ManualBody({required this.onTry});

  final VoidCallback onTry;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Step('1', 'انسخ نص رسالة البنك من تطبيق الرسائل.'),
        const _Step('2', 'افتح مالي واضغط «إضافة».'),
        const _Step('3', 'الصق الرسالة وسنحللها على جهازك.'),
        const SizedBox(height: 12),
        SizedBox(
          height: 48,
          child: OutlinedButton.icon(
            onPressed: onTry,
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: c.border),
              foregroundColor: c.cta,
            ),
            icon: const Icon(Icons.content_paste_rounded, size: 18),
            label: const Text('جرّب اللصق الآن'),
          ),
        ),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  const _Step(this.n, this.text);

  final String n;
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: c.cta.withValues(alpha: 0.14),
            ),
            child: Text(n, style: obFont(11, FontWeight.w800, 1, c.cta)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(text,
                  style: obFont(13, FontWeight.w500, 1.45, c.textPrimary)),
            ),
          ),
        ],
      ),
    );
  }
}
