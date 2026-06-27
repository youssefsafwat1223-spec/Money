enum BillType { subscription, installment }

enum BillFrequency { weekly, monthly, yearly, custom }

enum BillStatus { active, paused, cancelled }

class BillPaymentEntity {
  const BillPaymentEntity({
    required this.id,
    required this.billId,
    required this.amount,
    required this.currency,
    required this.periodStart,
    required this.periodEnd,
    required this.paidAt,
    this.installmentIndex,
    this.transactionId,
    this.note,
  });

  final String id;
  final String billId;
  final double amount;
  final String currency;
  final DateTime periodStart;
  final DateTime periodEnd;
  final DateTime paidAt;
  final int? installmentIndex;
  final String? transactionId;
  final String? note;

  BillPaymentEntity copyWith({
    String? transactionId,
  }) {
    return BillPaymentEntity(
      id: id,
      billId: billId,
      amount: amount,
      currency: currency,
      periodStart: periodStart,
      periodEnd: periodEnd,
      paidAt: paidAt,
      installmentIndex: installmentIndex,
      transactionId: transactionId ?? this.transactionId,
      note: note,
    );
  }
}

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
    this.status = BillStatus.active,
    this.accountId,
    // installment-only fields
    this.totalInstallments,
    this.paidCount,
    this.manualPaidAmount,
    this.totalPurchaseAmount,
    this.lenderName,
    this.interestRate,
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
  final BillStatus status;
  final String? accountId;

  // installment-specific
  final int? totalInstallments;
  final int? paidCount;
  final double? manualPaidAmount;
  final double? totalPurchaseAmount;
  final String? lenderName;
  final double? interestRate;

  // derived helpers
  int get remainingInstallments =>
      (totalInstallments != null && paidCount != null)
          ? (totalInstallments! - paidCount!).clamp(0, totalInstallments!)
          : 0;

  double get installmentProgress =>
      (totalInstallments != null && totalInstallments! > 0 && paidCount != null)
          ? (paidCount! / totalInstallments!).clamp(0.0, 1.0)
          : 0.0;

  double get safeManualPaidAmount => manualPaidAmount == null
      ? 0
      : manualPaidAmount!.clamp(0.0, double.infinity).toDouble();

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
    BillStatus? status,
    String? accountId,
    int? totalInstallments,
    int? paidCount,
    double? manualPaidAmount,
    double? totalPurchaseAmount,
    String? lenderName,
    double? interestRate,
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
      status: status ?? this.status,
      accountId: accountId ?? this.accountId,
      totalInstallments: totalInstallments ?? this.totalInstallments,
      paidCount: paidCount ?? this.paidCount,
      manualPaidAmount: manualPaidAmount ?? this.manualPaidAmount,
      totalPurchaseAmount: totalPurchaseAmount ?? this.totalPurchaseAmount,
      lenderName: lenderName ?? this.lenderName,
      interestRate: interestRate ?? this.interestRate,
    );
  }
}
