enum BudgetPeriod { daily, weekly, monthly, yearly }

class BudgetEntity {
  static const allExpensesCategoryId = '__all_expenses__';
  static const allExpensesCategoryKey = 'all_expenses';

  const BudgetEntity({
    required this.id,
    required this.categoryId,
    required this.amount,
    required this.period,
    required this.startDate,
    required this.isActive,
    required this.lastNotifiedSpentAmount,
    required this.lastNotifiedPeriodStart,
    this.showOnHeader = false,
    this.accountId,
  });

  final String id;
  final String categoryId;
  final double amount;
  final BudgetPeriod period;
  final DateTime startDate;
  final bool isActive;
  final double lastNotifiedSpentAmount;
  final DateTime lastNotifiedPeriodStart;
  final bool showOnHeader;
  final String? accountId;

  bool get isAllExpenses => categoryId == allExpensesCategoryId;

  BudgetEntity copyWith({
    String? id,
    String? categoryId,
    double? amount,
    BudgetPeriod? period,
    DateTime? startDate,
    bool? isActive,
    double? lastNotifiedSpentAmount,
    DateTime? lastNotifiedPeriodStart,
    bool? showOnHeader,
    String? accountId,
  }) {
    return BudgetEntity(
      id: id ?? this.id,
      categoryId: categoryId ?? this.categoryId,
      amount: amount ?? this.amount,
      period: period ?? this.period,
      startDate: startDate ?? this.startDate,
      isActive: isActive ?? this.isActive,
      lastNotifiedSpentAmount:
          lastNotifiedSpentAmount ?? this.lastNotifiedSpentAmount,
      lastNotifiedPeriodStart:
          lastNotifiedPeriodStart ?? this.lastNotifiedPeriodStart,
      showOnHeader: showOnHeader ?? this.showOnHeader,
      accountId: accountId ?? this.accountId,
    );
  }
}
