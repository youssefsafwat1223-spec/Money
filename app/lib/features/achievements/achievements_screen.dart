import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../common/section_hero_header.dart';
import 'achievements_providers.dart';

class AchievementsScreen extends ConsumerWidget {
  const AchievementsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(achievementsViewProvider);
    return async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('حدث خطأ: $error')),
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
                SectionHeroHeader(
                  title: 'الإنجازات',
                  subtitle: 'شارات ومستويات تشجعك تكمل عادة المتابعة.',
                  metrics: [
                    SectionHeroMetric(value: '${data.xpLevel.level}', label: 'المستوى'),
                    SectionHeroMetric(value: '${data.xpLevel.totalXp}', label: 'XP'),
                    SectionHeroMetric(value: '${data.streak.currentStreak}', label: 'السلسلة'),
                  ],
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
