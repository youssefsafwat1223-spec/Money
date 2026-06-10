import '../models/parsed_transaction.dart';
import '../models/transaction_type.dart';
import 'category.dart';
import 'category_seeds.dart';
import 'merchant_category_map.dart';

/// مصدر قرار التصنيف (للشفافية وضبط الثقة).
enum CategorySource { userMap, typeRule, keyword, fallback }

class CategoryResult {
  const CategoryResult(this.categoryKey, this.source, this.confidence);

  final String categoryKey;
  final CategorySource source;
  final double confidence;
}

/// محرّك التصنيف: merchant_map → قاعدة النوع → كلمات مفتاحية → افتراضي.
class Categorizer {
  Categorizer({MerchantCategoryMap? map}) : _map = map ?? MerchantCategoryMap();

  final MerchantCategoryMap _map;

  CategoryResult categorize(ParsedTransaction txn) {
    final merchant = txn.rawMerchant;

    // 1) تصنيف مؤكَّد من المستخدم لمتجر معروف (أعلى أولوية).
    if (merchant != null) {
      final learned = _map.lookup(merchant);
      if (learned != null) {
        return CategoryResult(learned, CategorySource.userMap, 1.0);
      }
    }

    // 2) أنواع لا تحتاج متجراً.
    switch (txn.type) {
      case TransactionType.withdrawal:
        return CategoryResult(
            Categories.cash.key, CategorySource.typeRule, 0.95);
      case TransactionType.transfer:
        return CategoryResult(
            Categories.transfers.key, CategorySource.typeRule, 0.95);
      case TransactionType.income:
        return CategoryResult(
            Categories.income.key, CategorySource.typeRule, 0.95);
      case TransactionType.payment:
      case TransactionType.refund:
      case TransactionType.unknown:
        break;
    }

    // 3) كلمات مفتاحية على اسم المتجر.
    if (merchant != null) {
      final upper = merchant.toUpperCase();
      for (final entry in CategorySeeds.keywordRules.entries) {
        if (upper.contains(entry.key.toUpperCase())) {
          return CategoryResult(entry.value, CategorySource.keyword, 0.8);
        }
      }
    }

    // 4) افتراضي.
    return CategoryResult(Categories.other.key, CategorySource.fallback, 0.3);
  }

  /// يطبّق تصحيح المستخدم على كل العمليات القادمة من نفس المتجر.
  void confirmMerchant(String rawMerchant, String categoryKey) {
    _map.learn(rawMerchant, categoryKey);
  }
}
