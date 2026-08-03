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
    // MALI-024 — the client is PULL-ONLY for gamification aggregates. It never
    // uploads an XP/streak/achievement total (that was the dual-authority tamper
    // vector). The server is authoritative: it awards from engagement events
    // (record_engagement_event RPC, submitted by EngagementEventService) and the
    // server-side evaluation of synced domain records. The client only mirrors
    // the acknowledged server aggregate.
    await _pullFromSupabase(userId);
    if (kDebugMode) debugPrint('[GamificationSync] done');
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
        // xp_levels/streaks are singleton rows seeded with a generated id (the
        // repo reads them via LIMIT 1), so target the single row directly — the
        // old `WHERE id='streak'` matched nothing, so the acknowledged server
        // aggregate never reached the local display.
        await db.customStatement('''
          UPDATE streaks
          SET current_streak = ?, longest_streak = ?, last_active_date = ?;
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
        SET total_xp = ?, level = ?;
      ''', [currentXp, currentLevel]);
    }
  }
}
