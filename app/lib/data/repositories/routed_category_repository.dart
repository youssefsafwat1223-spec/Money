import '../../data/catalog/feature_flag_service.dart';
import '../../domain/entities/category_entity.dart';
import '../../domain/repositories/category_repository.dart';

class RoutedCategoryRepository implements CategoryRepository {
  RoutedCategoryRepository({
    required CategoryRepository drift,
    required CategoryRepository supabase,
    required FeatureFlagService Function() flags,
  })  : _drift = drift,
        _supabase = supabase,
        _flags = flags;

  final CategoryRepository _drift;
  final CategoryRepository _supabase;
  final FeatureFlagService Function() _flags;

  bool get _useSupabase {
    final flags = _flags();
    return flags.getBool('transactions_supabase_primary') ||
        flags.getBool('budgets_supabase_primary');
  }

  CategoryRepository get _active => _useSupabase ? _supabase : _drift;

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
