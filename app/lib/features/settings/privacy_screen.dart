import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;
import 'package:url_launcher/url_launcher.dart';

import '../../core/backend/supabase_config.dart';
import '../../core/di/app_providers.dart';
import '../../core/privacy/data_wipe_service.dart';
import '../../core/session/app_session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../domain/errors/repo_exceptions.dart';
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
                Text('منطقة خطرة', style: AppTypography.subhead(c.danger)),
                const SizedBox(height: AppSpacing.s2),
                ref.watch(accountDeletionStatusProvider).maybeWhen(
                      data: (status) => status.isPending
                          ? _PendingDeletionCard(
                              scheduledAt: status.scheduledAt!,
                              onCancel: () => _confirmCancelDeletion(context, ref),
                            )
                          : const SizedBox.shrink(),
                      orElse: () => const SizedBox.shrink(),
                    ),
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
        title: const Text('حذف الحساب؟'),
        content: const Text(
            'سيتم جدولة حذف حسابك وكل بياناتك (العمليات، الأهداف، الميزانيات، النسخ الاحتياطي) '
            'نهائياً بعد 30 يوماً. يمكنك التراجع عن الحذف خلال هذه المدة من نفس الشاشة قبل تسجيل '
            'الدخول مرة أخرى. سيتم تسجيل خروجك من هذا الجهاز الآن.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('حذف الحساب')),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await ref.read(accountDeletionServiceProvider).requestDeletion();
    } catch (error) {
      if (context.mounted) {
        final message = error is RepoException
            ? repoExceptionMessage(error)
            : 'تعذّر جدولة الحذف الآن. حاول مجدداً.';
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      }
      return;
    }

    await ref.read(dataWipeServiceProvider).wipeAll();
    await AppSession.instance.wipeAndReset();
    if (SupabaseConfig.isConfigured) {
      try {
        await supabase.Supabase.instance.client.auth.signOut();
      } catch (_) {
        // Local wipe/reset above already protects the device even if the
        // network sign-out fails.
      }
    }
    if (context.mounted) context.go('/welcome');
  }

  Future<void> _confirmCancelDeletion(
      BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إلغاء حذف الحساب؟'),
        content: const Text('سيبقى حسابك وبياناتك كما هي.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('تراجع')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('إلغاء الحذف')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(accountDeletionServiceProvider).cancelDeletion();
      ref.invalidate(accountDeletionStatusProvider);
    } catch (error) {
      if (!context.mounted) return;
      final message = error is RepoException
          ? repoExceptionMessage(error)
          : 'تعذّر إلغاء الحذف الآن. حاول مجدداً.';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }
}

class _PendingDeletionCard extends StatelessWidget {
  const _PendingDeletionCard({
    required this.scheduledAt,
    required this.onCancel,
  });

  final DateTime scheduledAt;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final local = scheduledAt.toLocal();
    final label =
        '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s3),
      margin: const EdgeInsets.only(bottom: AppSpacing.s3),
      decoration: BoxDecoration(
        color: c.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.danger.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('حسابك مجدول للحذف بتاريخ $label',
              style: AppTypography.bodyStrong(c.danger)),
          const SizedBox(height: AppSpacing.s2),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              onPressed: onCancel,
              child: const Text('إلغاء الحذف'),
            ),
          ),
        ],
      ),
    );
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
