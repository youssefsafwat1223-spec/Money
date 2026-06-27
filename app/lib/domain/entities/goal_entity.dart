class GoalEntity {
  const GoalEntity({
    required this.id,
    required this.name,
    required this.targetAmount,
    required this.savedAmount,
    required this.vaultSkin,
    required this.status,
    required this.createdAt,
    this.accountId,
    this.deadline,
    this.autoSaveAmount,
    this.autoSavePeriod,
    this.autoSaveLastRun,
  });

  final String id;
  final String name;
  final String? accountId;
  final double targetAmount;
  final double savedAmount;
  final DateTime? deadline;
  final String vaultSkin;
  final String status;
  final DateTime createdAt;

  /// Fixed recurring auto-save: [autoSaveAmount] is added every
  /// [autoSavePeriod] ('weekly' / 'monthly'). Null/0 means off.
  final double? autoSaveAmount;
  final String? autoSavePeriod;
  final DateTime? autoSaveLastRun;

  bool get hasAutoSave =>
      (autoSaveAmount ?? 0) > 0 && autoSavePeriod != null;

  GoalEntity copyWith({
    String? id,
    String? name,
    double? targetAmount,
    double? savedAmount,
    String? accountId,
    DateTime? deadline,
    String? vaultSkin,
    String? status,
    DateTime? createdAt,
    double? autoSaveAmount,
    String? autoSavePeriod,
    DateTime? autoSaveLastRun,
  }) {
    return GoalEntity(
      id: id ?? this.id,
      name: name ?? this.name,
      accountId: accountId ?? this.accountId,
      targetAmount: targetAmount ?? this.targetAmount,
      savedAmount: savedAmount ?? this.savedAmount,
      deadline: deadline ?? this.deadline,
      vaultSkin: vaultSkin ?? this.vaultSkin,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      autoSaveAmount: autoSaveAmount ?? this.autoSaveAmount,
      autoSavePeriod: autoSavePeriod ?? this.autoSavePeriod,
      autoSaveLastRun: autoSaveLastRun ?? this.autoSaveLastRun,
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
