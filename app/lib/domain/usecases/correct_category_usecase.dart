import '../../engine/categorization/categorizer.dart';
import '../../engine/categorization/merchant_category_map.dart';
import '../../engine/intelligence/merchant_intelligence_store.dart';
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
    // OD-13: the on-device model that should learn from this correction.
    // Optional — when absent the correction still persists exactly as before,
    // so the model is never load-bearing for a user action.
    MerchantIntelligenceStore? merchantIntelligence,
  })  : _transactionRepository = transactionRepository,
        _merchantCategoryRepository = merchantCategoryRepository,
        _merchantIntelligence = merchantIntelligence;

  final TransactionRepository _transactionRepository;
  final MerchantCategoryRepository _merchantCategoryRepository;
  final MerchantIntelligenceStore? _merchantIntelligence;
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
      // OD-13 — the ONLY place the on-device model learns.
      //
      // Deliberately confined to `allMerchantTransactions`: that scope IS the
      // user saying "this merchant means this category". `thisTransactionOnly`
      // is the user saying the opposite — a one-off — so teaching the model
      // from it would contradict the choice they just made.
      //
      // Ordering matters: the durable write above is the source of truth, and
      // the in-memory model is updated only after it succeeds. If the write
      // throws, the model is not taught something that was never persisted.
      _merchantIntelligence?.learnFromUserCorrection(
        updated.rawMerchant!,
        categoryKey,
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
