
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/session/app_session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../capture/services/android_sms_capture_service.dart';

/// خطوة اختيار طريقة الإدخال بعد الدخول:
/// - Android: طلب إذن قراءة رسائل البنك.
/// - iOS: تعليمات المشاركة / اختصار Siri.
class OnboardingMethodScreen extends ConsumerStatefulWidget {
  const OnboardingMethodScreen({super.key});

  @override
  ConsumerState<OnboardingMethodScreen> createState() =>
      _OnboardingMethodScreenState();
}

class _OnboardingMethodScreenState
    extends ConsumerState<OnboardingMethodScreen> {
  bool _busy = false;

  Future<void> _finish() async {
    await AppSession.instance.finishOnboarding();
    if (mounted) context.go('/');
  }

  Future<void> _requestSms() async {
    if (_busy) return;
    setState(() => _busy = true);
    final granted =
        await AndroidSmsCaptureService.instance.requestPermissions();
    if (!mounted) return;
    setState(() => _busy = false);
    if (!granted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لم يتم التفعيل — تقدر تلصق الرسائل يدوياً.')),
      );
    }
    await _finish();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isAndroid = Platform.isAndroid;

    return Scaffold(
      appBar: AppBar(automaticallyImplyLeading: false),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.gutter),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: AppSpacing.s3),
              CircleAvatar(
                radius: 34,
                backgroundColor: c.primary.withValues(alpha: 0.12),
                child: Icon(
                    isAndroid ? Icons.sms_outlined : Icons.ios_share,
                    color: c.primary,
                    size: 30),
              ),
              const SizedBox(height: AppSpacing.s4),
              Text(
                isAndroid ? 'فعّل التتبّع التلقائي' : 'على iPhone، أنت تتحكّم',
                textAlign: TextAlign.center,
                style: AppTypography.title1(c.textMain),
              ),
              const SizedBox(height: AppSpacing.s2),
              Text(
                isAndroid
                    ? 'نقرأ رسائل بنكك ونحلّلها على جهازك فقط — ونقرأ من البنوك فقط.'
                    : 'أضف عملياتك بمشاركة رسالة البنك أو باختصار Siri أو باللصق.',
                textAlign: TextAlign.center,
                style: AppTypography.callout(c.textLight),
              ),
              const SizedBox(height: AppSpacing.s5),
              if (isAndroid)
                _card(context, [
                  'اضغط «السماح بقراءة الرسائل».',
                  'وافق على الإذن من النافذة.',
                  'نلتقط عمليات بنكك تلقائياً ونصنّفها.',
                ])
              else
                _card(context, [
                  'افتح رسالة البنك في تطبيق الرسائل.',
                  'اضغط «مشاركة» واختر تطبيقنا.',
                  'أو أنشئ اختصار Siri يشارك الرسالة لنا.',
                ]),
              if (!isAndroid) ...[
                const SizedBox(height: AppSpacing.s3),
                OutlinedButton.icon(
                  onPressed: () => context.push('/onboarding/ios-shortcut'),
                  icon: const Icon(Icons.menu_book_outlined, size: 18),
                  label: const Text('دليل إعداد الاختصار خطوة بخطوة'),
                ),
              ],
              const Spacer(),
              if (isAndroid)
                SizedBox(
                  height: 56,
                  child: FilledButton(
                    onPressed: _busy ? null : _requestSms,
                    style: FilledButton.styleFrom(
                      backgroundColor: c.primary,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppRadius.md)),
                    ),
                    child: _busy
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                                strokeWidth: 2.5, color: Colors.white))
                        : Text('السماح بقراءة الرسائل',
                            style: AppTypography.bodyStrong(Colors.white)),
                  ),
                )
              else
                SizedBox(
                  height: 56,
                  child: FilledButton(
                    onPressed: _finish,
                    style: FilledButton.styleFrom(
                      backgroundColor: c.primary,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppRadius.md)),
                    ),
                    child: Text('تمام، فهمت',
                        style: AppTypography.bodyStrong(Colors.white)),
                  ),
                ),
              const SizedBox(height: AppSpacing.s2),
              TextButton(
                onPressed: _finish,
                child: Text('لاحقاً، ألصق يدوياً',
                    style: AppTypography.bodyStrong(c.textLight)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _card(BuildContext context, List<String> steps) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s4),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.s2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    radius: 12,
                    backgroundColor: c.primary.withValues(alpha: 0.14),
                    child: Text('${i + 1}',
                        style: AppTypography.caption(c.primary)),
                  ),
                  const SizedBox(width: AppSpacing.s3),
                  Expanded(
                      child: Text(steps[i],
                          style: AppTypography.body(c.textMain))),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
