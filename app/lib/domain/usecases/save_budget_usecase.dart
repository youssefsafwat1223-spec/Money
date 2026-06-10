import '../entities/budget_entity.dart';
import '../repositories/budget_repository.dart';
import 'engagement_usecase.dart';
import '../entities/engagement_entities.dart';

class SaveBudgetUseCase {
  SaveBudgetUseCase(
    this._budgetRepository, {
    this.recordEngagementUseCase,
  });

  final BudgetRepository _budgetRepository;
  final RecordEngagementUseCase? recordEngagementUseCase;

  Future<BudgetEntity> call(BudgetEntity budget) async {
    final existing = await _budgetRepository.getById(budget.id);
    final beforeCount = await _budgetRepository.countActive();
    final saved = await _budgetRepository.save(budget);
    if (existing == null &&
        beforeCount == 0 &&
        recordEngagementUseCase != null) {
      await recordEngagementUseCase!(
        action: EngagementAction.firstBudgetCreated,
        occurredAt: saved.startDate,
      );
    }
    return saved;
  }
}

class DeleteBudgetUseCase {
  DeleteBudgetUseCase(this._budgetRepository);

  final BudgetRepository _budgetRepository;

  Future<void> call(String budgetId) {
    return _budgetRepository.delete(budgetId);
  }
}
