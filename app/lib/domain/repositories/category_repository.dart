import '../entities/category_entity.dart';

abstract class CategoryRepository {
  Future<List<CategoryEntity>> getAll();
  Future<CategoryEntity> createCategory({
    required String nameAr,
    required String icon,
    required String color,
    required bool isIncome,
  });
  Future<CategoryEntity> updateCategory(CategoryEntity category);
  Future<void> deleteCategory(String id);
}
