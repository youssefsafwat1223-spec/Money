import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_assets.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../data/catalog/catalog_daos.dart';
import '../../domain/entities/engagement_entities.dart';
import '../common/widgets.dart';
import '../settings/settings_providers.dart';

class AnnouncementsScreen extends ConsumerWidget {
  const AnnouncementsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final announcementsAsync = ref.watch(activeAnnouncementsProvider);
    final campaignsAsync = ref.watch(activeDashboardCampaignsProvider);
    final prefsAsync = ref.watch(notificationPreferencesProvider);
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
                  Text('مركز رسائل قرش',
                      style: AppTypography.headline(c.textPrimary)),
                  const SizedBox(height: 2),
                  Text(
                    'تاريخ إشعارات قرش، الحملات، والإعلانات في مكان واحد.',
                    style: AppTypography.footnote(c.textSecondary),
                  ),
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
      body: prefsAsync.when(
        loading: () => const AppLoadingState(label: 'تحميل مركز الرسائل...'),
        error: (_, __) => AppErrorState(
          title: 'تعذر تحميل الرسائل',
          description: 'حاول مرة أخرى بعد لحظات.',
          retryLabel: 'إعادة المحاولة',
          onRetry: () => ref.invalidate(notificationPreferencesProvider),
        ),
        data: (prefs) {
          final history = prefs.inboxState.history;
          final announcements = (announcementsAsync.valueOrNull ?? [])
              .where((item) => !item.isForceUpdate)
              .toList();
          final campaigns = campaignsAsync.valueOrNull ?? const [];
          final items = <_MessageItem>[
            ...history.map(_MessageItem.fromHistory),
            ...campaigns.map(_MessageItem.fromCampaign),
            ...announcements.map(_MessageItem.fromAnnouncement),
          ]..sort((a, b) => b.sortAt.compareTo(a.sortAt));

          if (items.isEmpty) {
            return const AppEmptyState(
              icon: Icons.notifications_none_rounded,
              title: 'لا توجد رسائل بعد',
              subtitle:
                  'أي إشعار من قرش أو إعلان من الإدارة هيظهر هنا تلقائياً.',
            );
          }

          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(activeAnnouncementsProvider);
              ref.invalidate(activeDashboardCampaignsProvider);
              ref.invalidate(notificationPreferencesProvider);
            },
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.gutter,
                AppSpacing.s2,
                AppSpacing.gutter,
                120,
              ),
              itemCount: items.length,
              separatorBuilder: (_, __) =>
                  const SizedBox(height: AppSpacing.s3),
              itemBuilder: (context, index) => _MessageCard(item: items[index]),
            ),
          );
        },
      ),
    );
  }
}

class _MessageCard extends ConsumerWidget {
  const _MessageCard({required this.item});

  final _MessageItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
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
                  color: item.accent(c).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: Icon(item.icon, color: item.accent(c)),
              ),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.badge, style: AppTypography.caption(c.textLight)),
                    const SizedBox(height: 3),
                    Text(item.title,
                        style: AppTypography.bodyStrong(c.textPrimary)),
                    if (item.body.trim().isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(item.body,
                          style: AppTypography.callout(c.textSecondary)),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s3),
          Row(
            children: [
              if (item.actionLabel != null)
                FilledButton(
                  onPressed: () => _openAction(context, item),
                  child: Text(item.actionLabel!),
                ),
              const Spacer(),
              if (item.dismissible)
                TextButton(
                  onPressed: () => _dismiss(ref, item),
                  child: const Text('إخفاء'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _dismiss(WidgetRef ref, _MessageItem item) async {
    if (item.source == _MessageSource.announcement) {
      await ref.read(announcementServiceProvider).dismiss(item.id);
      ref.invalidate(activeAnnouncementsProvider);
      return;
    }
    await ref.read(growthCampaignServiceProvider).dismiss(item.id);
    ref.invalidate(activeDashboardCampaignsProvider);
    ref.invalidate(notificationPreferencesProvider);
  }

  void _openAction(BuildContext context, _MessageItem item) {
    final route = item.route?.trim();
    if (route != null && route.isNotEmpty) {
      context.push(route);
      return;
    }
    final url = item.url?.trim();
    if (url != null && url.isNotEmpty) {
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    }
  }
}

enum _MessageSource { history, campaign, announcement }

class _MessageItem {
  const _MessageItem({
    required this.id,
    required this.source,
    required this.title,
    required this.body,
    required this.badge,
    required this.sortAt,
    required this.icon,
    required this.accent,
    this.route,
    this.url,
    this.actionLabel,
    this.dismissible = false,
  });

  final String id;
  final _MessageSource source;
  final String title;
  final String body;
  final String badge;
  final DateTime sortAt;
  final IconData icon;
  final Color Function(AppColors c) accent;
  final String? route;
  final String? url;
  final String? actionLabel;
  final bool dismissible;

  static _MessageItem fromHistory(NotificationHistoryEntry entry) {
    return _MessageItem(
      id: entry.id,
      source: _MessageSource.history,
      title: entry.title,
      body: entry.body,
      badge: 'إشعار مرسل',
      sortAt: entry.sentAt,
      icon: Icons.notifications_active_outlined,
      accent: (c) => c.primary,
      route: entry.route,
      actionLabel: entry.route == null ? null : 'فتح',
      dismissible: true,
    );
  }

  static _MessageItem fromCampaign(RemoteGrowthCampaign campaign) {
    return _MessageItem(
      id: campaign.id,
      source: _MessageSource.campaign,
      title: campaign.titleAr,
      body: campaign.bodyAr ?? '',
      badge: 'حملة داخل التطبيق',
      sortAt: campaign.validFrom,
      icon: Icons.campaign_outlined,
      accent: (c) => c.cta,
      route: campaign.actionRoute,
      url: campaign.actionUrl,
      actionLabel: campaign.actionLabelAr,
      dismissible: campaign.isDismissible,
    );
  }

  static _MessageItem fromAnnouncement(RemoteAnnouncement announcement) {
    return _MessageItem(
      id: announcement.id,
      source: _MessageSource.announcement,
      title: announcement.titleAr,
      body: announcement.bodyAr ?? '',
      badge: 'إعلان من قرش',
      sortAt: announcement.validFrom,
      icon: Icons.new_releases_outlined,
      accent: (c) => switch (announcement.severity) {
        'warning' => c.warning,
        'maintenance' => c.accent,
        _ => c.cta,
      },
      url: announcement.actionUrl,
      actionLabel: announcement.actionLabelAr,
      dismissible: announcement.isDismissible,
    );
  }
}
