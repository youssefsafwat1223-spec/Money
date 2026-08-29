import '../finance/money.dart';

/// مجموع الإنفاق لتصنيف خلال فترة (لتفصيل «أين ذهبت أموالك»). MALI-026 (B8-3
/// §16): [total] هو [Money] دقيق بعملة واحدة؛ التفصيل مُقيَّد بعملة واحدة فلا
/// يُجمَع صرف عملتين في رقم واحد ولا تُحسَب نسبة عبر عملات مختلفة.
class CategorySpend {
  const CategorySpend({
    required this.categoryId,
    required this.total,
    this.count = 0,
    this.refunds,
  });

  final String categoryId;

  /// The NET figure. The contract is unchanged by UX-022; only explained.
  final Money total;
  final int count;

  /// UX-022 — the refund magnitude folded into [total], when there is one.
  /// The QA's case: تسوق displayed 1,700.00, which matched no transaction.
  /// Null when not queried, so that stays distinguishable from "no refunds".
  final Money? refunds;

  bool get hasRefunds => (refunds?.minorUnits ?? 0) > 0;
}
