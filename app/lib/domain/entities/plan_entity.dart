enum PlanStatus { active, closed }

/// A temporary spending plan / envelope for an event (travel, wedding, Ramadan…)
/// with its own budget and date range. Transactions in that range from the
/// chosen accounts/cards count toward it (membership is computed dynamically).
class PlanEntity {
  const PlanEntity({
    required this.id,
    required this.name,
    required this.budgetAmount,
    required this.currency,
    required this.startDate,
    required this.endDate,
    required this.accountIds,
    required this.cardLast4s,
    required this.status,
    required this.createdAt,
    this.icon,
  });

  final String id;
  final String name;
  final double budgetAmount;
  final String currency;
  final DateTime startDate;
  final DateTime endDate;
  final List<String> accountIds;
  final List<String> cardLast4s;
  final PlanStatus status;
  final DateTime createdAt;
  final String? icon;

  bool get isOngoing {
    final now = DateTime.now();
    return status == PlanStatus.active &&
        !now.isBefore(startDate) &&
        !now.isAfter(endDate);
  }

  /// Days remaining (inclusive of today), 0 once the end date has passed.
  int get daysLeft {
    final diff = endDate.difference(DateTime.now()).inDays;
    return diff < 0 ? 0 : diff + 1;
  }

  PlanEntity copyWith({
    String? name,
    double? budgetAmount,
    String? currency,
    DateTime? startDate,
    DateTime? endDate,
    List<String>? accountIds,
    List<String>? cardLast4s,
    PlanStatus? status,
    String? icon,
  }) {
    return PlanEntity(
      id: id,
      name: name ?? this.name,
      budgetAmount: budgetAmount ?? this.budgetAmount,
      currency: currency ?? this.currency,
      startDate: startDate ?? this.startDate,
      endDate: endDate ?? this.endDate,
      accountIds: accountIds ?? this.accountIds,
      cardLast4s: cardLast4s ?? this.cardLast4s,
      status: status ?? this.status,
      createdAt: createdAt,
      icon: icon ?? this.icon,
    );
  }
}
