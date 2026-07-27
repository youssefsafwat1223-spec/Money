import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:drift/drift.dart' show Variable;

import '../../../core/di/app_providers.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/sql_value_codec.dart';
import '../../../data/repositories/drift_user_settings_repository.dart';
import '../../../domain/repositories/gamification_repository.dart';
import '../../../domain/usecases/user_settings_usecases.dart';
import '../../app/app_boot_loader.dart';
import '../../capture/services/local_notification_service.dart';

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
    Future<String?> Function()? getAuthUserId,
  }) : _getAuthUserId =
            getAuthUserId ?? (() async => supabase.auth.currentUser?.id);

  final AppDatabase db;
  final SupabaseClient supabase;
  final GamificationRepository gamificationRepo;
  final Future<String?> Function() _getAuthUserId;

  Future<void> performSync() async {
    // Read fresh on every call rather than capturing at provider-construction
    // time — the provider is a long-lived singleton, but the signed-in user
    // can change (sign-out/sign-in) without it being recreated.
    final userId = await _getAuthUserId();
    if (userId == null) return;
    try {
      await _migrateLocalToSupabaseIfNeeded(userId);
    } catch (error) {
      // A bootstrap write must never suppress the authoritative pull. This is
      // especially important for existing users whose server state is valid
      // while a newly-installed client still has seeded local defaults.
      if (kDebugMode) {
        debugPrint('[GamificationSync] bootstrap push failed: $error');
      }
    }
    await _pullFromSupabase(userId);
    if (kDebugMode) debugPrint('[GamificationSync] done');
  }

  Future<void> _migrateLocalToSupabaseIfNeeded(String userId) async {
    // Bootstrap each aggregate independently. Older builds could create XP
    // and terminate before streaks/achievements, so XP alone is not proof
    // that the whole gamification bootstrap completed.
    final serverXp = await supabase
        .from('user_xp_levels')
        .select('xp')
        .eq('user_id', userId)
        .maybeSingle();

    final serverStreak = await supabase
        .from('user_streaks')
        .select('user_id')
        .eq('user_id', userId)
        .maybeSingle();

    final serverAchievements = await supabase
        .from('user_achievements')
        .select('achievement_key')
        .eq('user_id', userId)
        .isFilter('deleted_at', null);
    final serverAchievementKeys = serverAchievements
        .map((row) => row['achievement_key'] as String?)
        .whereType<String>()
        .toSet();

    // 1. Upload only achievements that are not already represented remotely.
    final localAchievements = await gamificationRepo.getAchievements();
    final unlockedAchievements = localAchievements
        .where(
          (achievement) =>
              achievement.unlockedAt != null &&
              !serverAchievementKeys.contains(achievement.key),
        )
        .toList();

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

    // 2. Upload streak only when the remote aggregate is missing.
    if (serverStreak == null) {
      final streak = await gamificationRepo.getStreak();
      await supabase.from('user_streaks').upsert({
        'user_id': userId,
        'current_streak': streak.currentStreak,
        'longest_streak': streak.longestStreak,
        'last_active_date': dateTimeToSql(streak.lastActiveDate),
      });
    }

    // 3. Upload XP only when the remote aggregate is missing.
    if (serverXp == null) {
      final xp = await gamificationRepo.getXpLevel();
      await supabase.from('user_xp_levels').upsert({
        'user_id': userId,
        'xp': xp.totalXp,
        'level': xp.level,
      });
    }
  }

  Future<void> _pullFromSupabase(String userId) async {
    // Pull Achievements
    final serverAchievements = await supabase
        .from('user_achievements')
        .select()
        .eq('user_id', userId)
        .isFilter('deleted_at', null);

    final newlyUnlockedNames = <String>[];
    for (final row in serverAchievements) {
      final key = row['achievement_key'] as String;
      final unlockedAt = DateTime.parse(row['unlocked_at'] as String).toUtc();
      // Detect the locked→unlocked transition BEFORE writing — achievements
      // unlock server-side, and this pull was the only place that learned
      // about it, silently: no notification ever fired anywhere.
      final local = await db.customSelect(
        'SELECT name_ar, unlocked_at FROM achievements WHERE key = ? LIMIT 1;',
        variables: [Variable.withString(key)],
      ).getSingleOrNull();
      final newlyUnlocked =
          local != null && local.readNullable<String>('unlocked_at') == null;
      await db.customStatement('''
        UPDATE achievements
        SET unlocked_at = ?, progress = 1.0
        WHERE key = ?;
      ''', [dateTimeToSql(unlockedAt), key]);
      if (newlyUnlocked) {
        newlyUnlockedNames.add(local.read<String>('name_ar'));
      }
    }
    // Suppressed during the post-sign-in restore (appDataRestoring): the first
    // pull re-learns EVERY previously-earned achievement at once — notifying
    // then would spam the user with their whole history.
    if (newlyUnlockedNames.isNotEmpty && !appDataRestoring.value) {
      try {
        final preferences = await LoadNotificationPreferencesUseCase(
          DriftUserSettingsRepository(db),
        ).call();
        for (final name in newlyUnlockedNames) {
          await LocalNotificationService.instance.showAchievementNotification(
            title: '🏆 إنجاز جديد: $name',
            body: 'فتحت إنجازاً جديداً — افتح قرش وشوفه.',
            preferences: preferences,
          );
        }
      } catch (error) {
        if (kDebugMode) {
          debugPrint('[GamificationSync] achievement notify skipped: $error');
        }
      }
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
