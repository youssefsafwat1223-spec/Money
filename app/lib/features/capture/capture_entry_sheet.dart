import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';
import 'manual_paste_screen.dart';
import 'sms_permission_screen.dart';

Future<void> showCaptureEntrySheet(BuildContext context) {
  final c = context.colors;
  final isDark = Theme.of(context).brightness == Brightness.dark;

  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (_) => Directionality(
      textDirection: TextDirection.rtl,
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
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
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              border: Border.all(
                color: Colors.white.withValues(alpha: isDark ? 0.08 : 0.3),
                width: 1.5,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 44,
                  height: 5,
                  decoration: BoxDecoration(
                    color: c.textLight.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
                const SizedBox(height: AppSpacing.s4),
                Text('طريقة الإدخال', style: AppTypography.title2(c.textMain)),
                const SizedBox(height: AppSpacing.s4),
                _ActionTile(
                  icon: AppLucideIcons.clipboardPaste,
                  title: 'ألصق رسالة بنك',
                  subtitle: 'المسار اليدوي الحالي لإضافة عملية جديدة.',
                  onTap: () {
                    Navigator.of(context).pop();
                    ManualPasteScreen.showSheet(context);
                  },
                ),
                if (Platform.isAndroid) ...[
                  const SizedBox(height: AppSpacing.s3),
                  _ActionTile(
                    icon: AppLucideIcons.receipt,
                    title: 'فعّل قراءة الرسائل',
                    subtitle: 'نقطة دخول مؤقتة حتى ربط onboarding في Sprint 5.',
                    onTap: () {
                      Navigator.of(context).pop();
                      SmsPermissionScreen.showSheet(context);
                    },
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.s3),
        decoration: BoxDecoration(
          color: isDark ? Colors.white.withValues(alpha: 0.05) : c.surface2.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: Colors.white.withValues(alpha: isDark ? 0.08 : 0.4),
          ),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 22,
              backgroundColor: c.primary.withValues(alpha: 0.12),
              child: Icon(icon, color: c.primary, size: 20),
            ),
            const SizedBox(width: AppSpacing.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: AppTypography.bodyStrong(c.textMain)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: AppTypography.caption(c.textLight)),
                ],
              ),
            ),
            Icon(Icons.chevron_left_rounded, color: c.textLight, size: 20),
          ],
        ),
      ),
    );
  }
}

