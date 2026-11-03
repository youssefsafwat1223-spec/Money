import 'package:flutter/material.dart';

import 'announcement_text.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/utils/l10n_ext.dart';
import '../../core/privacy/gated_url_launcher.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../common/app_header.dart';
import '../common/app_card.dart';
import '../../core/theme/widgets/qirsh_visuals.dart';
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

    return AppScreenScaffold(
      header: AppHeader(title: context.l10n.annTitle),
      body: prefsAsync.when(
        skipLoadingOnReload: true,
        loading: () => AppLoadingState(label: context.l10n.annLoading),
        error: (_, __) => AppErrorState(
          title: context.l10n.annLoadFailed,
          description: context.l10n.annTryAgainSoon,
          retryLabel: context.l10n.annRetry,
          onRetry: () => ref.invalidate(notificationPreferencesProvider),
        ),
        data: (prefs) {
          final history = prefs.inboxState.history;
          final announcements = (announcementsAsync.valueOrNull ?? [])
              .where((item) => !item.isForceUpdate)
              .toList();
          final campaigns = campaignsAsync.valueOrNull ?? const [];
          final items = <_MessageItem>[
            ...history.map((e) => _MessageItem.fromHistory(context, e)),
            ...campaigns.map((e) => _MessageItem.fromCampaign(context, e)),
            ...announcements.map((e) => _MessageItem.fromAnnouncement(context, e)),
          ]..sort((a, b) => b.sortAt.compareTo(a.sortAt));

          if (items.isEmpty) {
            return AppEmptyState(
              icon: AppLucideIcons.bell,
              illustration: const QirshIllustration(
                  name: 'notifications', width: 220, height: 165),
              title: context.l10n.annEmpty,
              subtitle:
                  context.l10n.annEmptyBody,
            );
          }

          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(activeAnnouncementsProvider);
              ref.invalidate(activeDashboardCampaignsProvider);
              ref.invalidate(notificationPreferencesProvider);
            },
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.gutter, AppSpacing.s2, AppSpacing.gutter, 120,
              ),
              children: [
                AppCard(
                  padding: EdgeInsets.zero,
                  child: Column(children: [
                    for (final item in items) ...[
                      if (item != items.first)
                        Divider(height: 1, indent: 16, endIndent: 16,
                            color: context.colors.border),
                      _MessageCard(item: item),
                    ],
                  ]),
                ),
                const SizedBox(height: 20),
                AppCard(
                  child: Row(children: [
                    Expanded(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(context.l10n.setSettings,
                            style: AppTypography.caption(context.colors.primary)),
                        const SizedBox(height: 4),
                        Text(context.l10n.annPreferencesTitle,
                            style: AppTypography.bodyStrong(context.colors.textPrimary)),
                        TextButton(
                          onPressed: () => context.push('/settings'),
                          style: TextButton.styleFrom(padding: EdgeInsets.zero,
                              alignment: AlignmentDirectional.centerStart),
                          child: Text(context.l10n.annPreferencesAction),
                        ),
                      ],
                    )),
                    const QirshIllustration(name: 'notifications', width: 100, height: 75),
                  ]),
                ),
              ],
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
    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      childrenPadding: const EdgeInsetsDirectional.fromSTEB(16, 0, 16, 12),
      shape: const Border(),
      collapsedShape: const Border(),
      iconColor: c.textMuted,
      collapsedIconColor: c.textMuted,
      maintainState: true,
      leading: Container(
        width: 36, height: 36,
        decoration: BoxDecoration(
          color: item.accent(c).withValues(alpha:
              Theme.of(context).brightness == Brightness.dark ? 0.22 : 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(item.icon, size: 18, color: item.accent(c)),
      ),
      title: Text(item.title,
          style: AppTypography.custom(size: 14.5, weight: FontWeight.w600,
              height: 1.4, color: c.textPrimary)),
      subtitle: Text('${item.dateLabel(context)} · ${item.badge}',
          style: AppTypography.caption(c.textMuted)),
      children: [
        if (item.body.trim().isNotEmpty)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text(item.body,
                style: AppTypography.callout(c.textSecondary)),
          ),
        if (item.actionLabel != null || item.dismissible) ...[
          const SizedBox(height: 8),
          Row(children: [
            if (item.actionLabel != null)
              TextButton.icon(
                onPressed: () => _openAction(context, item),
                icon: const Icon(AppLucideIcons.externalLink, size: 16),
                label: Text(item.actionLabel!),
              ),
            const Spacer(),
            if (item.dismissible)
              TextButton(
                onPressed: () => _dismiss(ref, item),
                child: Text(context.l10n.txnHide),
              ),
          ]),
        ],
      ],
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
      launchExternalUrl(Uri.parse(url));
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
        context.l10n.annFromDate(date),
    };
  }

  static _MessageItem fromHistory(BuildContext context, NotificationHistoryEntry entry) {
    return _MessageItem(
      id: entry.id,
      source: _MessageSource.history,
      title: entry.title,
      body: entry.body,
      badge: context.l10n.annNotificationSent,
      sortAt: entry.sentAt,
      icon: AppLucideIcons.bellRing,
      accent: (c) => c.primary,
      route: entry.route,
      actionLabel: entry.route == null ? null : context.l10n.annOpen,
      dismissible: true,
    );
  }

  static _MessageItem fromCampaign(
      BuildContext context, RemoteGrowthCampaign campaign) {
    final en = Localizations.localeOf(context).languageCode == 'en';
    return _MessageItem(
      id: campaign.id,
      source: _MessageSource.campaign,
      title: en ? campaign.titleEn : campaign.titleAr,
      body: (en ? campaign.bodyEn : campaign.bodyAr) ?? '',
      badge: context.l10n.annInAppCampaign,
      sortAt: campaign.validFrom,
      icon: AppLucideIcons.megaphone,
      accent: (c) => c.cta,
      route: campaign.actionRoute,
      url: campaign.actionUrl,
      actionLabel: en ? campaign.actionLabelEn : campaign.actionLabelAr,
      dismissible: campaign.isDismissible,
    );
  }

  static _MessageItem fromAnnouncement(
      BuildContext context, RemoteAnnouncement announcement) {
    final en = Localizations.localeOf(context).languageCode == 'en';
    return _MessageItem(
      id: announcement.id,
      source: _MessageSource.announcement,
      title: en ? announcement.titleEn : announcement.titleAr,
      body: (en ? announcement.bodyEn : announcement.bodyAr) ?? '',
      badge: context.l10n.annFromQirsh,
      sortAt: announcement.validFrom,
      icon: AppLucideIcons.badgeAlert,
      accent: (c) => switch (announcement.severity) {
        'warning' => c.warning,
        'maintenance' => c.accent,
        _ => c.cta,
      },
      url: announcement.actionUrl,
      // Was `announcement.actionLabelAr`, one line below two that chose by
      // locale correctly.
      actionLabel: announcement.actionLabelFor(context),
      dismissible: announcement.isDismissible,
    );
  }
}
