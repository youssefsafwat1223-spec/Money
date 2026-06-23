import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../features/common/app_sheet_scaffold.dart';
import '../transactions/manual_transaction_sheet.dart';
import 'manual_paste_screen.dart';

Future<void> showCaptureEntrySheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (_) => AppSheetScaffold(
      title: 'طريقة الإدخال',
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ActionTile(
            icon: Icons.edit_note_rounded,
            title: 'إضافة عملية يدويًا',
            subtitle: 'اكتب المبلغ والتصنيف والتاريخ في أقل من دقيقة.',
            onTap: () {
              Navigator.of(context).pop();
              ManualTransactionSheet.show(context);
            },
          ),
          const SizedBox(height: AppSpacing.s3),
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
              title: 'شارك رسالة من تطبيق الرسائل',
              subtitle: 'افتح رسالة البنك، اضغط مشاركة، واختر مالي لإضافتها بدون أذونات SMS.',
              onTap: () {
                Navigator.of(context).pop();
                ManualPasteScreen.showSheet(context);
              },
            ),
          ],
        ],
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
