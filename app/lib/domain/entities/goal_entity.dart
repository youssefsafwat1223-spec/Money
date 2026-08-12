import '../finance/money.dart';

class GoalEntity {
  const GoalEntity({
    required this.id,
    required this.name,
    required this.currency,
    required this.targetMoney,
    required this.savedMoney,
    required this.lastNotifiedSavedMoney,
    required this.vaultSkin,
    required this.status,
    required this.createdAt,
    this.accountId,
    this.deadline,
    this.autoSaveMoney,
    this.autoSavePeriod,
    this.autoSaveLastRun,
  });

  final String id;
  final String name;
  final String? accountId;

  /// MALI-026 (B8-3 §15/§25) — the goal's OWN canonical currency authority
  /// (seeded from base at creation; immutable for an existing goal; never
  /// re-derived from the mutable base). Goal contributions inherit THIS currency.
  final String currency;

  final Money targetMoney;
  final Money savedMoney;
  final Money lastNotifiedSavedMoney;
  final DateTime? deadline;
  final String vaultSkin;
  final String status;
  final DateTime createdAt;

  /// Fixed recurring auto-save: [autoSaveMoney] is added every [autoSavePeriod]
  /// ('weekly' / 'monthly'). Null/zero means off.
  final Money? autoSaveMoney;
  final String? autoSavePeriod;
  final DateTime? autoSaveLastRun;

  bool get hasAutoSave =>
      (autoSaveMoney?.minorUnits ?? 0) > 0 && autoSavePeriod != null;

  /// DISPLAY-ONLY compatibility getters (§7) — never feed logic/persistence.
  double get targetAmount => targetMoney.toDouble();
  double get savedAmount => savedMoney.toDouble();
  double get lastNotifiedSavedAmount => lastNotifiedSavedMoney.toDouble();
  double? get autoSaveAmount => autoSaveMoney?.toDouble();

  GoalEntity copyWith({
    String? id,
    String? name,
    String? currency,
    Money? targetMoney,
    Money? savedMoney,
    Money? lastNotifiedSavedMoney,
    String? accountId,
    DateTime? deadline,
    String? vaultSkin,
    String? status,
    DateTime? createdAt,
    Money? autoSaveMoney,
    String? autoSavePeriod,
    DateTime? autoSaveLastRun,
  }) {
    return GoalEntity(
      id: id ?? this.id,
      name: name ?? this.name,
      currency: currency ?? this.currency,
      accountId: accountId ?? this.accountId,
      targetMoney: targetMoney ?? this.targetMoney,
      savedMoney: savedMoney ?? this.savedMoney,
      lastNotifiedSavedMoney:
          lastNotifiedSavedMoney ?? this.lastNotifiedSavedMoney,
      deadline: deadline ?? this.deadline,
      vaultSkin: vaultSkin ?? this.vaultSkin,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      autoSaveMoney: autoSaveMoney ?? this.autoSaveMoney,
      autoSavePeriod: autoSavePeriod ?? this.autoSavePeriod,
      autoSaveLastRun: autoSaveLastRun ?? this.autoSaveLastRun,
    );
  }
}

class GoalContributionEntity {
  const GoalContributionEntity({
    required this.id,
    required this.goalId,
    required this.amountMoney,
    required this.createdAt,
    this.note,
  });

  final String id;
  final String goalId;

  /// Canonical money; its currency is the PARENT GOAL's currency (§14) — a
  /// contribution has NO independent currency field.
  final Money amountMoney;
  final DateTime createdAt;
  final String? note;

  /// DISPLAY-ONLY (§7).
  double get amount => amountMoney.toDouble();
}
