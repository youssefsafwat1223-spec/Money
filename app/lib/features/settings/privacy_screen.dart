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
import '../../domain/entities/supporting_entities.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../onboarding/widgets/neon_illustration.dart';
import 'settings_providers.dart';
import '../../core/theme/widgets/app_toast.dart';

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
                _PrivacyCard(
                  icon: Icons.description_outlined,
                  title: 'سياسة الخصوصية',
                  onTap: () => _openExternalLink(context, _privacyPolicyUrl),
                ),
                _PrivacyCard(
                  icon: Icons.gavel_outlined,
                  title: 'الشروط والأحكام',
                  onTap: () => _openExternalLink(context, _termsUrl),
                ),
                _PrivacyCard(
                  icon: Icons.swap_vert_circle_outlined,
                  title: 'نقل واستيراد بياناتي',
                  onTap: () => context.push('/data-transfer'),
                ),
                const SizedBox(height: AppSpacing.s5),
                Text('معالجة البيانات',
                    style: AppTypography.subhead(c.textMain)),
                const SizedBox(height: AppSpacing.s2),
                ref.watch(userSettingsProvider).maybeWhen(
                      data: (settings) => Column(
                        children: [
                          _ConsentSwitchCard(
                            icon: Icons.cloud_outlined,
                            title: 'المعالجة السحابية والمزامنة',
                            subtitle:
                                'رفع رسائل البنك الملتقطة ومزامنة بياناتك مع خوادمنا. '
                                'إيقافها يعطّل الالتقاط التلقائي والمزامنة، ويُبقي الإدخال اليدوي يعمل على جهازك.',
                            value: settings.cloudProcessingEnabled,
                            onChanged: (value) => _setConsent(
                              ref,
                              settings.copyWith(cloudProcessingEnabled: value),
                            ),
                          ),
                          _ConsentSwitchCard(
                            icon: Icons.auto_awesome_outlined,
                            title: 'التحليل بالذكاء الاصطناعي',
                            subtitle:
                                'استخدام نماذج ذكاء اصطناعي سحابية لفهم الرسائل غير المألوفة وتصنيفها. '
                                'إيقافه يقتصر التحليل على القواعد المحلية.',
                            value: settings.aiConsentGranted,
                            onChanged: (value) => _setConsent(
                              ref,
                              settings.copyWith(aiConsentGranted: value),
                            ),
                          ),
                        ],
                      ),
                      orElse: () => const SizedBox.shrink(),
                    ),
                const SizedBox(height: AppSpacing.s5),
                Text('منطقة خطرة', style: AppTypography.subhead(c.danger)),
                const SizedBox(height: AppSpacing.s2),
                ref.watch(accountDeletionStatusProvider).maybeWhen(
                      data: (status) => status.isPending
                          ? _PendingDeletionCard(
                              scheduledAt: status.scheduledAt!,
                              onCancel: () =>
                                  _confirmCancelDeletion(context, ref),
                            )
                          : const SizedBox.shrink(),
                      orElse: () => const SizedBox.shrink(),
                    ),
                const SizedBox(height: AppSpacing.s2),
                _PrivacyCard(
                  icon: Icons.delete_outline,
                  title: 'حذف الحساب وكل بياناتي',
                  onTap: () => _confirmDelete(context, ref),
                  danger: true,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Persists a consent change and pushes the new state to the native capture
  /// layer immediately (the iOS extension reads it from the App Group), so
  /// revoking cloud processing takes effect without waiting for a restart.
  Future<void> _setConsent(
    WidgetRef ref,
    UserSettingsEntity updated,
  ) async {
    await ref.read(userSettingsRepositoryProvider).saveSettings(updated);
    ref.invalidate(userSettingsProvider);
    try {
      await ref
          .read(captureDeviceRegistrationServiceProvider)
          .syncNativeState();
    } catch (_) {
      // Best-effort: the startup sync re-applies the stored value anyway.
    }
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
        AppToast.show(context, message);
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
      AppToast.show(context, message);
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
            'رسائل البنك التي تشاركها عبر الاختصار تُعالج بنص مُعقّم على خادم قرش وبمساعدة الذكاء الاصطناعي. ويمكنك تصدير بياناتك المالية أو استيرادها من شاشة نقل البيانات.',
            style: AppTypography.caption(c.textMuted),
          ),
        ],
      ),
    );
  }
}

/// Revocable data-processing consent switch (MALI-001) — same card language
/// as [_PrivacyCard], with an honest subtitle describing what leaves the
/// device and what stops when the switch is off.
class _ConsentSwitchCard extends StatelessWidget {
  const _ConsentSwitchCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: c.surface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        child: SwitchListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          secondary: Icon(icon, color: c.primary),
          title: Text(title, style: AppTypography.bodyStrong(c.textMain)),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(subtitle, style: AppTypography.caption(c.textLight)),
          ),
          value: value,
          activeThumbColor: c.onCta,
          activeTrackColor: c.cta,
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _PrivacyCard extends StatelessWidget {
  const _PrivacyCard({
    required this.icon,
    required this.title,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = danger ? c.danger : c.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: danger ? c.danger.withValues(alpha: 0.05) : c.surface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color:
                danger ? c.danger.withValues(alpha: 0.3) : Colors.transparent,
          ),
        ),
        child: ListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          leading: Icon(icon, color: color),
          title: Text(
            title,
            style: AppTypography.bodyStrong(danger ? c.danger : c.textMain),
          ),
          trailing: Icon(Icons.chevron_left_rounded, color: c.textMuted),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          onTap: onTap,
        ),
      ),
    );
  }
}
