import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
    final announcementsAsync = ref.watch(activeAnnouncementsProvider);
    return announcementsAsync.when(
      data: (announcements) {
        // Filter out force_update here — those are handled by ForceUpdateScreen.
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
    final bg = switch (announcement.severity) {
      'warning' => c.warning.withValues(alpha: 0.15),
      'maintenance' => c.accent.withValues(alpha: 0.12),
      _ => c.primary.withValues(alpha: 0.10),
    };
    final textColor = switch (announcement.severity) {
      'warning' => c.warning,
      'maintenance' => c.accent,
      _ => c.primary,
    };

    return Material(
      color: bg,
      child: InkWell(
        onTap: announcement.actionUrl != null
            ? () => _handleTap(context, announcement.actionUrl!)
            : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.gutter,
            vertical: AppSpacing.s2,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  announcement.titleAr,
                  style: AppTypography.caption(textColor).copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (announcement.isDismissible) ...[
                const SizedBox(width: AppSpacing.s2),
                GestureDetector(
                  onTap: () => ref
                      .read(announcementServiceProvider)
                      .dismiss(announcement.id)
                      .then((_) => ref.invalidate(activeAnnouncementsProvider)),
                  child: Icon(Icons.close, size: 16, color: textColor),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _handleTap(BuildContext context, String url) {
    if (url.startsWith('/')) {
      // Internal route — use GoRouter
      // ignore: use_build_context_synchronously
      Navigator.of(context).pushNamed(url);
    } else {
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    }
  }
}
