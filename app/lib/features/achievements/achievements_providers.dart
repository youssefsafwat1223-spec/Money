import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../domain/entities/supporting_entities.dart';
import '../../domain/usecases/gamification_rules.dart';

class AchievementsView {
  const AchievementsView({
    required this.achievements,
    required this.xpLevel,
    required this.streak,
  });

  final List<AchievementEntity> achievements;
  final XpLevelEntity xpLevel;
  final StreakEntity streak;

  int? get nextLevelThreshold {
    final currentLevel = xpLevel.level;
    if (currentLevel >= XpLevelEngine.thresholds.length) {
      return null;
    }
    return XpLevelEngine.thresholds[currentLevel];
  }
}

final achievementsViewProvider = FutureProvider<AchievementsView>((ref) async {
  ref.watch(dbRevisionProvider);
  final repo = ref.watch(gamificationRepositoryProvider);
  return AchievementsView(
    achievements: await repo.getAchievements(),
    xpLevel: await repo.getXpLevel(),
    streak: await repo.getStreak(),
  );
});

void refreshAchievements(WidgetRef ref) {
  ref.invalidate(achievementsViewProvider);
}
