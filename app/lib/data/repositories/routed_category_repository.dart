import '../../domain/entities/category_entity.dart';
import '../../domain/repositories/category_repository.dart';

class RoutedCategoryRepository implements CategoryRepository {
  RoutedCategoryRepository({required CategoryRepository drift})
      : _drift = drift;

  final CategoryRepository _drift;

  // S0: الواجهة تقرأ وتكتب من Drift دائمًا. مزامنة الفئات المخصّصة إلى Supabase
  // تُدقَّق وتُضاف في S3 (كمزامنة خلفية، لا قراءة مباشرة من الواجهة).
  CategoryRepository get _active => _drift;

  @override
  Future<List<CategoryEntity>> getAll() => _active.getAll();

  @override
  Future<CategoryEntity> createCategory({
    required String nameAr,
    required String icon,
    required String color,
    required bool isIncome,
  }) =>
      _active.createCategory(
        nameAr: nameAr,
        icon: icon,
        color: color,
        isIncome: isIncome,
      );

  @override
  Future<CategoryEntity> updateCategory(CategoryEntity category) =>
      _active.updateCategory(category);

  @override
  Future<void> deleteCategory(String id) => _active.deleteCategory(id);
}
