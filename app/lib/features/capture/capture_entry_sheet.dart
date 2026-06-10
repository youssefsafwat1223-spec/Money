import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';

Future<void> showCaptureEntrySheet(BuildContext context) {
  final c = context.colors;
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (_) => Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        AppSpacing.s3,
        AppSpacing.gutter,
        AppSpacing.s6,
      ),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: c.border,
              borderRadius: BorderRadius.circular(2),
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
              context.push('/paste');
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
                context.push('/capture/sms-permission');
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
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.s3),
        decoration: BoxDecoration(
          color: c.surface2,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: c.border),
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
            Icon(AppLucideIcons.arrowLeftRight, color: c.textLight),
          ],
        ),
      ),
    );
  }
}
