import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/domain/usecases/gamification_rules.dart';

void main() {
  group('StreakEngine', () {
    test('يحافظ على السلسلة ويستهلك freeze عند غياب يوم واحد', () {
      const engine = StreakEngine();
      final current = StreakEntity(
        id: 'streak',
        currentStreak: 4,
        longestStreak: 4,
        lastActiveDate: DateTime.utc(2026, 6, 10),
        freezesAvailable: 1,
      );

      final result = engine.recordActivity(
        current: current,
        occurredAt: DateTime.utc(2026, 6, 12),
        weeklyFreezeAllowance: 1,
        dayGap: (from, to) => to.difference(from).inDays,
        isSameWeek: (_, __) => true,
      );

      expect(result.streak.currentStreak, 5);
      expect(result.streak.freezesAvailable, 0);
    });
  });

  group('XpLevelEngine', () {
    test('يرفع المستوى عند تجاوز العتبات التراكمية', () {
      const engine = XpLevelEngine();
      const current = XpLevelEntity(
        id: 'xp',
        totalXp: 190,
        level: 1,
        levelKey: 'beginner',
      );

      final result = engine.addXp(current, 20);

      expect(result.xpLevel.totalXp, 210);
      expect(result.xpLevel.level, 2);
      expect(result.xpLevel.levelKey, 'organized');
      expect(result.didLevelUp, isTrue);
    });
  });

  group('BadgeEngine', () {
    test('يفتح شارات الميزانية والسلسلة والهدف والادخار', () {
      const engine = BadgeEngine();

      final unlocked = engine.evaluate(
        action: EngagementAction.goalMilestone,
        streakValue: 7,
        savedThisMonth: 620,
        goalProgressAfter: 1,
      );

      final keys = unlocked.map((item) => item.key).toSet();
      expect(keys.contains('streak_7_days'), isTrue);
      expect(keys.contains('first_goal'), isTrue);
      expect(keys.contains('saved_500'), isTrue);
    });
  });
}
