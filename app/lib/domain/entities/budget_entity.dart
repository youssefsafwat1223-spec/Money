import '../finance/money.dart';

enum BudgetPeriod { daily, weekly, monthly, yearly }

class BudgetEntity {
  static const allExpensesCategoryId = '__all_expenses__';
  static const allExpensesCategoryKey = 'all_expenses';

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
    );
  }
}
