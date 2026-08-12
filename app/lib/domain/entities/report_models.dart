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

/// اشتراك متكرر مُكتشَف (نفس المتجر بمبلغ متقارب عبر أشهر). [averageAmount] قيمة
/// إرشادية (متوسط اكتشاف التكرار) تبقى double — ليست مبلغاً مالياً دقيقاً يُخزَّن
/// أو يُقارَن كـ Money (B8-3 §14).
class RecurringCandidate {
  const RecurringCandidate({
    required this.merchantId,
    required this.name,
    required this.averageAmount,
    required this.currency,
    required this.monthsSeen,
  });

  final String merchantId;
  final String name;

  /// HEURISTIC recurrence-stability average (display estimate) — NOT canonical
  /// Money. Scoped to [currency] so a cross-currency total is never folded.
  final double averageAmount;
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
