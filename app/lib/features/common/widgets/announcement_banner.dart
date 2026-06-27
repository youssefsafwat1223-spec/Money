import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/theme/app_assets.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../data/catalog/catalog_daos.dart';

class AnnouncementBanner extends ConsumerWidget {
  const AnnouncementBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final announcementsAsync = ref.watch(activeAnnouncementsProvider);
    return announcementsAsync.when(
      data: (announcements) {
        final visible = announcements
            .where((a) => !a.isForceUpdate && !a.isDismissed)
            .toList();
        if (visible.isEmpty) return const SizedBox.shrink();
        final a = visible.first;
        return _BannerTile(announcement: a);
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }
}

class _BannerTile extends ConsumerWidget {
  const _BannerTile({required this.announcement});

  final RemoteAnnouncement announcement;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = Theme.of(context).extension<AppColors>()!;
    final accent = switch (announcement.severity) {
      'warning' => c.warning,
      'maintenance' => c.accent,
      _ => c.cta,
    };
    final body = announcement.bodyAr?.trim();
    final hasBody = body != null && body.isNotEmpty;
    final actionLabel = announcement.actionLabelAr?.trim();
    final hasAction = announcement.actionUrl != null &&
        actionLabel != null &&
        actionLabel.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        AppSpacing.s2,
        AppSpacing.gutter,
        0,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.card),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 24,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Material(
          color: c.surface.withValues(alpha: 0.98),
          borderRadius: BorderRadius.circular(AppRadius.card),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => _handleTap(context, announcement.actionUrl),
            child: Stack(
              children: [
                PositionedDirectional(
                  top: 0,
                  bottom: 0,
                  start: 0,
                  child: Container(width: 5, color: accent),
                ),
                Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(
                    AppSpacing.s4,
                    AppSpacing.s3,
                    AppSpacing.s3,
                    AppSpacing.s3,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        padding: const EdgeInsets.all(7),
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.11),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: accent.withValues(alpha: 0.22),
                          ),
                        ),
                        child: Image.asset(
                          AppAssets.qirshCoin,
                          filterQuality: FilterQuality.high,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.s3),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              announcement.titleAr,
                              style: AppTypography.bodyStrong(c.textPrimary),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (hasBody) ...[
                              const SizedBox(height: 3),
                              Text(
                                body,
                                style: AppTypography.footnote(c.textSecondary),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                            if (hasAction) ...[
                              const SizedBox(height: AppSpacing.s2),
                              Align(
                                alignment: AlignmentDirectional.centerStart,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: AppSpacing.s3,
                                    vertical: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    color: accent.withValues(alpha: 0.12),
                                    borderRadius:
                                        BorderRadius.circular(AppRadius.pill),
                                  ),
                                  child: Text(
                                    actionLabel,
                                    style: AppTypography.caption(accent)
                                        .copyWith(fontWeight: FontWeight.w800),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (announcement.isDismissible) ...[
                        const SizedBox(width: AppSpacing.s2),
                        SizedBox(
                          width: 34,
                          height: 34,
                          child: IconButton(
                            padding: EdgeInsets.zero,
                            onPressed: () => ref
                                .read(announcementServiceProvider)
                                .dismiss(announcement.id)
                                .then(
                                  (_) => ref
                                      .invalidate(activeAnnouncementsProvider),
                                ),
                            icon: Icon(
                              Icons.close_rounded,
                              size: 18,
                              color: c.textMuted,
                            ),
                            tooltip: 'إخفاء',
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
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
