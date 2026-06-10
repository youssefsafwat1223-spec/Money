abstract class MerchantCategoryRepository {
  Future<Map<String, String>> getLearnedCategoryMap();
  Future<bool> hasCategoryForMerchant(String rawMerchant);
  Future<void> confirmMerchantCategory({
    required String rawMerchant,
    required String categoryKey,
    required bool isUserConfirmed,
    double confidence = 1,
  });
}
