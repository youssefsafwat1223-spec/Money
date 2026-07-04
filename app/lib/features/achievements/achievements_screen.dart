import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../common/premium_loading.dart';
import 'achievements_providers.dart';

class AchievementsScreen extends ConsumerWidget {
  const AchievementsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(achievementsViewProvider);
    return Scaffold(
      body: async.when(
        loading: () => const PremiumSkeletonPage(cardCount: 5),
        error: (error, _) => const Center(child: Text('حدث خطأ')),
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
                      Text('المستوى الحالي', style: AppTypography.callout(c.textLight)),
                      const SizedBox(height: AppSpacing.s1),
                      Text(
                        _levelName(data.xpLevel.levelKey),
                        style: AppTypography.title2(c.textMain),
                      ),
                      const SizedBox(height: AppSpacing.s3),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(AppRadius.pill),
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
                      const SizedBox(height: AppSpacing.s5),
                      Text(
                        'السلسلة الحالية: ${data.streak.currentStreak} يوم',
                        style: AppTypography.bodyStrong(c.textMain),
                      ),
                      const SizedBox(height: AppSpacing.s5),
                      GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
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
                              borderRadius: BorderRadius.circular(AppRadius.card),
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
                                        unlocked ? Icons.emoji_events_rounded : Icons.lock_outline,
                                        color: unlocked ? c.accent : c.textLight,
                                        size: 18,
                                      ),
                                    ),
                                    const SizedBox(height: AppSpacing.s3),
                                    Text(
                                      item.nameAr,
                                      style: AppTypography.subhead(unlocked ? c.textMain : c.textLight).copyWith(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      unlocked ? 'تم الفتح' : 'قيد التقدّم',
                                      style: AppTypography.caption(unlocked ? c.success : c.textLight.withValues(alpha: 0.7)),
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
                                          Icons.emoji_events_rounded,
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
              ],
            ),
          );
        },
      ),
    );
  }

  String _levelName(String levelKey) {
    switch (levelKey) {
      case 'organized':
        return 'منظّم';
      case 'smart_saver':
        return 'موفّر ذكي';
      case 'financial_expert':
        return 'خبير مالي';
      case 'saving_legend':
        return 'أسطورة الادخار';
      case 'beginner':
      default:
        return 'مبتدئ';
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
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        64,
        AppSpacing.gutter,
        AppSpacing.s4,
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
                  'الإنجازات',
                  style: AppTypography.title1(c.textMain)
                      .copyWith(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'شارات ومستويات تشجعك تكمل عادة المتابعة.',
            style: AppTypography.caption(c.textMuted),
          ),
          const SizedBox(height: AppSpacing.s5),
          Container(
            padding: const EdgeInsets.all(AppSpacing.s4),
            decoration: BoxDecoration(
              color: c.surfaceCard,
              borderRadius: BorderRadius.circular(AppRadius.card),
              border: Border.all(color: c.border),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.03),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: c.cta.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(
                        Icons.emoji_events_outlined,
                        color: c.cta,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.s3),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'المستوى الحالي',
                            style: AppTypography.caption(c.textSecondary),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '$level',
                            style: AppTypography.title2(c.textMain)
                                .copyWith(fontWeight: FontWeight.bold, fontFamily: 'Outfit'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.s3),
                  child: Divider(color: c.border, height: 1),
                ),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '$xp',
                            style: AppTypography.bodyStrong(c.textMain)
                                .copyWith(fontWeight: FontWeight.bold, fontFamily: 'Outfit'),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'إجمالي الـ XP',
                            style: AppTypography.caption(c.textSecondary),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      width: 1,
                      height: 32,
                      color: c.divider,
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '$streak يوم',
                            style: AppTypography.bodyStrong(c.textMain)
                                .copyWith(fontWeight: FontWeight.bold, fontFamily: 'Outfit'),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'سلسلة المتابعة',
                            style: AppTypography.caption(c.textSecondary),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
