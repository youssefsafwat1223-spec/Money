class GoalEntity {
  const GoalEntity({
    required this.id,
    required this.name,
    required this.targetAmount,
    required this.savedAmount,
    required this.vaultSkin,
    required this.status,
    required this.createdAt,
    this.deadline,
  });

  final String id;
  final String name;
  final double targetAmount;
  final double savedAmount;
  final DateTime? deadline;
  final String vaultSkin;
  final String status;
  final DateTime createdAt;

  GoalEntity copyWith({
    String? id,
    String? name,
    double? targetAmount,
    double? savedAmount,
    DateTime? deadline,
    String? vaultSkin,
    String? status,
    DateTime? createdAt,
  }) {
    return GoalEntity(
      id: id ?? this.id,
      name: name ?? this.name,
      targetAmount: targetAmount ?? this.targetAmount,
      savedAmount: savedAmount ?? this.savedAmount,
      deadline: deadline ?? this.deadline,
      vaultSkin: vaultSkin ?? this.vaultSkin,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}

class GoalContributionEntity {
  const GoalContributionEntity({
    required this.id,
    required this.goalId,
    required this.amount,
    required this.createdAt,
    this.note,
  });

  final String id;
  final String goalId;
  final double amount;
  final DateTime createdAt;
  final String? note;
}
