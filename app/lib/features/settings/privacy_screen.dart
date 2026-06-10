import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/privacy/data_wipe_service.dart';
import '../../core/session/app_session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';

class PrivacyScreen extends ConsumerWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    return Scaffold(
      appBar: AppBar(title: const Text('الخصوصية والبيانات')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.gutter),
        children: [
          Row(
            children: [
              Icon(Icons.lock_outline, color: c.primary),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Text(
                  'بياناتك المالية على جهازك. النسخ الاحتياطي اختياري ومشفّر E2E. نجمع إحصاءات مجهولة فقط.',
                  style: AppTypography.body(c.textLight),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s5),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.description_outlined),
            title: const Text('سياسة الخصوصية'),
            onTap: () {},
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.download_outlined),
            title: const Text('تصدير بياناتي'),
            onTap: () => ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('التصدير سيتوفّر قريباً.')),
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.cloud_outlined),
            title: const Text('النسخ الاحتياطي'),
            onTap: () => context.push('/backup'),
          ),
          const SizedBox(height: AppSpacing.s5),
          Text('منطقة خطرة',
              style: AppTypography.subhead(c.danger)),
          const SizedBox(height: AppSpacing.s2),
          OutlinedButton.icon(
            onPressed: () => _confirmDelete(context, ref),
            icon: Icon(Icons.delete_outline, color: c.danger),
            label: Text('حذف الحساب وكل بياناتي',
                style: TextStyle(color: c.danger)),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: c.danger),
              minimumSize: const Size.fromHeight(52),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف كل بياناتي؟'),
        content: const Text(
            'سيُحذف الحساب وكل العمليات والأهداف نهائياً من هذا الجهاز. لا يمكن التراجع.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('حذف')),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(dataWipeServiceProvider).wipeAll();
    await AppSession.instance.wipeAndReset();
    if (context.mounted) context.go('/onboarding');
  }
}
