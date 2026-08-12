import '../finance/money.dart';

/// مجموع الإنفاق لتصنيف خلال فترة (لتفصيل «أين ذهبت أموالك»). MALI-026 (B8-3
/// §16): [total] هو [Money] دقيق بعملة واحدة؛ التفصيل مُقيَّد بعملة واحدة فلا
/// يُجمَع صرف عملتين في رقم واحد ولا تُحسَب نسبة عبر عملات مختلفة.
class CategorySpend {
  const CategorySpend({
    required this.categoryId,
    required this.total,
    this.count = 0,
  });

  final String categoryId;
  final Money total;
  final int count;
}
