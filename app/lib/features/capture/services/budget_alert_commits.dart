import '../../../domain/entities/transaction_entity.dart';
import '../../../domain/usecases/add_transaction_usecase.dart';

/// Only added results prove a new commit; duplicates may carry an old row.
List<TransactionEntity> newlyAddedTransactions(AddTransactionResult result) => [
      if (result.outcome == AddTransactionOutcome.added &&
          result.transaction != null)
        result.transaction!,
      if (result.secondary != null)
        ...newlyAddedTransactions(result.secondary!),
    ];
