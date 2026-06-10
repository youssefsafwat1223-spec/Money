class AchievementDefinition {
  const AchievementDefinition(this.key, this.nameAr);

  final String key;
  final String nameAr;
}

class AchievementCatalog {
  AchievementCatalog._();

  static const firstBudget = AchievementDefinition(
    'first_budget',
    'أول ميزانية',
  );
  static const streak7Days = AchievementDefinition(
    'streak_7_days',
    '7 أيام متواصلة',
  );
  static const monthWithoutOverrun = AchievementDefinition(
    'month_without_overrun',
    'شهر بلا تجاوز',
  );
  static const saved500 = AchievementDefinition(
    'saved_500',
    'وفّرت 500',
  );
  static const firstGoal = AchievementDefinition(
    'first_goal',
    'أول هدف',
  );
  static const restaurantsMinus20 = AchievementDefinition(
    'restaurants_minus_20',
    'قللت المطاعم 20%',
  );

  static const all = [
    firstBudget,
    streak7Days,
    monthWithoutOverrun,
    saved500,
    firstGoal,
    restaurantsMinus20,
  ];
}
