class AchievementDefinition {
  const AchievementDefinition(this.key, this.nameAr, this.nameEn);

  final String key;
  final String nameAr;
  final String nameEn;

  /// The catalog stays `const` — these nine names are a fixed vocabulary
  /// shared with the server, not editable copy — so the pair travels with the
  /// definition instead of going through the ARB.
  String name(String languageCode) => languageCode == 'en' ? nameEn : nameAr;
}

/// F-023 / OD-03 — the single achievement vocabulary shared by both sides.
///
/// The client and server previously defined DISJOINT sets: the server awards
/// `first_transaction` / `tenth_transaction` / `century_transaction`
/// (`0074_gamification_atomic_award.sql`), the client defined six unrelated
/// keys, and the intersection was empty. Every server award therefore landed on
/// a missing local row and was dropped silently — no update, no notification,
/// no error.
///
/// Per OD-03 the canonical contract is the UNION, not one side winning: both
/// sets are legitimate product features. A key that exists here is one the
/// client can represent; `gamification_vocabulary_test` asserts the server's
/// award list against the migration itself, so a new server key cannot be added
/// without a local row to receive it.
class AchievementCatalog {
  AchievementCatalog._();

  // ── Server-awarded (public.award_gamification_for_transaction) ────────────
  static const firstTransaction = AchievementDefinition(
    'first_transaction',
    'أول عملية',
    'First transaction',
  );
  static const tenthTransaction = AchievementDefinition(
    'tenth_transaction',
    '10 عمليات',
    '10 transactions',
  );
  static const centuryTransaction = AchievementDefinition(
    'century_transaction',
    '100 عملية',
    '100 transactions',
  );

  static const firstBudget = AchievementDefinition(
    'first_budget',
    'أول ميزانية',
    'First budget',
  );
  static const streak7Days = AchievementDefinition(
    'streak_7_days',
    '7 أيام متواصلة',
    '7-day streak',
  );
  static const monthWithoutOverrun = AchievementDefinition(
    'month_without_overrun',
    'شهر بلا تجاوز',
    'A month under budget',
  );
  static const saved500 = AchievementDefinition(
    'saved_500',
    'وفّرت 500',
    'Saved 500',
  );
  static const firstGoal = AchievementDefinition(
    'first_goal',
    'أول هدف',
    'First goal',
  );
  static const restaurantsMinus20 = AchievementDefinition(
    'restaurants_minus_20',
    'قللت المطاعم 20%',
    'Restaurants down 20%',
  );

  /// The persisted `AchievementEntity` carries only `nameAr` (the row was
  /// written before the catalog was bilingual). Look the English name up by
  /// key rather than migrating every stored row; the key is the contract the
  /// server already awards against.
  static String displayName(String key, String nameAr, String languageCode) {
    if (languageCode != 'en') return nameAr;
    for (final d in all) {
      if (d.key == key) return d.nameEn;
    }
    return nameAr;
  }

  static const all = [
    firstTransaction,
    tenthTransaction,
    centuryTransaction,
    firstBudget,
    streak7Days,
    monthWithoutOverrun,
    saved500,
    firstGoal,
    restaurantsMinus20,
  ];
}
