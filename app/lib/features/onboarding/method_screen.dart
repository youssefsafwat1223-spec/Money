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
import '../../core/utils/l10n_ext.dart';
import 'widgets/premium_ui.dart';

TextStyle _alex(double size, FontWeight weight, double height, Color color,
    {bool tabular = false, List<Shadow>? shadows}) {
  return GoogleFonts.inter(
    fontSize: size,
    fontWeight: weight,
    height: height,
    color: color,
    shadows: shadows,
    fontFeatures: tabular ? const [FontFeature.tabularFigures()] : null,
  ).copyWith(
    fontFamilyFallback: [
      GoogleFonts.ibmPlexSansArabic().fontFamily!,
      GoogleFonts.alexandria().fontFamily!,
    ],
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

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final actionForeground = maliPrimaryActionForeground(context);
    final isAndroid = Platform.isAndroid;
    final title = isAndroid
        ? 'شارك رسائل البنك مع مالي'
        : context.l10n.setupAppleShortcut;
    final subtitle = isAndroid
        ? 'من تطبيق الرسائل، اختر رسالة البنك ثم مشاركة إلى مالي. سنحللها على جهازك ونضيف العملية.'
        : context.l10n.autoTrackingSubtitleIos;
    final steps = isAndroid
        ? (Localizations.localeOf(context).languageCode == 'en'
            ? const [
                'Open the bank SMS in your Messages app.',
                'Tap Share and choose Mali.',
                'Mali parses the text on your device and asks for confirmation when needed.',
              ]
            : const [
                'افتح رسالة البنك من تطبيق الرسائل.',
                'اضغط مشاركة واختر مالي.',
                'مالي يحلل النص على جهازك ويطلب التأكيد عند الحاجة.',
              ])
        : const <String>[];

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            width: double.infinity,
            constraints: BoxConstraints(
              maxWidth: 680,
              maxHeight: MediaQuery.of(context).size.height * 0.85,
            ),
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter,
              AppSpacing.gutter,
              AppSpacing.gutter,
              0,
            ),
            decoration: BoxDecoration(
              color: c.bg,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
              border: Border(
                top: BorderSide(color: c.border),
                left: BorderSide(color: c.border),
                right: BorderSide(color: c.border),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.15),
                  blurRadius: 24,
                  offset: const Offset(0, -4),
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
                        : const IosShortcutGuide(),
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
                        onPressed: _finish,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.transparent,
                          shadowColor: Colors.transparent,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: Text(
                          context.l10n.gotIt,
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
                  SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class IosShortcutGuide extends StatelessWidget {
  const IosShortcutGuide({super.key});

  static List<_ShortcutStep> _getSteps(BuildContext context) {
    final locale = Localizations.localeOf(context).languageCode;
    if (locale == 'en') {
      return const [
        _ShortcutStep('Open Shortcuts app', 'Go to Shortcuts then Automation tab at the bottom.', Icons.auto_awesome_motion_rounded),
        _ShortcutStep('Create new Automation', 'Press New Automation or +, then select Message.', Icons.add_circle_outline_rounded),
        _ShortcutStep('Select bank messages', 'In Message Contents type currency code e.g. SAR, repeat later for additional currencies.', Icons.filter_alt_outlined),
        _ShortcutStep('Run Immediately', 'Select Run Immediately then press Next.', Icons.bolt_rounded),
        _ShortcutStep('Choose Mali Shortcut', 'Press New Blank Automation, and search for Post Bank Status.', Icons.send_rounded),
        _ShortcutStep('Pass message text', 'Select Shortcut Input as input to the shortcut so Mali receives the bank message text.', Icons.text_snippet_outlined),
        _ShortcutStep('Run in background', 'Disable Show When Run so the addition happens silently.', Icons.volume_off_rounded),
        _ShortcutStep('Save shortcut', 'Press Done. Then any matching bank message will be converted to a transaction inside Mali.', Icons.check_circle_outline_rounded),
      ];
    }
    return const [
      _ShortcutStep('افتح تطبيق الاختصارات', 'ادخل على Shortcuts ثم تبويب Automation من الأسفل.', Icons.auto_awesome_motion_rounded),
      _ShortcutStep('أنشئ Automation جديد', 'اضغط New Automation أو علامة +، ثم اختر Message.', Icons.add_circle_outline_rounded),
      _ShortcutStep('حدّد رسائل البنك', 'في Message Contents اكتب رمز العملة مثل SAR، وكرّر لاحقاً لأي عملة إضافية.', Icons.filter_alt_outlined),
      _ShortcutStep('خلّيه يعمل فوراً', 'اختَر Run Immediately ثم اضغط Next.', Icons.bolt_rounded),
      _ShortcutStep('اختَر اختصار مالي', 'اضغط New Blank Automation، وابحث عن Post Bank Status.', Icons.send_rounded),
      _ShortcutStep('مرّر نص الرسالة', 'اختَر Shortcut Input كمدخل للاختصار حتى يستقبل مالي نص رسالة البنك.', Icons.text_snippet_outlined),
      _ShortcutStep('شغّله في الخلفية', 'أوقف Show When Run حتى الإضافة تتم بدون إزعاج.', Icons.volume_off_rounded),
      _ShortcutStep('احفظ الاختصار', 'اضغط Done. بعدها أي رسالة بنك مطابقة هتتحول لعملية داخل مالي.', Icons.check_circle_outline_rounded),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final steps = _getSteps(context);
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

/// يفتح دليل اختصار آبل كـ bottom sheet قابل للسحب لأسفل.
Future<void> showIosShortcutSheet(BuildContext context) {
  final c = context.colors;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    backgroundColor: c.bg,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
    ),
    constraints: BoxConstraints(
      maxHeight: MediaQuery.of(context).size.height * 0.9,
    ),
    builder: (_) => const _IosShortcutSheet(),
  );
}

class _IosShortcutSheet extends StatelessWidget {
  const _IosShortcutSheet();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        0,
        AppSpacing.gutter,
        AppSpacing.gutter,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
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
                  child: const Icon(
                    Icons.ios_share_rounded,
                    color: Colors.white,
                    size: 30,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  context.l10n.setupAppleShortcut,
                  textAlign: TextAlign.center,
                  style: _alex(22, FontWeight.w800, 1.2, Colors.white),
                ),
                const SizedBox(height: 8),
                Text(
                  context.l10n.autoTrackingSubtitleIos,
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
          const GlassCard(
            padding: EdgeInsets.all(18),
            child: IosShortcutGuide(),
          ),
          const SizedBox(height: 18),
        ],
      ),
    );
  }
}
