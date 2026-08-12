import '../finance/money.dart';

/// مجموع إنفاق متجر خلال فترة (لأكثر المتاجر صرفاً). MALI-026 (B8-3 §16):
/// [total] هو [Money] دقيق بعملة واحدة (لا تُجمع عملتان في رقم واحد).
class MerchantSpend {
  const MerchantSpend({
    required this.name,
    required this.total,
    this.count = 0,
  });

  final String name;
  final Money total;
  final int count;
}

/// اشتراك متكرر مُكتشَف (نفس المتجر بمبلغ متقارب عبر أشهر). MALI-026 (B8-3 §16
/// correction): the MONETARY estimate ([estimatedAmountMoney]) is EXACT Money
/// (SUM(minor)/count, rounded half-away-from-zero once) in [currency] — an
/// estimate is still a Money-denominated value. The recurrence-STABILITY decision
/// (the 15% rule) stays a separate integer/heuristic gate in the query, not a
/// floating money amount.
class RecurringCandidate {
  const RecurringCandidate({
    required this.merchantId,
    required this.name,
    required this.estimatedAmountMoney,
    required this.currency,
    required this.monthsSeen,
  });

  final String merchantId;
  final String name;

  /// Exact monthly monetary estimate (avg payment) in [currency]. Non-authoritative
  /// (it's an estimate) but exactly represented — never a lossy double.
  final Money estimatedAmountMoney;
  final String currency;
  final int monthsSeen;
}

/// إجمالي المصروف في يوم واحد, يستخدم لرسم Insights اليومي. MALI-026 (B8-3 §16):
/// [total] هو [Money] دقيق بعملة واحدة؛ يُحوَّل إلى double فقط عند إحداثي الرسم.
class DailySpend {
  const DailySpend({required this.day, required this.total});

  final DateTime day;
  final Money total;
}

/// إجمالي المصروف والدخل لعملة واحدة — لعرض «كل الحسابات» بعملات منفصلة
/// (بدون جمع عملات مختلفة في رقم واحد). MALI-026 (B8-3 §16): [expense]/[income]
/// هما [Money] دقيقان بـ [currency]؛ لا تُدمَج عملتان في إجمالي واحد.
class CurrencyTotal {
  const CurrencyTotal({
    required this.currency,
    required this.expense,
    required this.income,
  });

  final String currency;
  final Money expense;
  final Money income;
}
