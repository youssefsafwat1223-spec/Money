import '../entities/transaction_entity.dart';
import '../repositories/transaction_repository.dart';
import 'engagement_usecase.dart';
import '../entities/engagement_entities.dart';

class ConfirmTransactionUseCase {
  ConfirmTransactionUseCase(
    this._transactionRepository, {
    this.recordEngagementUseCase,
  });

  final TransactionRepository _transactionRepository;
  final RecordEngagementUseCase? recordEngagementUseCase;

  Future<TransactionEntity> call(String transactionId) async {
    final transaction = await _transactionRepository.confirm(transactionId);
    if (recordEngagementUseCase != null) {
      await recordEngagementUseCase!(
        action: EngagementAction.transactionConfirmed,
        occurredAt: transaction.occurredAt,
      );
    }
    return transaction;
  }
}
