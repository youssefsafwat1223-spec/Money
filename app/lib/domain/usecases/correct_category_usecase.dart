import '../../engine/categorization/categorizer.dart';
import '../../engine/categorization/merchant_category_map.dart';
import '../entities/engagement_entities.dart';
import '../entities/transaction_entity.dart';
import '../repositories/merchant_category_repository.dart';
import '../repositories/transaction_repository.dart';
import 'engagement_usecase.dart';

enum CategoryCorrectionScope { thisTransactionOnly, allMerchantTransactions }

class CorrectCategoryUseCase {
  CorrectCategoryUseCase({
    required TransactionRepository transactionRepository,
    required MerchantCategoryRepository merchantCategoryRepository,
    this.recordEngagementUseCase,
  })  : _transactionRepository = transactionRepository,
        _merchantCategoryRepository = merchantCategoryRepository;

  final TransactionRepository _transactionRepository;
  final MerchantCategoryRepository _merchantCategoryRepository;
  final RecordEngagementUseCase? recordEngagementUseCase;

  Future<TransactionEntity> call({
    required String transactionId,
    required String categoryKey,
    required CategoryCorrectionScope scope,
  }) async {
    final updated = await _transactionRepository.updateCategory(
      transactionId: transactionId,
      categoryKey: categoryKey,
    );

    if (scope == CategoryCorrectionScope.allMerchantTransactions &&
        updated.rawMerchant != null) {
      final learnedMap =
          await _merchantCategoryRepository.getLearnedCategoryMap();
      final categorizer = Categorizer(map: MerchantCategoryMap(learnedMap));
      categorizer.confirmMerchant(updated.rawMerchant!, categoryKey);
      await _merchantCategoryRepository.confirmMerchantCategory(
        rawMerchant: updated.rawMerchant!,
        categoryKey: categoryKey,
        isUserConfirmed: true,
      );
    }

    if (recordEngagementUseCase != null) {
      await recordEngagementUseCase!(
        action: EngagementAction.categoryCorrected,
        occurredAt: updated.updatedAt,
      );
    }

    return updated;
  }
}
