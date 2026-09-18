import '../finance/money.dart';

enum BudgetPeriod { daily, weekly, monthly, yearly }

class BudgetEntity {
  /// The early-warning threshold a budget has unless the user chooses another.
  ///
  /// 80 because that is what the Settings copy has always promised
  /// («تنبيه 80% من الميزانية» / "Alert at 80% of a budget"), and because every
  /// budget that predates this column is migrated to it — nobody's alerts move
  /// the day they update.
  static const int defaultAlertThresholdPercent = 80;

  /// The selectable range, in whole percent. 5% steps between these.
  static const int minAlertThresholdPercent = 10;
  static const int maxAlertThresholdPercent = 100;
  static const int alertThresholdStepPercent = 5;

  /// Clamps [value] onto the selectable range and step grid. Used by the form,
  /// by the repository on the way in, and by the decoder on the way out, so a
  /// value that is out of range in the database cannot produce a threshold the
  /// UI could not have chosen.
  static int normalizeAlertThreshold(int value) {
    final clamped = value.clamp(
      minAlertThresholdPercent,
      maxAlertThresholdPercent,
    );
    final snapped =
        (clamped / alertThresholdStepPercent).round() * alertThresholdStepPercent;
    return snapped.clamp(minAlertThresholdPercent, maxAlertThresholdPercent);
  }

  static const allExpensesCategoryId = '__all_expenses__';
  static const allExpensesCategoryKey = 'all_expenses';

  /// The display name of the all-expenses pseudo-category, in ONE place.
  ///
  /// It was written three times and disagreed with itself: the budget form's
  /// ARB entry said "All spending" while `CategoryView.name` and the report
  /// composer said "All expenses" — the same row, two names, both visible to
  /// one user in one session. Arabic never diverged because it only ever had
  /// one spelling.
  ///
  /// It cannot live in the ARB alone: `CategoryView` and the PDF composer have
  /// no BuildContext. `all_expenses_naming_test` asserts the ARB agrees with
  /// these.
  static const allExpensesNameAr = 'كل المصروفات';
  static const allExpensesNameEn = 'All expenses';

  const BudgetEntity({
    required this.id,
    required this.categoryId,
    required this.currency,
    required this.amountMoney,
    required this.lastNotifiedSpentMoney,
    required this.period,
    required this.startDate,
    required this.isActive,
    required this.lastNotifiedPeriodStart,
    this.showOnHeader = false,
    this.accountId,
    this.alertThresholdPercent = defaultAlertThresholdPercent,
  });

  final String id;
  final String categoryId;

  /// MALI-026 (B8-3 §15/§25) — the row's OWN canonical currency authority. For a
  /// NEW budget this is seeded from the effective base at creation; for an
  /// existing budget it is the immutable persisted value. It is NEVER re-derived
  /// from the (mutable) base currency for an existing row.
  final String currency;

  /// Canonical fixed-precision money (int64 minor units). The authoritative
  /// financial value — persistence/calculation/comparison/sync source.
  final Money amountMoney;
  final Money lastNotifiedSpentMoney;

  final BudgetPeriod period;
  final DateTime startDate;
  final bool isActive;
  final DateTime lastNotifiedPeriodStart;
  final bool showOnHeader;
  final String? accountId;

  /// When Qirsh warns about this budget, as a whole percentage of its amount.
  ///
  /// Per budget, because the answer is per budget: a grocery budget you want to
  /// hear about at 50% is not the rent budget you only want to hear about when
  /// it is nearly gone. Chosen in the budget form; [defaultAlertThresholdPercent]
  /// for a new budget and for every budget that existed before the column did.
  ///
  /// It replaces the early-warning threshold only. The 100% exceeded alert is
  /// not a warning and is not configurable — a budget you have gone past is a
  /// fact about your money, not a preference.
  final int alertThresholdPercent;

  bool get isAllExpenses => categoryId == allExpensesCategoryId;

  /// DISPLAY-ONLY compatibility getters (§7). These project canonical Money to a
  /// double for the UI and MUST NOT feed persistence / calculations / comparisons
  /// / sync / notifications / import.
  double get amount => amountMoney.toDouble();
  double get lastNotifiedSpentAmount => lastNotifiedSpentMoney.toDouble();

  BudgetEntity copyWith({
    String? id,
    String? categoryId,
    String? currency,
    Money? amountMoney,
    Money? lastNotifiedSpentMoney,
    BudgetPeriod? period,
    DateTime? startDate,
    bool? isActive,
    DateTime? lastNotifiedPeriodStart,
    bool? showOnHeader,
    String? accountId,
    int? alertThresholdPercent,
  }) {
    return BudgetEntity(
      id: id ?? this.id,
      categoryId: categoryId ?? this.categoryId,
      currency: currency ?? this.currency,
      amountMoney: amountMoney ?? this.amountMoney,
      lastNotifiedSpentMoney:
          lastNotifiedSpentMoney ?? this.lastNotifiedSpentMoney,
      period: period ?? this.period,
      startDate: startDate ?? this.startDate,
      isActive: isActive ?? this.isActive,
      lastNotifiedPeriodStart:
          lastNotifiedPeriodStart ?? this.lastNotifiedPeriodStart,
      showOnHeader: showOnHeader ?? this.showOnHeader,
      accountId: accountId ?? this.accountId,
      alertThresholdPercent:
          alertThresholdPercent ?? this.alertThresholdPercent,
    );
  }
}
