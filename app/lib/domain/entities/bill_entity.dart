import '../finance/money.dart';

enum BillType { subscription, installment }

enum BillFrequency { weekly, monthly, yearly, custom }

enum BillStatus { active, paused, cancelled }

class BillPaymentEntity {
  const BillPaymentEntity({
    required this.id,
    required this.billId,
    required this.amountMoney,
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
  final Money amountMoney;

  /// DISPLAY-ONLY compatibility getter. Persisted calculations and writes use
  /// [amountMoney].
  double get amount => amountMoney.toDouble();
  final String currency;
  final DateTime periodStart;
  final DateTime periodEnd;
  final DateTime paidAt;
  final int? installmentIndex;
  final String? transactionId;
  final String? note;

  BillPaymentEntity copyWith({
    Money? amountMoney,
    String? transactionId,
  }) {
    return BillPaymentEntity(
      id: id,
      billId: billId,
      amountMoney: amountMoney ?? this.amountMoney,
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
    required this.amountMoney,
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
    this.manualPaidMoney,
    this.totalPurchaseMoney,
    this.lenderName,
    this.interestRate,
  });

  final String id;
  final String name;
  final Money amountMoney;

  /// DISPLAY-ONLY compatibility getter. Persisted calculations and writes use
  /// [amountMoney].
  double get amount => amountMoney.toDouble();
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
  final Money? manualPaidMoney;
  final Money? totalPurchaseMoney;

  /// DISPLAY-ONLY compatibility getters. Persisted calculations and writes use
  /// the corresponding `*Money` fields.
  double? get manualPaidAmount => manualPaidMoney?.toDouble();
  double? get totalPurchaseAmount => totalPurchaseMoney?.toDouble();
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

  /// صحيح إذا كان الاشتراك يبدو غير مستخدم — لم يُسجَّل دفع منذ أطول من دورة ونصف.
  bool get mightBeUnused {
    if (type != BillType.subscription || status != BillStatus.active) {
      return false;
    }
    final periodDays = switch (frequency) {
      BillFrequency.weekly => 7,
      BillFrequency.monthly => 30,
      BillFrequency.yearly => 365,
      BillFrequency.custom => customIntervalDays ?? 30,
    };
    final daysPast = DateTime.now().difference(nextDueDate).inDays;
    return daysPast > (periodDays * 1.5).round();
  }

  double get safeManualPaidAmount => manualPaidAmount == null
      ? 0
      : manualPaidAmount!.clamp(0.0, double.infinity).toDouble();

  BillEntity copyWith({
    String? id,
    String? name,
    Money? amountMoney,
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
    Money? manualPaidMoney,
    Money? totalPurchaseMoney,
    String? lenderName,
    double? interestRate,
  }) {
    return BillEntity(
      id: id ?? this.id,
      name: name ?? this.name,
      amountMoney: amountMoney ?? this.amountMoney,
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
      manualPaidMoney: manualPaidMoney ?? this.manualPaidMoney,
      totalPurchaseMoney: totalPurchaseMoney ?? this.totalPurchaseMoney,
      lenderName: lenderName ?? this.lenderName,
      interestRate: interestRate ?? this.interestRate,
    );
  }
}
