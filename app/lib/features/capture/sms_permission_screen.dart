import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';
import 'manual_paste_screen.dart';

class SmsPermissionScreen extends StatefulWidget {
  const SmsPermissionScreen({super.key});

  static Future<void> showSheet(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const FractionallySizedBox(
        heightFactor: 0.82,
        child: SmsPermissionScreen(),
      ),
    );
  }

  @override
  State<SmsPermissionScreen> createState() => _SmsPermissionScreenState();
}

class _SmsPermissionScreenState extends State<SmsPermissionScreen> {
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(28),
        ),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter,
              AppSpacing.s3,
              AppSpacing.gutter,
              AppSpacing.s6,
            ),
            decoration: BoxDecoration(
              color: isDark ? c.surface.withValues(alpha: 0.9) : Colors.white.withValues(alpha: 0.92),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(28),
              ),
              border: Border.all(
                color: Colors.white.withValues(alpha: isDark ? 0.08 : 0.3),
                width: 1.5,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 44,
                    height: 5,
                    decoration: BoxDecoration(
                      color: c.textLight.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: IconButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      icon: const Icon(Icons.close),
                      style: IconButton.styleFrom(
                        backgroundColor: c.surface.withValues(alpha: 0.4),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.s3),
                CircleAvatar(
                  radius: 34,
                  backgroundColor: c.primary.withValues(alpha: 0.12),
                  child: Icon(
                    AppLucideIcons.receipt,
                    color: c.primary,
                    size: 28,
                  ),
                ),
                const SizedBox(height: AppSpacing.s4),
                Text(
                  'شارك رسالة البنك مع قرش',
                  textAlign: TextAlign.center,
                  style: AppTypography.title1(c.textMain),
                ),
                const SizedBox(height: AppSpacing.s2),
                Text(
                  'بدون إذن قراءة SMS: افتح رسالة البنك، اضغط مشاركة، واختر قرش. سنحلّل النص على جهازك فقط.',
                  textAlign: TextAlign.center,
                  style: AppTypography.callout(c.textLight),
                ),
                const SizedBox(height: AppSpacing.s5),
                Container(
                  padding: const EdgeInsets.all(AppSpacing.s4),
                  decoration: BoxDecoration(
                    color: isDark ? Colors.white.withValues(alpha: 0.05) : c.surface2.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: isDark ? 0.08 : 0.4),
                    ),
                  ),
                  child: Column(
                    children: [
                      Text(
                        'مثال: «شراء 45 ريال لدى BURGER BOUTIQUE»',
                        textAlign: TextAlign.center,
                        style: AppTypography.bodyStrong(c.textMain),
                      ),
                      const SizedBox(height: AppSpacing.s2),
                      Text(
                        'لو لم يظهر زر المشاركة في تطبيق الرسائل، استخدم اللصق اليدوي كبديل سريع.',
                        textAlign: TextAlign.center,
                        style: AppTypography.callout(c.textLight),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                SizedBox(
                  height: 52,
                  child: FilledButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      ManualPasteScreen.showSheet(context);
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: c.cta,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: Text(
                      'لصق رسالة يدويًا',
                      style: AppTypography.bodyStrong(Colors.white),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.s2),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(
                    'لاحقًا، ألصق يدويًا',
                    style: AppTypography.bodyStrong(c.textLight),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
