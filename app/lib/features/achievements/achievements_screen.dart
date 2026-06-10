import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
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
              padding: const EdgeInsets.all(AppSpacing.gutter),
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
                        color: unlocked ? c.surface : c.surface2,
                        borderRadius: BorderRadius.circular(AppRadius.card),
                        border: Border.all(
                          color: unlocked ? c.primary : c.border,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            unlocked ? Icons.verified_outlined : Icons.lock_outline,
                            color: unlocked ? c.primary : c.textLight,
                          ),
                          const SizedBox(height: AppSpacing.s2),
                          Text(
                            item.nameAr,
                            style: AppTypography.subhead(c.textMain),
                          ),
                          const SizedBox(height: AppSpacing.s1),
                          Text(
                            unlocked ? 'تم الفتح' : 'قيد التقدّم',
                            style: AppTypography.caption(c.textLight),
                          ),
                        ],
                      ),
                    );
                  },
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
