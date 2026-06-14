enum BudgetPeriod { daily, weekly, monthly }

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
    required this.alert80Sent,
    required this.alert100Sent,
    this.showOnHeader = false,
    this.accountId,
  });

  final String id;
  final String categoryId;
  final double amount;
  final BudgetPeriod period;
  final DateTime startDate;
  final bool isActive;
  final bool alert80Sent;
  final bool alert100Sent;
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
    bool? alert80Sent,
    bool? alert100Sent,
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
      alert80Sent: alert80Sent ?? this.alert80Sent,
      alert100Sent: alert100Sent ?? this.alert100Sent,
      showOnHeader: showOnHeader ?? this.showOnHeader,
      accountId: accountId ?? this.accountId,
    );
  }
}
