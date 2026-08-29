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
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/formatters.dart';

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
            Image.asset(AppAssets.getCoin(context), width: 42, height: 42),
            const SizedBox(width: AppSpacing.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'مركز رسائل قرش',
                    // Mockup `.tophead .h1`: 24px w600, tight tracking.
                    style: AppTypography.calmTitle(c.textPrimary)
                        .copyWith(fontSize: 24, letterSpacing: -0.5),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'تاريخ إشعارات قرش، الحملات، والإعلانات في مكان واحد.',
                    // Mockup `.hsub`: 13px secondary.
                    style: AppTypography.caption(c.textSecondary)
                        .copyWith(fontSize: 13, fontWeight: FontWeight.w400),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'إغلاق',
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(AppLucideIcons.x),
            ),
          ],
        ),
      ),
      body: prefsAsync.when(
        skipLoadingOnReload: true,
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
              icon: AppLucideIcons.bell,
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
                    // UX-031 — the screen calls itself «تاريخ إشعارات قرش» and
                    // sorts every row by `sortAt`, and then showed no dates at
                    // all: a history in which nothing is dated. The date is
                    // stated beside the badge because the two together are what
                    // make a row identifiable — «إشعار مرسل» alone does not
                    // distinguish this month's budget warning from last
                    // month's.
                    Row(
                      children: [
                        Flexible(
                          child: Text(item.badge,
                              style: AppTypography.caption(c.textLight),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                        ),
                        Text(' · ${item.dateLabel(context)}',
                            style: AppTypography.caption(c.textLight)),
                      ],
                    ),
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
            mainAxisSize: MainAxisSize.max,
            children: [
              if (item.actionLabel != null)
                Flexible(
                  child: FilledButton(
                    onPressed: () => _openAction(context, item),
                    child: Text(item.actionLabel!),
                  ),
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

  /// UX-031 — the date, said accurately for what each source actually records.
  ///
  /// `sortAt` is not one kind of instant. For a delivered notification it is
  /// `sentAt` — genuinely when the user received it. For a campaign or an
  /// announcement it is `validFrom` — when the item BEGAN being shown, which is
  /// not the same claim. Printing one undifferentiated timestamp would date a
  /// server-side publication window as though it were a delivery.
  String dateLabel(BuildContext context) {
    final date = Formatters.dateGroupLabel(sortAt, context);
    return switch (source) {
      _MessageSource.history => date,
      _MessageSource.campaign ||
      _MessageSource.announcement =>
        'من $date',
    };
  }

  static _MessageItem fromHistory(NotificationHistoryEntry entry) {
    return _MessageItem(
      id: entry.id,
      source: _MessageSource.history,
      title: entry.title,
      body: entry.body,
      badge: 'إشعار مرسل',
      sortAt: entry.sentAt,
      icon: AppLucideIcons.bellRing,
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
      icon: AppLucideIcons.megaphone,
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
      icon: AppLucideIcons.badgeAlert,
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
