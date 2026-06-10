import '../entities/budget_entity.dart';

abstract class BudgetRepository {
  Future<BudgetEntity> save(BudgetEntity budget);
  Future<List<BudgetEntity>> getAll();
  Future<BudgetEntity?> getById(String id);
  Future<int> countActive();
  Future<void> delete(String id);
}
