import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/l10n_ext.dart';
import '../../domain/entities/achievement_catalog.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/qirsh_visuals.dart';
import '../ads/ad_placement.dart';
import '../ads/qirsh_ad_banner.dart';
import '../common/app_card.dart';
import '../common/premium_loading.dart';
import '../common/app_error_state.dart';
import '../common/app_header.dart';
import 'achievements_providers.dart';
import '../../core/utils/app_lucide_icons.dart';

class AchievementsScreen extends ConsumerWidget {
  const AchievementsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(achievementsViewProvider);
    return Scaffold(
      appBar: AppHeader(title: context.l10n.achTitle),
      body: async.when(
        skipLoadingOnReload: true,
        loading: () => const Column(children: [
          _AchievementsHeader(),
          Expanded(child: SkeletonList(rows: 5)),
        ]),
        error: (error, _) => ListView(padding: EdgeInsets.zero, children: [
          const _AchievementsHeader(),
          AppErrorState(
            title: context.l10n.txnError,
            description: context.l10n.annTryAgainSoon,
            retryLabel: context.l10n.startRetry,
            onRetry: () => ref.invalidate(achievementsViewProvider),
          ),
        ]),
        data: (data) {
          final c = context.colors;
          final nextThreshold = data.nextLevelThreshold;
          final progress = nextThreshold == null
              ? 1.0
              : (data.xpLevel.totalXp / nextThreshold).clamp(0, 1).toDouble();
          return RefreshIndicator(
            onRefresh: () async => refreshAchievements(ref),
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                const _AchievementsHeader(),
                const QirshPhotoBanner(photo: QirshPhoto.milestone),
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.gutter),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ON A SURFACE, not on the bare page.
                      //
                      // `CalmPageHeader` melts its gradient DOWNWARD into the
                      // page, so the first content block sits over fading
                      // blue. This block used the light-theme page tokens
                      // there, and «Current level» measured **1.45:1** against
                      // its background — WCAG AA wants 4.5:1. Every other
                      // screen puts a card in the melt zone, which is why none
                      // of them has the problem; this one had bare text.
                      //
                      // The header hero names the level and its tiles carry XP
                      // and the streak, so this card is only the progress to
                      // the next level.
                      AppCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Expanded(child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('${context.l10n.achLevel} ${data.xpLevel.level}',
                                    style: AppTypography.caption(c.textMuted)),
                                  Text(_levelName(context, data.xpLevel.levelKey),
                                    style: AppTypography.title2(c.textPrimary)),
                                ],
                              )),
                              Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(color: c.warningBg,
                                  borderRadius: BorderRadius.circular(999)),
                                child: Text(context.l10n.achStreakDays(data.streak.currentStreak),
                                  style: AppTypography.caption(c.warning))),
                            ]),
                            const SizedBox(height: 12),
                            ClipRRect(
                              borderRadius:
                                  BorderRadius.circular(AppRadius.pill),
                              child: LinearProgressIndicator(
                                value: progress,
                                minHeight: 12,
                                backgroundColor: c.surface2,
                                valueColor: AlwaysStoppedAnimation(c.primary),
                              ),
                            ),
                            const SizedBox(height: AppSpacing.s2),
                            Text(
                              nextThreshold == null
                                  ? '${data.xpLevel.totalXp.toString()} XP'
                                  : '${data.xpLevel.totalXp.toString()}/$nextThreshold XP',
                              style: AppTypography.subhead(c.textMain),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: AppSpacing.s5),
                      Text(context.l10n.achBadges,
                        style: AppTypography.title2(c.textPrimary)),
                      const SizedBox(height: 4),
                      Text(context.l10n.achEarnedCount(
                        data.achievements.where((a) => a.unlockedAt != null).length,
                        data.achievements.length),
                        style: AppTypography.caption(c.textMuted)),
                      const SizedBox(height: 12),
                      GridView.builder(
                        // Explicit, or the grid inherits the status-bar inset
                        // as top padding and opens a ~60pt gap above itself.
                        padding: EdgeInsets.zero,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate:
                            SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: MediaQuery.sizeOf(context).width < 360 ? 2 : 3,
                          crossAxisSpacing: AppSpacing.s3,
                          mainAxisSpacing: AppSpacing.s3,
                          mainAxisExtent: 164 * MediaQuery.textScalerOf(context).scale(1),
                        ),
                        itemCount: data.achievements.length,
                        itemBuilder: (context, index) {
                          final item = data.achievements[index];
                          final unlocked = item.unlockedAt != null;
                          return Container(
                            padding: const EdgeInsets.all(AppSpacing.s3),
                            decoration: BoxDecoration(
                              color: unlocked
                                  ? c.primary.withValues(alpha: 0.08)
                                  : c.surface,
                              borderRadius:
                                  BorderRadius.circular(AppRadius.card),
                              border: Border.all(
                                color: unlocked
                                    ? c.primary.withValues(alpha: 0.4)
                                    : c.border,
                                width: unlocked ? 1.5 : 1,
                              ),
                              boxShadow: unlocked
                                  ? [
                                      BoxShadow(
                                        color: c.primary.withValues(alpha: 0.1),
                                        blurRadius: 10,
                                        offset: const Offset(0, 4),
                                      ),
                                    ]
                                  : [],
                            ),
                            child: Stack(
                              children: [
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(6),
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: unlocked
                                            ? c.accent.withValues(alpha: 0.15)
                                            : c.surface2.withValues(alpha: 0.5),
                                        border: Border.all(
                                          color: unlocked
                                              ? c.accent.withValues(alpha: 0.3)
                                              : c.border.withValues(alpha: 0.1),
                                          width: 1,
                                        ),
                                      ),
                                      child: Icon(
                                        unlocked
                                            ? AppLucideIcons.trophy
                                            : AppLucideIcons.lock,
                                        color:
                                            unlocked ? c.accent : c.textLight,
                                        size: 18,
                                      ),
                                    ),
                                    const SizedBox(height: AppSpacing.s3),
                                    Text(
                                      AchievementCatalog.displayName(
                                          item.key,
                                          item.nameAr,
                                          Localizations.localeOf(context)
                                              .languageCode),
                                      style: AppTypography.subhead(unlocked
                                              ? c.textMain
                                              : c.textLight)
                                          .copyWith(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      unlocked ? context.l10n.achUnlocked : context.l10n.achInProgress,
                                      style: AppTypography.caption(unlocked
                                          ? c.success
                                          : c.textLight.withValues(alpha: 0.7)),
                                    ),
                                  ],
                                ),
                                // إضاءة خلفية ذهبية خفيفة للشارات المفتوحة كعلامة مائية
                                if (unlocked)
                                  Positioned(
                                    top: -20,
                                    left: -20,
                                    child: Opacity(
                                      opacity: 0.12,
                                      child: Transform.rotate(
                                        angle: 0.25,
                                        child: Icon(
                                          AppLucideIcons.trophy,
                                          size: 80,
                                          color: c.accent,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
                // A DIRECT child of the ListView, deliberately.
                //
                // `SliverList` materialises its direct children lazily, so a
                // banner here buys nothing until the user has scrolled past the
                // badge grid. Move it inside the `Padding` above and it becomes
                // part of that child, which is built as one unit — and the ad
                // would be requested on arrival for a slot far below the fold.
                // Verified both ways in banner_placement_mechanics_test.dart.
                //
                // After the grid, never inside it: a cell-sized ad among badge
                // cells reads as a badge.
                if (data.achievements.isNotEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(
                        horizontal: AppSpacing.gutter),
                    child: QirshAdBanner(placement: AdPlacement.achievements),
                  ),
                // Clearance for the floating nav bar. An ad the bar sits on top
                // of is an obscured ad, which is a placement-policy problem and
                // not a cosmetic one.
                const SizedBox(
                  height: AppSpacing.navBarHeight + AppSpacing.navBarInset * 2,
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  String _levelName(BuildContext context, String levelKey) {
    switch (levelKey) {
      case 'organized':
        return context.l10n.achLevelOrganised;
      case 'smart_saver':
        return context.l10n.achLevelSmartSaver;
      case 'financial_expert':
        return context.l10n.achLevelExpert;
      case 'saving_legend':
        return context.l10n.achLevelLegend;
      case 'beginner':
      default:
        return context.l10n.achLevelBeginner;
    }
  }
}

class _AchievementsHeader extends StatelessWidget {
  const _AchievementsHeader();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, 8, AppSpacing.gutter, 12),
      child: Text(context.l10n.achSubtitle,
          style: AppTypography.caption(context.colors.textSecondary)),
    );
  }
}
