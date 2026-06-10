class CategoryEntity {
  const CategoryEntity({
    required this.id,
    required this.key,
    required this.nameAr,
    required this.icon,
    required this.color,
    required this.isIncome,
    required this.sort,
  });

  final String id;
  final String key;
  final String nameAr;
  final String icon;
  final String color;
  final bool isIncome;
  final int sort;
}
