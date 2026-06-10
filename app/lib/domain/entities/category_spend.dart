/// مجموع الإنفاق لتصنيف خلال فترة (لتفصيل «أين ذهبت أموالك»).
class CategorySpend {
  const CategorySpend({required this.categoryId, required this.total});

  final String categoryId;
  final double total;
}
