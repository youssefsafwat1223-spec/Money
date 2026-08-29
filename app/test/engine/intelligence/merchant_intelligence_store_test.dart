import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/categorization/categorizer.dart';
import 'package:money_companion/engine/categorization/category.dart';
import 'package:money_companion/engine/categorization/category_seeds.dart';
import 'package:money_companion/engine/intelligence/merchant_classifier.dart';
import 'package:money_companion/engine/intelligence/merchant_intelligence_store.dart';
import 'package:money_companion/engine/models/parsed_transaction.dart';
import 'package:money_companion/engine/models/transaction_source.dart';
import 'package:money_companion/engine/models/transaction_type.dart';

ParsedTransaction _txn(String merchant) => ParsedTransaction(
      amountText: '10.00',
      amount: 10.0,
      currency: 'SAR',
      type: TransactionType.payment,
      source: TransactionSource.bank,
      rawMerchant: merchant,
    );

void main() {
  group('BUG 4 — lifecycle fix must not change any prediction', () {
    // The whole justification for sharing one instance is that it is a pure
    // lifecycle change. That is worth asserting rather than assuming: a shared
    // store and a throwaway classifier must agree on EVERY catalog merchant.
    test('store and a fresh classifier agree on every seeded merchant', () {
      final store = MerchantIntelligenceStore();
      for (final seed in CategorySeeds.keywordRules.keys) {
        final fresh = CharNgramMerchantClassifier().predict(seed);
        final shared = store.predict(seed);
        expect(shared?.categoryKey, fresh?.categoryKey, reason: seed);
        expect(shared?.confidence, fresh?.confidence, reason: seed);
      }
    });

    test('store and a fresh classifier agree on unseen and noise input', () {
      final store = MerchantIntelligenceStore();
      for (final probe in const [
        'ZAJIL EXPRESS TRDG',
        'مغسلة الصفا للملابس',
        'كارفوور',
        'qqqqqqqq',
        '',
        '12345',
      ]) {
        expect(store.predict(probe)?.categoryKey,
            CharNgramMerchantClassifier().predict(probe)?.categoryKey,
            reason: probe);
      }
    });

    test('repeated predictions on one instance are stable', () {
      final store = MerchantIntelligenceStore();
      final first = store.predict('ستاربكس')?.categoryKey;
      for (var i = 0; i < 50; i++) {
        expect(store.predict('ستاربكس')?.categoryKey, first);
      }
    });

    test('Categorizer output is identical with a shared store', () {
      final txn = _txn('كارفوور');
      final withFresh = Categorizer(intelligence: CharNgramMerchantClassifier())
          .categorize(txn);
      final withStore =
          Categorizer(intelligence: MerchantIntelligenceStore()).categorize(txn);
      expect(withStore.categoryKey, withFresh.categoryKey);
      expect(withStore.source, withFresh.source);
      expect(withStore.confidence, withFresh.confidence);
    });
  });

  group('BUG 5 — corrections teach the model, without corrupting neighbours', () {
    test('an unknown merchant is refused before any correction', () {
      final store = MerchantIntelligenceStore();
      expect(store.predict('مطعم زرياب الدمشقي'), isNull);
    });

    test('an explicit correction changes the later prediction', () {
      final store = MerchantIntelligenceStore();
      store.learnFromUserCorrection('مطعم زرياب الدمشقي', Categories.restaurants.key);
      expect(store.predict('مطعم زرياب الدمشقي')?.categoryKey,
          Categories.restaurants.key);
    });

    test('learning generalises to a variant of the corrected merchant', () {
      final store = MerchantIntelligenceStore();
      store.learnFromUserCorrection('مطعم زرياب الدمشقي', Categories.restaurants.key);
      expect(store.predict('مطعم زرياب الدمشقى')?.categoryKey,
          Categories.restaurants.key,
          reason: 'alef-maqsura variant of the same merchant');
    });

    test('a correction does NOT move an unrelated merchant', () {
      final store = MerchantIntelligenceStore();
      final before = {
        for (final m in const ['ستاربكس', 'كارفور', 'NETFLIX', 'ARAMCO', 'UBER'])
          m: store.predict(m)?.categoryKey,
      };
      store.learnFromUserCorrection('مطعم زرياب الدمشقي', Categories.restaurants.key);
      store.learnFromUserCorrection('ورشة النجم', Categories.maintenance.key);
      for (final entry in before.entries) {
        expect(store.predict(entry.key)?.categoryKey, entry.value,
            reason: 'correcting another merchant must not move ${entry.key}');
      }
    });

    test('re-confirming the same pair does not duplicate an exemplar', () {
      final store = MerchantIntelligenceStore();
      store.learnFromUserCorrection('متجر التجربة', Categories.shopping.key);
      final after = store.learnedCount;
      store.learnFromUserCorrection('متجر التجربة', Categories.shopping.key);
      store.learnFromUserCorrection('متجر التجربة', Categories.shopping.key);
      expect(store.learnedCount, after);
    });

    test('a later correction of the same merchant wins', () {
      final store = MerchantIntelligenceStore();
      store.learnFromUserCorrection('متجر التجربة', Categories.shopping.key);
      store.learnFromUserCorrection('متجر التجربة', Categories.groceries.key);
      expect(store.predict('متجر التجربة')?.categoryKey, Categories.groceries.key);
    });

    test('empty merchant or category is ignored', () {
      final store = MerchantIntelligenceStore();
      final before = store.learnedCount;
      store.learnFromUserCorrection('', Categories.shopping.key);
      store.learnFromUserCorrection('   ', Categories.shopping.key);
      store.learnFromUserCorrection('متجر', '');
      expect(store.learnedCount, before);
    });

    test('seedFromLearnedMap rehydrates persisted corrections', () {
      final store = MerchantIntelligenceStore();
      store.seedFromLearnedMap({
        'مطعم زرياب الدمشقي': Categories.restaurants.key,
        'ورشة النجم': Categories.maintenance.key,
      });
      expect(store.predict('مطعم زرياب الدمشقي')?.categoryKey,
          Categories.restaurants.key);
      expect(store.predict('ورشة النجم')?.categoryKey, Categories.maintenance.key);
    });

    test('seeding twice is idempotent', () {
      final store = MerchantIntelligenceStore();
      const map = {'مطعم زرياب الدمشقي': 'restaurants'};
      store.seedFromLearnedMap(map);
      final after = store.learnedCount;
      store.seedFromLearnedMap(map);
      expect(store.learnedCount, after);
    });

    test('the model still ranks below deterministic sources after learning', () {
      // A correction must not let the model outrank a rule that fired. The
      // Categorizer caps a model result at 0.75; deterministic sources are 0.8+.
      //
      // The merchant here deliberately shares no keyword with the catalog, so
      // steps 1-4 all decline and step 5 (the model) is genuinely the source.
      // Using one that DOES contain a seeded keyword — e.g. anything with
      // "مطعم" — exercises the keyword rule instead and proves nothing here.
      const novel = 'زرياب الدمشقي';
      final store = MerchantIntelligenceStore();
      expect(Categorizer(intelligence: store).categorize(_txn(novel)).source,
          CategorySource.fallback,
          reason: 'precondition: no deterministic source claims this merchant');

      store.learnFromUserCorrection(novel, Categories.restaurants.key);
      final result = Categorizer(intelligence: store).categorize(_txn(novel));
      expect(result.categoryKey, Categories.restaurants.key);
      expect(result.source, CategorySource.model);
      expect(result.confidence, lessThanOrEqualTo(0.75));
    });

    test('a deterministic keyword still beats a contrary correction', () {
      // The inverse guarantee: teaching the model something that contradicts a
      // catalog keyword must not change the outcome, because the keyword rule
      // fires first and never consults the model.
      final store = MerchantIntelligenceStore();
      final txn = _txn('مطعم البيك');
      final before = Categorizer(intelligence: store).categorize(txn);
      store.learnFromUserCorrection('مطعم البيك', Categories.pets.key);
      final after = Categorizer(intelligence: store).categorize(txn);
      expect(after.categoryKey, before.categoryKey);
      expect(after.source, CategorySource.keyword);
    });
  });
}
