import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:go_router/go_router.dart';

import '../../core/di/app_providers.dart';
import '../../core/session/app_session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/l10n_ext.dart';
import '../../core/theme/app_spacing.dart';
import 'widgets/premium_ui.dart';

TextStyle _alex(double size, FontWeight weight, double height, Color color,
    {bool tabular = false}) {
  return GoogleFonts.inter(
    fontSize: size,
    fontWeight: weight,
    height: height,
    color: color,
    fontFeatures: tabular ? const [FontFeature.tabularFigures()] : null,
  ).copyWith(
    fontFamilyFallback: [
      GoogleFonts.ibmPlexSansArabic().fontFamily!,
      GoogleFonts.alexandria().fontFamily!,
    ],
  );
}

const String _defaultShortcutCurrency = 'SAR';

String _shortcutCurrency(String? currency) {
  final normalized = currency?.trim().toUpperCase();
  if (normalized == null || normalized.isEmpty) return _defaultShortcutCurrency;
  return normalized;
}

class IosShortcutScreen extends ConsumerWidget {
  const IosShortcutScreen({super.key});

  static List<_Step> _getSteps(BuildContext context, String currencyCode) {
    final locale = Localizations.localeOf(context).languageCode;
    if (locale == 'en') {
      return [
        const _Step(
            'Delete Old',
            'Open Shortcuts app and go to Automation tab. If there is an old automation for the app, delete it.',
            Icons.delete_outline_rounded),
        const _Step(
            'New (+)',
            'Press New Automation (+) and scroll down to "Message".',
            Icons.add_circle_outline_rounded),
        _Step(
            'Filter Messages',
            'Press "Message Contents" and type currency code e.g. $currencyCode.',
            Icons.filter_alt_outlined),
        const _Step('Run Immediately',
            'Enable "Run Immediately" and press Next.', Icons.bolt_rounded),
        const _Step('Blank Automation', 'Press "New Blank Automation".',
            Icons.insert_drive_file_outlined),
        const _Step(
            'Send to App',
            'Search for "Process Bank SMS". In SMS Text, choose "Shortcut Input".',
            Icons.send_rounded),
        const _Step(
            'Final shape',
            'It should show: Receive messages as input, then Process Bank SMS with SMS Text = Shortcut Input.',
            Icons.volume_off_rounded),
        const _Step('Save', 'Press Save in the top and setup is completed.',
            Icons.check_circle_outline_rounded),
      ];
    }
    return [
      const _Step(
          'احذف القديم',
          'افتح تطبيق Shortcuts وروح لتبويب Automation. لو فيه Automation قديم للتطبيق، احذفه.',
          Icons.delete_outline_rounded),
      const _Step(
          'جديد (+)',
          'اضغط New Automation (+) ومرّر للأسفل حتى تلقى «Message».',
          Icons.add_circle_outline_rounded),
      _Step(
          'حدّد الرسائل',
          'اضغط على «Message Contents» واكتب رمز العملة مثل $currencyCode.',
          Icons.filter_alt_outlined),
      const _Step('بدون تأكيد', 'فعّل «Run Immediately» واضغط Next.',
          Icons.bolt_rounded),
      const _Step('اختصار فارغ', 'اضغط «New Blank Automation».',
          Icons.insert_drive_file_outlined),
      const _Step(
          'إرسال للتطبيق',
          'ابحث عن «Process Bank SMS». في SMS Text اختَر «Shortcut Input».',
          Icons.send_rounded),
      const _Step(
          'الشكل النهائي',
          'لازم يظهر: Receive messages as input ثم Process Bank SMS وفيها SMS Text = Shortcut Input.',
          Icons.volume_off_rounded),
      const _Step('حفظ', 'اضغط زر الحفظ في الأعلى وتم الإعداد.',
          Icons.check_circle_outline_rounded),
    ];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final currencyCode =
        _shortcutCurrency(ref.watch(baseCurrencyProvider).valueOrNull);
    final steps = _getSteps(context, currencyCode);
    return PremiumBackground(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.gutter, vertical: 8.0),
            child: Row(
              children: [
                Container(
                  decoration: BoxDecoration(
                    color: c.surface.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    onPressed: () => context.pop(),
                    icon: Icon(
                      Directionality.of(context) == TextDirection.rtl
                          ? Icons.arrow_forward_rounded
                          : Icons.arrow_back_rounded,
                      color: c.textMain,
                      size: 20,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding:
                  const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
              children: [
                Center(
                  child: GlowingIcon(
                    icon: Icons.apple_rounded,
                    color: c.primary,
                    size: 40,
                  ),
                ),
                const SizedBox(height: 20),
                Text(context.l10n.appleSecuritySteps,
                    textAlign: TextAlign.center,
                    style: _alex(24, FontWeight.w800, 1.2, c.textMain)),
                const SizedBox(height: 8),
                Text(
                  context.l10n.iosShortcutSubtitle,
                  textAlign: TextAlign.center,
                  style: _alex(13, FontWeight.w500, 1.5, c.textLight),
                ),
                const SizedBox(height: 32),
                Text(context.l10n.stepsLabel,
                    style: _alex(15, FontWeight.w800, 1.2, c.textMain)),
                const SizedBox(height: 20),
                GlassCard(
                  padding: const EdgeInsets.all(20),
                  child: ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: steps.length,
                    separatorBuilder: (context, index) => Padding(
                      padding:
                          const EdgeInsets.only(right: 14.0, top: 4, bottom: 4),
                      child: Container(
                        height: 16,
                        width: 1.5,
                        color: c.border.withValues(alpha: 0.3),
                        alignment: Alignment.centerRight,
                      ),
                    ),
                    itemBuilder: (context, index) {
                      final step = steps[index];
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
                            child: Text('${index + 1}',
                                style: _alex(
                                    12, FontWeight.w800, 1.0, Colors.white)),
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
                                      Text(step.title,
                                          style: _alex(14, FontWeight.w800, 1.2,
                                              c.textMain)),
                                      const SizedBox(width: 8),
                                      Icon(step.icon,
                                          color: c.textLight, size: 14),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(step.body,
                                      style: _alex(12, FontWeight.w500, 1.5,
                                          c.textLight)),
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
                      Icon(Icons.currency_exchange_rounded,
                          size: 24, color: c.accent),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(context.l10n.multipleCurrenciesQuestion,
                                style:
                                    _alex(14, FontWeight.w800, 1.2, c.accent)),
                            const SizedBox(height: 4),
                            Text(
                              context.l10n.multipleCurrenciesDesc,
                              style: _alex(12, FontWeight.w600, 1.5,
                                  c.accent.withValues(alpha: 0.8)),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 32),
                SizedBox(
                  height: 52,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: maliPrimaryActionGradient(context),
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: c.primary.withValues(alpha: 0.22),
                          blurRadius: 14,
                          offset: const Offset(0, 5),
                        ),
                      ],
                    ),
                    child: ElevatedButton(
                      onPressed: () async {
                        await AppSession.instance.finishOnboarding();
                        if (context.mounted) context.go('/');
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.transparent,
                        shadowColor: Colors.transparent,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16)),
                      ),
                      child: Text(
                        'تم، ابدأ استخدام قرش',
                        style: _alex(14, FontWeight.w800, 1.2,
                            maliPrimaryActionForeground(context)),
                      ),
                    ),
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
