import 'package:drift/drift.dart';

import '../../domain/entities/supporting_entities.dart';
import '../../domain/repositories/gamification_repository.dart';
import '../db/app_database.dart';
import '../db/sql_value_codec.dart';
import 'drift_repository_support.dart';

class DriftGamificationRepository implements GamificationRepository {
  DriftGamificationRepository(this._db);

  final AppDatabase _db;

  @override
  Future<AchievementEntity?> getAchievementByKey(String key) async {
    final row = await _db.customSelect(
      'SELECT * FROM achievements WHERE key = ? LIMIT 1;',
      variables: [Variable.withString(key)],
    ).getSingleOrNull();
    return row == null ? null : achievementFromRow(row);
  }

  @override
  Future<List<AchievementEntity>> getAchievements() async {
    final rows = await _db
        .customSelect(
          'SELECT * FROM achievements ORDER BY name_ar ASC;',
        )
        .get();
    return rows.map(achievementFromRow).toList();
  }

  @override
  Future<StreakEntity> getStreak() async {
    final row = await _db
        .customSelect(
          'SELECT * FROM streaks LIMIT 1;',
        )
        .getSingle();
    return streakFromRow(row);
  }

  @override
  Future<XpLevelEntity> getXpLevel() async {
    final row = await _db
        .customSelect(
          'SELECT * FROM xp_levels LIMIT 1;',
        )
        .getSingle();
    return xpLevelFromRow(row);
  }

  @override
  Future<AchievementEntity> saveAchievement(
      AchievementEntity achievement) async {
    await _db.customStatement('''
      UPDATE achievements
      SET name_ar = ${sqlString(achievement.nameAr)},
          unlocked_at = ${sqlNullableString(achievement.unlockedAt == null ? null : dateTimeToSql(achievement.unlockedAt!))},
          progress = ${achievement.progress}
      WHERE id = ${sqlString(achievement.id)};
    ''');
    return achievement;
  }

  @override
  Future<StreakEntity> saveStreak(StreakEntity streak) async {
    await _db.customUpdate(
      '''
        UPDATE streaks
        SET current_streak = ?, longest_streak = ?, last_active_date = ?, freezes_available = ?
        WHERE id = ?;
      ''',
      variables: [
        Variable.withInt(streak.currentStreak),
        Variable.withInt(streak.longestStreak),
        Variable.withString(dateTimeToSql(streak.lastActiveDate)),
        Variable.withInt(streak.freezesAvailable),
        Variable.withString(streak.id),
      ],
    );
    return streak;
  }

  @override
  Future<XpLevelEntity> saveXpLevel(XpLevelEntity xpLevel) async {
    await _db.customUpdate(
      '''
        UPDATE xp_levels
        SET total_xp = ?, level = ?, level_key = ?
        WHERE id = ?;
      ''',
      variables: [
        Variable.withInt(xpLevel.totalXp),
        Variable.withInt(xpLevel.level),
        Variable.withString(xpLevel.levelKey),
        Variable.withString(xpLevel.id),
      ],
    );
    return xpLevel;
  }
}
