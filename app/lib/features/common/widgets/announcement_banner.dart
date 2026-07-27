import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../data/catalog/catalog_daos.dart';

class AnnouncementBanner extends ConsumerWidget {
  const AnnouncementBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final campaignsAsync = ref.watch(activeDashboardCampaignsProvider);
    final campaigns = campaignsAsync.valueOrNull ?? [];

    final announcementsAsync = ref.watch(activeAnnouncementsProvider);
    final announcements = announcementsAsync.valueOrNull
            ?.where((a) => !a.isForceUpdate && !a.isDismissed)
            .toList() ??
        [];

    final allItems = <Widget>[
      for (final c in campaigns) _CampaignBannerTile(campaign: c),
      for (final a in announcements) _BannerTile(announcement: a),
    ];

    if (allItems.isEmpty) return const SizedBox.shrink();
    if (allItems.length == 1) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
        child: allItems.first,
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: allItems.asMap().entries.map((entry) {
          final isLast = entry.key == allItems.length - 1;
          return Padding(
            padding:
                EdgeInsetsDirectional.only(end: isLast ? 0 : AppSpacing.s3),
            child: SizedBox(
              width: MediaQuery.of(context).size.width -
                  (AppSpacing.gutter * 2) -
                  24,
              child: entry.value,
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _CampaignBannerTile extends ConsumerStatefulWidget {
  const _CampaignBannerTile({required this.campaign});

  final RemoteGrowthCampaign campaign;

  @override
  ConsumerState<_CampaignBannerTile> createState() =>
      _CampaignBannerTileState();
}

class _CampaignBannerTileState extends ConsumerState<_CampaignBannerTile> {
  bool _recorded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_recorded) return;
    _recorded = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(growthCampaignServiceProvider)
          .recordImpression(widget.campaign.id)
          .then((_) => ref.invalidate(activeDashboardCampaignsProvider));
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final start = isDark ? const Color(0xFF0F766E) : const Color(0xFF0F8F73);
    final end = isDark ? const Color(0xFF115E59) : const Color(0xFF12A17E);
    final body = widget.campaign.bodyAr?.trim();
    final hasBody = body != null && body.isNotEmpty;
    final actionLabel = widget.campaign.actionLabelAr?.trim();
    final hasAction = actionLabel != null && actionLabel.isNotEmpty;

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.xxl),
        boxShadow: [
          BoxShadow(
            color: start.withValues(alpha: isDark ? 0.20 : 0.24),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.xxl),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _handleTap(context),
          child: Stack(
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: AlignmentDirectional.topStart,
                      end: AlignmentDirectional.bottomEnd,
                      colors: [start, end],
                    ),
                  ),
                ),
              ),
              PositionedDirectional(
                top: -44,
                start: -26,
                child: Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                ),
              ),
              PositionedDirectional(
                bottom: -58,
                end: -28,
                child: Container(
                  width: 150,
                  height: 150,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.black.withValues(alpha: 0.07),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(
                  AppSpacing.s5,
                  AppSpacing.s5,
                  AppSpacing.s4,
                  AppSpacing.s5,
                ),
                child: Directionality(
                  textDirection: TextDirection.rtl,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              widget.campaign.titleAr,
                              textAlign: TextAlign.right,
                              style: AppTypography.title(Colors.white).copyWith(
                                fontWeight: FontWeight.w700,
                                height: 1.22,
                              ),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (widget.campaign.isDismissible) ...[
                            const SizedBox(width: AppSpacing.s2),
                            _CampaignDismissButton(
                              campaignId: widget.campaign.id,
                            ),
                          ],
                        ],
                      ),
                      if (hasBody) ...[
                        const SizedBox(height: AppSpacing.s2),
                        Text(
                          body,
                          textAlign: TextAlign.right,
                          style: AppTypography.body(
                            Colors.white.withValues(alpha: 0.82),
                          ).copyWith(height: 1.35),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      if (hasAction) ...[
                        const SizedBox(height: AppSpacing.s3),
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.s3,
                              vertical: 7,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.16),
                              borderRadius:
                                  BorderRadius.circular(AppRadius.pill),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.18),
                              ),
                            ),
                            child: Text(
                              actionLabel,
                              style: AppTypography.caption(Colors.white)
                                  .copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _handleTap(BuildContext context) {
    final route = widget.campaign.actionRoute?.trim();
    if (route != null && route.isNotEmpty) {
      context.push(route);
      return;
    }
    final url = widget.campaign.actionUrl?.trim();
    if (url != null && url.isNotEmpty) {
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    }
  }
}

class _BannerTile extends ConsumerWidget {
  const _BannerTile({required this.announcement});

  final RemoteAnnouncement announcement;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = Theme.of(context).extension<AppColors>()!;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colors = switch (announcement.severity) {
      'warning' => (
          start: c.warning,
          end: const Color(0xFFB45309),
          fg: Colors.white,
        ),
      'maintenance' => (
          start: c.accent,
          end: const Color(0xFF7C3AED),
          fg: Colors.white,
        ),
      _ => (
          start: isDark ? const Color(0xFF0F766E) : const Color(0xFF0F8F73),
          end: isDark ? const Color(0xFF115E59) : const Color(0xFF12A17E),
          fg: Colors.white,
        ),
    };
    final body = announcement.bodyAr?.trim();
    final hasBody = body != null && body.isNotEmpty;
    final actionLabel = announcement.actionLabelAr?.trim();
    final hasAction = announcement.actionUrl != null &&
        actionLabel != null &&
        actionLabel.isNotEmpty;

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.xxl),
        boxShadow: [
          BoxShadow(
            color: colors.start.withValues(alpha: isDark ? 0.20 : 0.24),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.xxl),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _handleTap(context, announcement.actionUrl),
          child: Stack(
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: AlignmentDirectional.topStart,
                      end: AlignmentDirectional.bottomEnd,
                      colors: [colors.start, colors.end],
                    ),
                  ),
                ),
              ),
              PositionedDirectional(
                top: -44,
                start: -26,
                child: Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                ),
              ),
              PositionedDirectional(
                bottom: -58,
                end: -28,
                child: Container(
                  width: 150,
                  height: 150,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.black.withValues(alpha: 0.07),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(
                  AppSpacing.s5,
                  AppSpacing.s5,
                  AppSpacing.s4,
                  AppSpacing.s5,
                ),
                child: Directionality(
                  textDirection: TextDirection.rtl,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              announcement.titleAr,
                              textAlign: TextAlign.right,
                              style: AppTypography.title(colors.fg).copyWith(
                                fontWeight: FontWeight.w700,
                                height: 1.22,
                              ),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (announcement.isDismissible) ...[
                            const SizedBox(width: AppSpacing.s2),
                            _DismissButton(announcementId: announcement.id),
                          ],
                        ],
                      ),
                      if (hasBody) ...[
                        const SizedBox(height: AppSpacing.s2),
                        Text(
                          body,
                          textAlign: TextAlign.right,
                          style: AppTypography.body(
                            colors.fg.withValues(alpha: 0.82),
                          ).copyWith(height: 1.35),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      if (hasAction) ...[
                        const SizedBox(height: AppSpacing.s3),
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.s3,
                              vertical: 7,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.16),
                              borderRadius:
                                  BorderRadius.circular(AppRadius.pill),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.18),
                              ),
                            ),
                            child: Text(
                              actionLabel,
                              style: AppTypography.caption(colors.fg)
                                  .copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _handleTap(BuildContext context, String? url) {
    if (url == null || url.trim().isEmpty) {
      context.push('/announcements');
      return;
    }
    if (url.startsWith('/')) {
      context.push(url);
      return;
    }
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }
}

class _DismissButton extends ConsumerWidget {
  const _DismissButton({required this.announcementId});

  final String announcementId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SizedBox.square(
      dimension: 34,
      child: IconButton(
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(
          backgroundColor: Colors.white.withValues(alpha: 0.16),
          foregroundColor: Colors.white,
          shape: const CircleBorder(),
        ),
        onPressed: () =>
            ref.read(announcementServiceProvider).dismiss(announcementId).then(
                  (_) => ref.invalidate(activeAnnouncementsProvider),
                ),
        icon: const Icon(Icons.close_rounded, size: 18),
        tooltip: 'إخفاء',
      ),
    );
  }
}

class _CampaignDismissButton extends ConsumerWidget {
  const _CampaignDismissButton({required this.campaignId});

  final String campaignId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SizedBox.square(
      dimension: 34,
      child: IconButton(
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(
          backgroundColor: Colors.white.withValues(alpha: 0.16),
          foregroundColor: Colors.white,
          shape: const CircleBorder(),
        ),
        onPressed: () => ref
            .read(growthCampaignServiceProvider)
            .dismiss(campaignId)
            .then((_) => ref.invalidate(activeDashboardCampaignsProvider)),
        icon: const Icon(Icons.close_rounded, size: 18),
        tooltip: 'إخفاء',
      ),
    );
  }
}
