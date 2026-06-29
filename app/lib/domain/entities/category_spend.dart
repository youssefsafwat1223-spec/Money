/// مجموع الإنفاق لتصنيف خلال فترة (لتفصيل «أين ذهبت أموالك»).
class CategorySpend {
  const CategorySpend({
    required this.categoryId,
    required this.total,
    this.count = 0,
  });

  final String categoryId;
  final double total;
  final int count;
}
