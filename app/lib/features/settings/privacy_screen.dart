import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/privacy/data_wipe_service.dart';
import '../../core/session/app_session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../onboarding/widgets/neon_illustration.dart';
import 'data_export.dart';

class PrivacyScreen extends ConsumerWidget {
  const PrivacyScreen({super.key});

  static final Uri _privacyPolicyUrl =
      Uri.parse('https://mali.youssefsafwat.com/privacy');
  static final Uri _termsUrl =
      Uri.parse('https://mali.youssefsafwat.com/terms');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    return Scaffold(
      backgroundColor: c.bg,
      body: Column(
        children: [
          const _PrivacyHeader(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(AppSpacing.gutter),
              children: [
                const SizedBox(height: AppSpacing.s4),
                const Center(
                  child: NeonIllustration(
                    icon: Icons.shield_rounded,
                    size: 140,
                  ),
                ),
                const SizedBox(height: AppSpacing.s6),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.description_outlined),
                  title: const Text('سياسة الخصوصية'),
                  onTap: () => _openExternalLink(context, _privacyPolicyUrl),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.gavel_outlined),
                  title: const Text('الشروط والأحكام'),
                  onTap: () => _openExternalLink(context, _termsUrl),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.download_outlined),
                  title: const Text('تصدير بياناتي'),
                  onTap: () => exportTransactionsCsv(context, ref),
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
          ),
        ],
      ),
    );
  }

  Future<void> _openExternalLink(BuildContext context, Uri url) async {
    final opened = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذر فتح الرابط الآن.')),
      );
    }
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
    if (context.mounted) context.go('/welcome');
  }
}

class _PrivacyHeader extends StatelessWidget {
  const _PrivacyHeader();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        64,
        AppSpacing.gutter,
        AppSpacing.s5,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            c.cta.withValues(alpha: 0.12),
            c.bg,
          ],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (Navigator.of(context).canPop()) ...[
                BackButton(color: c.textMain),
                const SizedBox(width: AppSpacing.s2),
              ],
              Expanded(
                child: Text(
                  'الخصوصية والبيانات',
                  style: AppTypography.title1(c.textMain)
                      .copyWith(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'بياناتك المالية على جهازك. النسخ الاحتياطي اختياري ومشفّر E2E. نجمع إحصاءات مجهولة فقط.',
            style: AppTypography.caption(c.textMuted),
          ),
        ],
      ),
    );
  }
}
