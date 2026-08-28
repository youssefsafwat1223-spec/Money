import '../entities/achievement_catalog.dart';
import '../entities/engagement_entities.dart';
import '../entities/supporting_entities.dart';

class StreakUpdate {
  const StreakUpdate({
    required this.streak,
    required this.reachedMilestone,
  });

  final StreakEntity streak;
  final int? reachedMilestone;
}

class StreakEngine {
  const StreakEngine();

  StreakUpdate recordActivity({
    required StreakEntity current,
    required DateTime occurredAt,
    required int weeklyFreezeAllowance,
    required int Function(DateTime from, DateTime to) dayGap,
    required bool Function(DateTime a, DateTime b) isSameWeek,
  }) {
    var streak = current;
    if (!isSameWeek(current.lastActiveDate, occurredAt)) {
      streak = streak.copyWith(freezesAvailable: weeklyFreezeAllowance);
    }

    final gap = dayGap(streak.lastActiveDate, occurredAt);
    if (gap <= 0) {
      return StreakUpdate(streak: streak, reachedMilestone: null);
    }

    var nextStreak = 1;
    var freezes = streak.freezesAvailable;
    if (gap == 1) {
      nextStreak = streak.currentStreak + 1;
    } else if (gap == 2 && freezes > 0) {
      freezes -= 1;
      nextStreak = streak.currentStreak + 1;
    }

    final updated = streak.copyWith(
      currentStreak: nextStreak,
      longestStreak:
          nextStreak > streak.longestStreak ? nextStreak : streak.longestStreak,
      lastActiveDate: occurredAt,
      freezesAvailable: freezes,
    );

    final milestone = switch (updated.currentStreak) {
      7 => 7,
      30 => 30,
      100 => 100,
      _ => null,
    };
    return StreakUpdate(streak: updated, reachedMilestone: milestone);
  }
}

class XpLevelResult {
  const XpLevelResult({
    required this.xpLevel,
    required this.didLevelUp,
  });

  final XpLevelEntity xpLevel;
  final bool didLevelUp;
}

class XpLevelEngine {
  const XpLevelEngine();

  static const thresholds = <int>[0, 200, 600, 1500, 3500];
  static const levelKeys = <String>[
    'beginner',
    'organized',
    'smart_saver',
    'financial_expert',
    'saving_legend',
  ];

  /// F-022 / OD-03 — the label for ANY level, including one the server produced.
  ///
  /// The server curve is UNBOUNDED (`floor(sqrt(xp/100)) + 1`), while these
  /// tiers are a fixed list of five. A naive `levelKeys[level - 1]` therefore
  /// throws RangeError on a server level of 6 or more — reachable at 3600 XP.
  ///
  /// Clamping is the honest mapping: a level past the top tier is still a real
  /// level, and the user has genuinely earned the highest title we define. It is
  /// never a reason to crash or to show nothing.
  static String levelKeyForLevel(int level) {
    if (level <= 1) return levelKeys.first;
    if (level >= levelKeys.length) return levelKeys.last;
    return levelKeys[level - 1];
  }

  XpLevelResult addXp(XpLevelEntity current, int amount) {
    final total = current.totalXp + amount;
    var level = 1;
    for (var index = thresholds.length - 1; index >= 0; index--) {
      if (total >= thresholds[index]) {
        level = index + 1;
        break;
      }
    }
    final updated = current.copyWith(
      totalXp: total,
      level: level,
      levelKey: levelKeys[level - 1],
    );
    return XpLevelResult(
      xpLevel: updated,
      didLevelUp: updated.level > current.level,
    );
  }
}

class BadgeEngine {
  const BadgeEngine();

  List<AchievementDefinition> evaluate({
    required EngagementAction action,
    required int streakValue,
    double? savedThisMonth,
    double? goalProgressAfter,
  }) {
    final unlocked = <AchievementDefinition>[];
    if (action == EngagementAction.firstBudgetCreated) {
      unlocked.add(AchievementCatalog.firstBudget);
    }
    if (streakValue >= 7) {
      unlocked.add(AchievementCatalog.streak7Days);
    }
    if ((goalProgressAfter ?? 0) >= 1) {
      unlocked.add(AchievementCatalog.firstGoal);
    }
    if ((savedThisMonth ?? 0) >= 500) {
      unlocked.add(AchievementCatalog.saved500);
    }
    return unlocked;
  }
}
