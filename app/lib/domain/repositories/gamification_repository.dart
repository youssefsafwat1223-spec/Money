import '../entities/supporting_entities.dart';

abstract class GamificationRepository {
  Future<StreakEntity> getStreak();
  Future<StreakEntity> saveStreak(StreakEntity streak);

  Future<XpLevelEntity> getXpLevel();
  Future<XpLevelEntity> saveXpLevel(XpLevelEntity xpLevel);

  Future<List<AchievementEntity>> getAchievements();
  Future<AchievementEntity?> getAchievementByKey(String key);
  Future<AchievementEntity> saveAchievement(AchievementEntity achievement);
}
