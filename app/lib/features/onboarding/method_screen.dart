import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:go_router/go_router.dart';

import '../../core/backend/supabase_config.dart';
import '../../core/backup/backup_service.dart';
import '../../core/session/app_session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../capture/services/android_sms_capture_service.dart';
import '../../core/utils/l10n_ext.dart';
import 'onboarding_options.dart';
import 'widgets/premium_ui.dart';

TextStyle _alex(double size, FontWeight weight, double height, Color color,
    {bool tabular = false, List<Shadow>? shadows}) {
  return GoogleFonts.alexandria(
    fontSize: size,
    fontWeight: weight,
    height: height,
    color: color,
    shadows: shadows,
    fontFeatures: tabular ? const [FontFeature.tabularFigures()] : null,
  );
}

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
    if (SupabaseConfig.isConfigured) {
      try {
        final hasBackup =
            await ref.read(backupServiceProvider).hasRemoteBackup();
        if (mounted && hasBackup) {
          context.push('/onboarding/restore');
          return;
        }
      } catch (_) {
        // Keep onboarding smooth if the remote check is temporarily unavailable.
      }
    }
    await AppSession.instance.finishOnboarding();
    if (mounted) context.go('/');
  }

  Future<void> _requestSms() async {
    if (_busy) return;
    setState(() => _busy = true);
    await AndroidSmsCaptureService.instance.requestPermissions();
    if (!mounted) return;
    setState(() => _busy = false);
    context.push('/onboarding/listening');
  }

  Future<void> _startIosVerify() async {
    if (SupabaseConfig.isConfigured) {
      try {
        final hasBackup =
            await ref.read(backupServiceProvider).hasRemoteBackup();
        if (mounted && hasBackup) {
          context.push('/onboarding/restore');
          return;
        }
      } catch (_) {}
    }
    if (mounted) context.push('/onboarding/ios-verify');
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final actionForeground = maliPrimaryActionForeground(context);
    final isAndroid = Platform.isAndroid;
    final title = isAndroid ? context.l10n.enableAutoTracking : context.l10n.setupAppleShortcut;
    final subtitle = isAndroid
        ? context.l10n.autoTrackingSubtitleAndroid
        : context.l10n.autoTrackingSubtitleIos;
    final steps = isAndroid
        ? (Localizations.localeOf(context).languageCode == 'en'
            ? const [
                'Click "Allow message reading".',
                'Approve the permission from the dialog.',
                'We capture your bank transactions automatically and classify them.',
              ]
            : const [
                'اضغط «السماح بقراءة الرسائل».',
                'وافق على الإذن من النافذة.',
                'نلتقط عمليات بنكك تلقائياً ونصنّفها.',
              ])
        : const <String>[];

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 680, maxHeight: 620),
            margin: const EdgeInsets.all(AppSpacing.gutter),
            padding: const EdgeInsets.all(AppSpacing.gutter),
            decoration: BoxDecoration(
              color: c.bg,
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: c.border),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.45),
                  blurRadius: 36,
                  spreadRadius: -16,
                  offset: const Offset(0, 18),
                ),
              ],
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 44,
                      height: 5,
                      margin: const EdgeInsets.only(bottom: AppSpacing.s4),
                      decoration: BoxDecoration(
                        color: c.border,
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      gradient: c.primaryGradient,
                      borderRadius: BorderRadius.circular(26),
                    ),
                    child: Column(
                      children: [
                        Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.08),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.10),
                            ),
                          ),
                          child: Icon(
                            isAndroid
                                ? Icons.sms_rounded
                                : Icons.ios_share_rounded,
                            color: Colors.white,
                            size: 30,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          title,
                          textAlign: TextAlign.center,
                          style: _alex(24, FontWeight.w800, 1.2, Colors.white),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          subtitle,
                          textAlign: TextAlign.center,
                          style: _alex(
                            13,
                            FontWeight.w500,
                            1.5,
                            Colors.white.withValues(alpha: 0.84),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  GlassCard(
                    padding: const EdgeInsets.all(18),
                    child: isAndroid
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                context.l10n.howWillActivationWork,
                                style:
                                    _alex(15, FontWeight.w800, 1.3, c.textMain),
                              ),
                              const SizedBox(height: 16),
                              for (var i = 0; i < steps.length; i++) ...[
                                _MethodStep(index: i + 1, text: steps[i]),
                                if (i != steps.length - 1)
                                  const SizedBox(height: 14),
                              ],
                            ],
                          )
                        : const _InlineIosShortcutGuide(),
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    height: 52,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: maliPrimaryActionGradient(context),
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: c.accent.withValues(alpha: 0.25),
                            blurRadius: 15,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: ElevatedButton(
                        onPressed:
                            _busy ? null : (isAndroid ? _requestSms : _startIosVerify),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.transparent,
                          shadowColor: Colors.transparent,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: _busy
                            ? SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  color: actionForeground,
                                ),
                              )
                            : Text(
                                isAndroid
                                    ? context.l10n.allowSmsReading
                                    : context.l10n.gotIt,
                                style: _alex(
                                    15, FontWeight.w800, 1.2, actionForeground),
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _finish,
                    child: Text(
                      context.l10n.laterAddManually,
                      style: _alex(13, FontWeight.w700, 1.2, c.textLight),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _InlineIosShortcutGuide extends ConsumerWidget {
  const _InlineIosShortcutGuide();

  static List<_ShortcutStep> _getSteps(BuildContext context, String keyword) {
    final locale = Localizations.localeOf(context).languageCode;
    if (locale == 'en') {
      return [
        const _ShortcutStep('Open Shortcuts app', 'Go to Shortcuts then Automation tab at the bottom.', Icons.auto_awesome_motion_rounded),
        const _ShortcutStep('Create new Automation', 'Press New Automation or +, then select Message.', Icons.add_circle_outline_rounded),
        _ShortcutStep('Select bank messages', 'In Message Contents type $keyword, then press Next.', Icons.filter_alt_outlined),
        const _ShortcutStep('Run Immediately', 'Select Run Immediately then press Next.', Icons.bolt_rounded),
        const _ShortcutStep('Choose Mali Shortcut', 'Press New Blank Automation, and search for Post Bank Status.', Icons.send_rounded),
        const _ShortcutStep('Pass message text', 'Select Shortcut Input as input to the shortcut so Mali receives the bank message text.', Icons.text_snippet_outlined),
        const _ShortcutStep('Run in background', 'Disable Show When Run so the addition happens silently.', Icons.volume_off_rounded),
        const _ShortcutStep('Save shortcut', 'Press Done. Then any matching bank message will be converted to a transaction inside Mali.', Icons.check_circle_outline_rounded),
      ];
    }
    return [
      const _ShortcutStep('افتح تطبيق الاختصارات', 'ادخل على Shortcuts ثم تبويب Automation من الأسفل.', Icons.auto_awesome_motion_rounded),
      const _ShortcutStep('أنشئ Automation جديد', 'اضغط New Automation أو علامة +، ثم اختر Message.', Icons.add_circle_outline_rounded),
      _ShortcutStep('حدّد رسائل البنك', 'في Message Contents اكتب $keyword، ثم اضغط Next.', Icons.filter_alt_outlined),
      const _ShortcutStep('خلّيه يعمل فوراً', 'اختَر Run Immediately ثم اضغط Next.', Icons.bolt_rounded),
      const _ShortcutStep('اختَر اختصار مالي', 'اضغط New Blank Automation، وابحث عن Post Bank Status.', Icons.send_rounded),
      const _ShortcutStep('مرّر نص الرسالة', 'اختَر Shortcut Input كمدخل للاختصار حتى يستقبل مالي نص رسالة البنك.', Icons.text_snippet_outlined),
      const _ShortcutStep('شغّله في الخلفية', 'أوقف Show When Run حتى الإضافة تتم بدون إزعاج.', Icons.volume_off_rounded),
      const _ShortcutStep('احفظ الاختصار', 'اضغط Done. بعدها أي رسالة بنك مطابقة هتتحول لعملية داخل مالي.', Icons.check_circle_outline_rounded),
    ];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final currencyCode = ref.watch(onboardingSelectionProvider).currencyCode;
    final keyword = currencyKeywords(currencyCode).first;
    final steps = _getSteps(context, keyword);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.l10n.shortcutSetupGuide,
          style: _alex(15, FontWeight.w800, 1.3, c.textMain),
        ),
        const SizedBox(height: 6),
        Text(
          context.l10n.doStepsOnceFromShortcuts,
          style: _alex(11, FontWeight.w600, 1.45, c.textLight),
        ),
        const SizedBox(height: 16),
        for (var i = 0; i < steps.length; i++) ...[
          _ShortcutStepRow(index: i + 1, step: steps[i]),
          if (i != steps.length - 1) const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class _ShortcutStep {
  const _ShortcutStep(this.title, this.body, this.icon);

  final String title;
  final String body;
  final IconData icon;
}

class _ShortcutStepRow extends StatelessWidget {
  const _ShortcutStepRow({required this.index, required this.step});

  final int index;
  final _ShortcutStep step;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: c.primary.withValues(alpha: 0.10),
            shape: BoxShape.circle,
            border: Border.all(color: c.primary.withValues(alpha: 0.18)),
          ),
          alignment: Alignment.center,
          child: Text(
            '$index',
            style: _alex(12, FontWeight.w800, 1, c.primary),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      step.title,
                      style: _alex(13, FontWeight.w800, 1.25, c.textMain),
                    ),
                  ),
                  Icon(step.icon, color: c.accent, size: 16),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                step.body,
                style: _alex(11, FontWeight.w600, 1.45, c.textLight),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MethodStep extends StatelessWidget {
  const _MethodStep({required this.index, required this.text});

  final int index;
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: c.primary.withValues(alpha: 0.10),
            shape: BoxShape.circle,
            border: Border.all(color: c.primary.withValues(alpha: 0.18)),
          ),
          alignment: Alignment.center,
          child: Text(
            '$index',
            style: _alex(12, FontWeight.w800, 1, c.primary),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              text,
              style: _alex(14, FontWeight.w600, 1.4, c.textMain),
            ),
          ),
        ),
      ],
    );
  }
}
