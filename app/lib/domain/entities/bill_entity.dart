enum BillType { subscription, installment }

enum BillFrequency { weekly, monthly, yearly, custom }

class BillEntity {
  const BillEntity({
    required this.id,
    required this.name,
    required this.amount,
    required this.currency,
    required this.type,
    required this.frequency,
    required this.nextDueDate,
    required this.reminderOn,
    required this.isConfirmed,
    required this.createdAt,
    this.merchantId,
    this.customIntervalDays,
    this.note,
  });

  final String id;
  final String name;
  final double amount;
  final String currency;
  final BillType type;
  final BillFrequency frequency;
  final DateTime nextDueDate;
  final bool reminderOn;
  final bool isConfirmed;
  final DateTime createdAt;
  final String? merchantId;
  final int? customIntervalDays;
  final String? note;

  BillEntity copyWith({
    String? id,
    String? name,
    double? amount,
    String? currency,
    BillType? type,
    BillFrequency? frequency,
    DateTime? nextDueDate,
    bool? reminderOn,
    bool? isConfirmed,
    DateTime? createdAt,
    String? merchantId,
    int? customIntervalDays,
    String? note,
  }) {
    return BillEntity(
      id: id ?? this.id,
      name: name ?? this.name,
      amount: amount ?? this.amount,
      currency: currency ?? this.currency,
      type: type ?? this.type,
      frequency: frequency ?? this.frequency,
      nextDueDate: nextDueDate ?? this.nextDueDate,
      reminderOn: reminderOn ?? this.reminderOn,
      isConfirmed: isConfirmed ?? this.isConfirmed,
      createdAt: createdAt ?? this.createdAt,
      merchantId: merchantId ?? this.merchantId,
      customIntervalDays: customIntervalDays ?? this.customIntervalDays,
      note: note ?? this.note,
    );
  }
}
