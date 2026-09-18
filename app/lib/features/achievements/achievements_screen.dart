import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/l10n_ext.dart';
import '../../domain/entities/achievement_catalog.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/calm_page_header.dart';
import '../ads/ad_placement.dart';
import '../ads/qirsh_ad_banner.dart';
import '../common/app_card.dart';
import '../common/premium_loading.dart';
import 'achievements_providers.dart';
import '../../core/utils/app_lucide_icons.dart';

class AchievementsScreen extends ConsumerWidget {
  const AchievementsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(achievementsViewProvider);
    return Scaffold(
      body: async.when(
        skipLoadingOnReload: true,
        loading: () => const SkeletonList(rows: 5),
        error: (error, _) => Center(child: Text(context.l10n.txnError)),
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
                _AchievementsHeader(
                  level: data.xpLevel.level,
                  xp: data.xpLevel.totalXp,
                  streak: data.streak.currentStreak,
                ),
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
                      AppCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(context.l10n.achCurrentLevel,
                                style: AppTypography.callout(c.textLight)),
                            const SizedBox(height: AppSpacing.s1),
                            Text(
                              _levelName(context, data.xpLevel.levelKey),
                              style: AppTypography.title2(c.textMain),
                            ),
                            const SizedBox(height: AppSpacing.s3),
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
                            const SizedBox(height: AppSpacing.s3),
                            Text(
                              context.l10n
                                  .achCurrentStreak(data.streak.currentStreak),
                              style: AppTypography.bodyStrong(c.textMain),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: AppSpacing.s5),
                      GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          crossAxisSpacing: AppSpacing.s3,
                          mainAxisSpacing: AppSpacing.s3,
                          childAspectRatio: 1.3,
                        ),
                        itemCount: data.achievements.length,
                        itemBuilder: (context, index) {
                          final item = data.achievements[index];
                          final unlocked = item.unlockedAt != null;
                          return Container(
                            padding: const EdgeInsets.all(AppSpacing.s4),
                            decoration: BoxDecoration(
                              color: unlocked
                                  ? c.primary.withValues(alpha: 0.08)
                                  : c.surface.withValues(alpha: 0.45),
                              borderRadius:
                                  BorderRadius.circular(AppRadius.card),
                              border: Border.all(
                                color: unlocked
                                    ? c.primary.withValues(alpha: 0.4)
                                    : c.border.withValues(alpha: 0.15),
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
  const _AchievementsHeader({
    required this.level,
    required this.xp,
    required this.streak,
  });

  final int level;
  final int xp;
  final int streak;

  @override
  Widget build(BuildContext context) {
    return CalmPageHeader(
      title: context.l10n.achTitle,
      subtitle: context.l10n.achSubtitle,
      leading: Navigator.of(context).canPop()
          ? const BackButton(color: Colors.white)
          : null,
      amount: '$level',
      currency: context.l10n.achLevel,
      metrics: [
        CalmMetric(label: context.l10n.achTotalXp, value: '$xp'),
        CalmMetric(label: context.l10n.achStreak, value: context.l10n.achStreakDays(streak)),
      ],
    );
  }
}
