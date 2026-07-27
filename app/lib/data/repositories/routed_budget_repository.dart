import '../../domain/entities/budget_entity.dart';
import '../../domain/repositories/budget_repository.dart';

/// S5: توجيه المرحلة-A أُزيل — غلاف رفيع يفوّض إلى Drift. المزامنة خلفية فقط.
class RoutedBudgetRepository implements BudgetRepository {
  const RoutedBudgetRepository({required BudgetRepository drift})
      : _drift = drift;

  final BudgetRepository _drift;

  @override
  Future<int> countActive() => _drift.countActive();
  @override
  Future<void> delete(String id) => _drift.delete(id);
  @override
  Future<List<BudgetEntity>> getAll() => _drift.getAll();
  @override
  Future<BudgetEntity?> getById(String id) => _drift.getById(id);
  @override
  Future<BudgetEntity> save(BudgetEntity budget) => _drift.save(budget);
}
