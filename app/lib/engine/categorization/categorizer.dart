import 'dart:math' as math;

import '../../data/catalog/catalog_daos.dart';
import '../models/parsed_transaction.dart';
import '../models/transaction_type.dart';
import 'category.dart';
import '../intelligence/merchant_classifier.dart';
import 'category_seeds.dart';
import 'merchant_category_map.dart';

/// مصدر قرار التصنيف (للشفافية وضبط الثقة).
/// OD-13: `model` is a SUGGESTION source. It ranks below every deterministic
/// source and above the give-up fallback, and it never carries confidence 1.0 —
/// a model result must stay distinguishable from a user's own decision.
enum CategorySource { userMap, typeRule, keyword, model, fallback }

class CategoryResult {
  const CategoryResult(this.categoryKey, this.source, this.confidence);

  final String categoryKey;
  final CategorySource source;
  final double confidence;
}

/// محرّك التصنيف: merchant_map → قاعدة النوع → كلمات مفتاحية → افتراضي.
class Categorizer {
  Categorizer({
    MerchantCategoryMap? map,
    List<RemoteMerchantKeyword> remoteKeywords = const [],
    MerchantIntelligence? intelligence,
  })  : _map = map ?? MerchantCategoryMap(),
        _remoteKeywords = remoteKeywords,
        _intelligence = intelligence;

  final MerchantCategoryMap _map;
  final List<RemoteMerchantKeyword> _remoteKeywords;

  /// Optional on-device model. Null keeps the pre-model behaviour exactly, so
  /// the classifier can never be a hard dependency of transaction capture.
  final MerchantIntelligence? _intelligence;

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
      case TransactionType.creditCardPayment:
      case TransactionType.governmentPayment:
        return CategoryResult(
            Categories.other.key, CategorySource.typeRule, 0.75);
      case TransactionType.payment:
      case TransactionType.refund:
      case TransactionType.unknown:
        break;
    }

    // 3) كلمات مفتاحية بعيدة على اسم المتجر.
    if (merchant != null && _remoteKeywords.isNotEmpty) {
      final upper = merchant.toUpperCase();
      for (final kw in _remoteKeywords) {
        if (upper.contains(kw.keyword.toUpperCase())) {
          return CategoryResult(kw.categoryKey, CategorySource.keyword, 0.8);
        }
      }
    }

    // 4) كلمات مفتاحية محلية على اسم المتجر.
    if (merchant != null) {
      final upper = merchant.toUpperCase();
      for (final entry in CategorySeeds.keywordRules.entries) {
        if (upper.contains(entry.key.toUpperCase())) {
          return CategoryResult(entry.value, CategorySource.keyword, 0.8);
        }
      }
    }

    // 5) نموذج على الجهاز — يعمل فقط حين تفشل كل القواعد الحتمية.
    //
    // OD-13. This is the ONLY place the model runs: strictly after every
    // deterministic source has declined, and strictly before giving up. Wiring
    // it here rather than beside them is what stops it being decorative — if it
    // never fires, the only thing lost is the `other` fallback it replaced.
    //
    // It abstains below its confidence floor, so an unrecognised merchant still
    // lands on `fallback` instead of being guessed at.
    if (merchant != null && _intelligence != null) {
      final p = _intelligence.predict(merchant);
      if (p != null) {
        // Confidence is deliberately capped below the deterministic sources'
        // 0.8: a model suggestion must never outrank a rule that fired.
        return CategoryResult(
            p.categoryKey, CategorySource.model, math.min(p.confidence, 0.75));
      }
    }

    // 6) افتراضي.
    return CategoryResult(Categories.other.key, CategorySource.fallback, 0.3);
  }

  /// يطبّق تصحيح المستخدم على كل العمليات القادمة من نفس المتجر.
  void confirmMerchant(String rawMerchant, String categoryKey) {
    _map.learn(rawMerchant, categoryKey);
  }
}
