import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../features/common/app_sheet_scaffold.dart';
import '../transactions/manual_transaction_sheet.dart';
import 'manual_paste_screen.dart';

Future<void> showCaptureEntrySheet(BuildContext context) {
  // لو الكيبورد كان مفتوح (جاي من خانة البحث مثلًا) فمساحة الشيت بتتاكل
  // بالكامل والمحتوى بيطفح — نقفله الأول، والمحتوى بيتسكرول لو ضاق.
  FocusManager.instance.primaryFocus?.unfocus();
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (_) => navySheetTheme(AppSheetScaffold(
      title: 'إضافة عملية جديدة',
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
      scrollable: true,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ActionTile(
            icon: AppLucideIcons.clipboardPaste,
            title: 'ألصق رسالة بنك',
            subtitle: 'سيقوم الذكاء الاصطناعي بتصنيفها وإضافتها تلقائياً.',
            isPrimary: true,
            onTap: () {
              Navigator.of(context).pop();
              ManualPasteScreen.showSheet(context);
            },
          ),
          const SizedBox(height: AppSpacing.s3),
          _ActionTile(
            icon: AppLucideIcons.pencil,
            title: 'إضافة يدوية',
            subtitle: 'اكتب تفاصيل العملية بنفسك.',
            isPrimary: false,
            onTap: () {
              Navigator.of(context).pop();
              ManualTransactionSheet.show(context);
            },
          ),
        ],
      ),
    )),
  );
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.isPrimary = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool isPrimary;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.s3),
        decoration: BoxDecoration(
          color: isPrimary
              ? c.cta.withValues(alpha: 0.1)
              : c.surface2.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isPrimary ? c.cta.withValues(alpha: 0.3) : c.border,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isPrimary ? c.cta : c.surface,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon,
                  color: isPrimary ? Colors.white : c.textMain, size: 20),
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
            Icon(AppLucideIcons.chevronLeft, color: c.textLight, size: 20),
          ],
        ),
      ),
    );
  }
}
