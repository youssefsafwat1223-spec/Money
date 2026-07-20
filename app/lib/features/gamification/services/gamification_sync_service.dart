import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/di/app_providers.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/sql_value_codec.dart';
import '../../../domain/repositories/gamification_repository.dart';

final gamificationSyncServiceProvider = Provider((ref) {
  return GamificationSyncService(
    db: ref.watch(appDatabaseProvider),
    supabase: Supabase.instance.client,
    gamificationRepo: ref.watch(gamificationRepositoryProvider),
  );
});

class GamificationSyncService {
  GamificationSyncService({
    required this.db,
    required this.supabase,
    required this.gamificationRepo,
  });

  final AppDatabase db;
  final SupabaseClient supabase;
  final GamificationRepository gamificationRepo;

  Future<void> performSync() async {
    // Read fresh on every call rather than capturing at provider-construction
    // time — the provider is a long-lived singleton, but the signed-in user
    // can change (sign-out/sign-in) without it being recreated.
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) return;
    await _migrateLocalToSupabaseIfNeeded(userId);
    await _pullFromSupabase(userId);
  }

  Future<void> _migrateLocalToSupabaseIfNeeded(String userId) async {
    // Check if user already has xp_levels in Supabase to determine if migration ran
    final response = await supabase
        .from('user_xp_levels')
        .select('xp')
        .eq('user_id', userId)
        .maybeSingle();

    if (response != null) {
      return; // Already migrated
    }

    // 1. Upload achievements
    final localAchievements = await gamificationRepo.getAchievements();
    final unlockedAchievements =
        localAchievements.where((a) => a.unlockedAt != null).toList();

    if (unlockedAchievements.isNotEmpty) {
      final achievementsPayload = unlockedAchievements
          .map((a) => {
                'user_id': userId,
                'local_id': a.id,
                'achievement_key': a.key,
                'unlocked_at': a.unlockedAt!.toUtc().toIso8601String(),
              })
          .toList();

      await supabase.from('user_achievements').insert(achievementsPayload);
    }

    // 2. Upload streak
    final streak = await gamificationRepo.getStreak();
    await supabase.from('user_streaks').upsert({
      'user_id': userId,
      'current_streak': streak.currentStreak,
      'longest_streak': streak.longestStreak,
      'last_active_date': dateTimeToSql(streak.lastActiveDate),
    });

    // 3. Upload xp
    final xp = await gamificationRepo.getXpLevel();
    await supabase.from('user_xp_levels').upsert({
      'user_id': userId,
      'xp': xp.totalXp,
      'level': xp.level,
    });
  }

  Future<void> _pullFromSupabase(String userId) async {
    // Pull Achievements
    final serverAchievements = await supabase
        .from('user_achievements')
        .select()
        .eq('user_id', userId)
        .isFilter('deleted_at', null);

    for (final row in serverAchievements) {
      final key = row['achievement_key'] as String;
      final unlockedAt = DateTime.parse(row['unlocked_at'] as String).toUtc();
      await db.customStatement('''
        UPDATE achievements
        SET unlocked_at = ?, progress = 1.0
        WHERE key = ?;
      ''', [dateTimeToSql(unlockedAt), key]);
    }

    // Pull Streak
    final serverStreak = await supabase
        .from('user_streaks')
        .select()
        .eq('user_id', userId)
        .maybeSingle();

    if (serverStreak != null) {
      final currentStreak = serverStreak['current_streak'] as int;
      final longestStreak = serverStreak['longest_streak'] as int;
      final lastActiveDate = serverStreak['last_active_date'] as String?;

      if (lastActiveDate != null) {
        await db.customStatement('''
          UPDATE streaks
          SET current_streak = ?, longest_streak = ?, last_active_date = ?
          WHERE id = 'streak';
        ''', [currentStreak, longestStreak, lastActiveDate]);
      }
    }

    // Pull XP
    final serverXp = await supabase
        .from('user_xp_levels')
        .select()
        .eq('user_id', userId)
        .maybeSingle();

    if (serverXp != null) {
      final currentXp = serverXp['xp'] as int;
      final currentLevel = serverXp['level'] as int;

      await db.customStatement('''
        UPDATE xp_levels
        SET total_xp = ?, level = ?
        WHERE id = 'xp_level';
      ''', [currentXp, currentLevel]);
    }
  }
}
