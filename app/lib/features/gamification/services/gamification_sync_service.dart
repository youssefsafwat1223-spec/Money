import 'package:drift/drift.dart' as drift;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../data/db/app_database.dart';
import '../../../../data/db/sql_value_codec.dart';
import '../../../../domain/repositories/gamification_repository.dart';
import '../../../auth/providers/auth_providers.dart';

final gamificationSyncServiceProvider = Provider((ref) {
  return GamificationSyncService(
    db: ref.watch(appDatabaseProvider),
    supabase: Supabase.instance.client,
    userId: ref.watch(requireUserIdProvider),
    gamificationRepo: ref.watch(gamificationRepositoryProvider),
  );
});

class GamificationSyncService {
  GamificationSyncService({
    required this.db,
    required this.supabase,
    required this.userId,
    required this.gamificationRepo,
  });

  final AppDatabase db;
  final SupabaseClient supabase;
  final String userId;
  final GamificationRepository gamificationRepo;

  Future<void> performSync() async {
    await _migrateLocalToSupabaseIfNeeded();
    await _pullFromSupabase();
  }

  Future<void> _migrateLocalToSupabaseIfNeeded() async {
    // Check if user already has xp_levels in Supabase to determine if migration ran
    final response = await supabase
        .from('user_xp_levels')
        .select('current_xp')
        .eq('user_id', userId)
        .maybeSingle();

    if (response != null) {
      return; // Already migrated
    }

    // 1. Upload achievements
    final localAchievements = await gamificationRepo.getAchievements();
    final unlockedAchievements = localAchievements.where((a) => a.unlockedAt != null).toList();
    
    if (unlockedAchievements.isNotEmpty) {
      final achievementsPayload = unlockedAchievements.map((a) => {
        'user_id': userId,
        'local_id': a.id,
        'achievement_key': a.key,
        'unlocked_at': a.unlockedAt!.toUtc().toIso8601String(),
      }).toList();
      
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
      'current_xp': xp.totalXp,
      'current_level': xp.level,
    });
  }

  Future<void> _pullFromSupabase() async {
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
        SET unlocked_at = ?, progress = max_progress
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
      final currentXp = serverXp['current_xp'] as int;
      final currentLevel = serverXp['current_level'] as int;
      
      await db.customStatement('''
        UPDATE xp_levels
        SET total_xp = ?, level = ?
        WHERE id = 'xp_level';
      ''', [currentXp, currentLevel]);
    }
  }
}
