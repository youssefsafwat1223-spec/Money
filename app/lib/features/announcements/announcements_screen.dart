import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_assets.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../data/catalog/catalog_daos.dart';
import '../common/widgets.dart';

class AnnouncementsScreen extends ConsumerWidget {
  const AnnouncementsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(activeAnnouncementsProvider);
    final c = context.colors;
    return AppScreenScaffold(
      header: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter,
          AppSpacing.s3,
          AppSpacing.gutter,
          AppSpacing.s2,
        ),
        child: Row(
          children: [
            Image.asset(AppAssets.qirshCoin, width: 42, height: 42),
            const SizedBox(width: AppSpacing.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('الإعلانات والتنبيهات',
                      style: AppTypography.headline(c.textPrimary)),
                  const SizedBox(height: 2),
                  Text('كل رسائل قرش المهمة في مكان واحد.',
                      style: AppTypography.footnote(c.textSecondary)),
                ],
              ),
            ),
            IconButton(
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
      ),
      body: async.when(
        loading: () => const AppLoadingState(label: 'تحميل الإعلانات...'),
        error: (_, __) => AppErrorState(
          title: 'تعذر تحميل الإعلانات',
          description: 'حاول مرة أخرى بعد لحظات.',
          retryLabel: 'إعادة المحاولة',
          onRetry: () => ref.invalidate(activeAnnouncementsProvider),
        ),
        data: (items) {
          final announcements =
              items.where((item) => !item.isForceUpdate).toList();
          if (announcements.isEmpty) {
            return const AppEmptyState(
              icon: Icons.campaign_outlined,
              title: 'لا توجد إعلانات حالياً',
              subtitle: 'أي تحديثات أو عروض مهمة هتظهر هنا.',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter,
              AppSpacing.s2,
              AppSpacing.gutter,
              120,
            ),
            itemCount: announcements.length,
            separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.s3),
            itemBuilder: (context, index) => _AnnouncementCard(
              announcement: announcements[index],
            ),
          );
        },
      ),
    );
  }
}

class _AnnouncementCard extends ConsumerWidget {
  const _AnnouncementCard({required this.announcement});

  final RemoteAnnouncement announcement;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final accent = _accentFor(c, announcement);
    final body = announcement.bodyAr?.trim();
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s4),
      decoration: BoxDecoration(
        color: c.surfaceCard,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 46,
                height: 46,
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: Image.asset(AppAssets.qirshCoin),
              ),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(announcement.titleAr,
                        style: AppTypography.bodyStrong(c.textPrimary)),
                    if (body != null && body.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(body, style: AppTypography.callout(c.textSecondary)),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s3),
          Row(
            children: [
              if (announcement.actionUrl != null &&
                  (announcement.actionLabelAr?.trim().isNotEmpty ?? false))
                FilledButton(
                  onPressed: () => _openAction(announcement.actionUrl!),
                  child: Text(announcement.actionLabelAr!),
                ),
              const Spacer(),
              if (announcement.isDismissible)
                TextButton(
                  onPressed: () => ref
                      .read(announcementServiceProvider)
                      .dismiss(announcement.id)
                      .then((_) => ref.invalidate(activeAnnouncementsProvider)),
                  child: const Text('إخفاء'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Color _accentFor(AppColors c, RemoteAnnouncement a) {
    return switch (a.severity) {
      'warning' => c.warning,
      'maintenance' => c.accent,
      _ => c.cta,
    };
  }

  void _openAction(String url) {
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }
}
