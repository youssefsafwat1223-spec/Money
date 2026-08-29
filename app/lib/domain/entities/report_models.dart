import '../finance/money.dart';

/// مجموع إنفاق متجر خلال فترة (لأكثر المتاجر صرفاً). MALI-026 (B8-3 §16):
/// [total] هو [Money] دقيق بعملة واحدة (لا تُجمع عملتان في رقم واحد).
class MerchantSpend {
  const MerchantSpend({
    required this.name,
    required this.total,
    this.count = 0,
    this.refunds,
  });

  final String name;

  /// The NET figure — the documented `payments + withdrawals − refunds`
  /// contract. Unchanged by UX-022; only explained by it.
  final Money total;
  final int count;

  /// UX-022 — the refund magnitude folded into [total], when there is one.
  ///
  /// The QA's row read «نون · 1,700.00 · 2 عمليات» and neither transaction was
  /// 1,700: an expense of 1,899 and a refund of 199. The `COUNT(*)` was not
  /// wrong — a refund IS one of the transactions the total is built from — but
  /// pairing a netted amount with a raw count and no refund left the implied
  /// average meaningless.
  ///
  /// Null (not zero) when the caller did not ask for it, so "not queried" and
  /// "queried, no refunds" stay distinguishable.
  final Money? refunds;

  bool get hasRefunds => (refunds?.minorUnits ?? 0) > 0;
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

  /// Net spend for the day. UX-022: this goes NEGATIVE on a day whose refunds
  /// exceed its spending — a real state that the chart used to render as an
  /// unexplained downward bar.
  final Money total;

  bool get isRefundDay => total.minorUnits < 0;
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
