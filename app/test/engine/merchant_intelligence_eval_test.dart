import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/categorization/categorizer.dart';
import 'package:money_companion/engine/categorization/category.dart';
import 'package:money_companion/engine/categorization/category_seeds.dart';
import 'package:money_companion/engine/intelligence/merchant_classifier.dart';
import 'package:money_companion/engine/intelligence/text_normalizer.dart';
import 'package:money_companion/engine/models/parsed_transaction.dart';
import 'package:money_companion/engine/models/transaction_source.dart';
import 'package:money_companion/engine/models/transaction_type.dart';

/// OD-13 — the evaluation harness, and the gate that stops the model becoming
/// decorative.
///
/// ## What can honestly be measured here
///
/// There is no real labelled corpus: ~37 messages, contaminated by F-015. Too
/// few to train on and too few to evaluate with. So this harness does NOT claim
/// a real-world accuracy number — claiming one would be the dishonest move.
///
/// Instead it evaluates on a PERTURBATION SET generated from the shipped
/// catalog: take each seeded merchant and produce the variants banks actually
/// emit — diacritics, alef/yaa/teh-marbuta forms, Arabic-Indic digits, acquirer
/// prefixes, terminal suffixes, truncation, case noise. Those variants are the
/// realistic failure mode of the exact-substring matcher in production, so
/// measuring on them measures the thing the model was added to fix.
///
/// ## The lift gate
///
/// The decisive assertion is not "the model is accurate" — it is "the model
/// beats the trivial baseline it replaced". A model that merely matches exact
/// substring matching adds nothing and should fail CI rather than ship as
/// decoration. That is [_liftGate].
String _stripPrefix(String s) => s;

/// Realistic variant generators. Each mirrors something a bank actually sends.
final _perturbations = <String, String Function(String)>{
  'acquirer prefix (ar)': (m) => 'شراء من $m',
  'acquirer prefix (en)': (m) => 'POS PURCHASE $m',
  'terminal suffix': (m) => '$m TERM 4471',
  'branch suffix (ar)': (m) => '$m - فرع ١٢٣',
  'lowercased': (m) => m.toLowerCase(),
  'diacritised': (m) => m.replaceAll('ا', 'اَ'),
  'alef variants': (m) => m.replaceAll('ا', 'أ'),
  'teh marbuta': (m) => m.replaceAll('ه', 'ة'),
  'separator noise': (m) => m.replaceAll(' ', '  '),
  'trailing digits': (m) => '$m 0012',
};

/// The baseline the model must beat: exactly what the categorizer did before —
/// case-insensitive substring containment against the same seeds.
String? _exactBaseline(String merchant) {
  final upper = merchant.toUpperCase();
  for (final e in CategorySeeds.keywordRules.entries) {
    if (upper.contains(e.key.toUpperCase())) return e.value;
  }
  return null;
}

void main() {
  final seeds = CategorySeeds.keywordRules;
  final model = CharNgramMerchantClassifier();

  group('the corpus is real', () {
    test('the shipped catalog is large enough to be a training set', () {
      // The premise of choosing a classical model over a neural one: the app
      // already ships real labelled data. If this ever shrinks drastically the
      // choice should be revisited.
      expect(model.exemplarCount, greaterThanOrEqualTo(200),
          reason: 'the seed catalog is the training corpus');
    });
  });

  group('regression guard — unperturbed merchants', () {
    test('every catalog merchant classifies to its own category', () {
      // This is close to a lookup; failure means the pipeline itself is broken.
      var correct = 0;
      for (final e in seeds.entries) {
        final p = model.predict(e.key);
        if (p != null && p.categoryKey == e.value) correct++;
      }
      final acc = correct / seeds.length;
      expect(acc, greaterThan(0.98),
          reason: 'exact catalog forms must be near-perfect; got '
              '${(acc * 100).toStringAsFixed(1)}%');
    });
  });

  group('lift over the trivial baseline', () {
    late double modelAcc;
    late double baselineAcc;

    setUpAll(() {
      var modelCorrect = 0, baseCorrect = 0, total = 0;
      for (final e in seeds.entries) {
        for (final perturb in _perturbations.values) {
          final variant = perturb(_stripPrefix(e.key));
          total++;
          final p = model.predict(variant);
          if (p != null && p.categoryKey == e.value) modelCorrect++;
          if (_exactBaseline(variant) == e.value) baseCorrect++;
        }
      }
      modelAcc = modelCorrect / total;
      baselineAcc = baseCorrect / total;
      // Reported, not asserted as a real-world number — see the doc comment.
      // ignore: avoid_print
      print('perturbation set: n=$total  model=${(modelAcc * 100).toStringAsFixed(1)}%  '
          'baseline=${(baselineAcc * 100).toStringAsFixed(1)}%');
    });

    test('the model beats exact substring matching', () {
      // THE anti-decorative gate. If this fails, the model earns nothing over
      // the code it sits beside and must not ship.
      expect(modelAcc, greaterThan(baselineAcc),
          reason: 'a model that does not beat the baseline it replaced is '
              'decoration, not intelligence');
    });

    test('it removes most of the errors the baseline still makes', () {
      // Absolute lift is the WRONG measure here and it took running this to
      // see it: the baseline already scores ~93%, so absolute lift is capped at
      // ~7 points no matter how good the model is. Relative error reduction is
      // the honest measure of "how much of the remaining problem did this
      // solve" — and it is not a softer gate, it is a stricter one, because a
      // model that fixed only a third of the residual errors would pass an
      // absolute-lift test and fail this.
      final baselineErr = 1 - baselineAcc;
      final modelErr = 1 - modelAcc;
      final reduction = (baselineErr - modelErr) / baselineErr;
      expect(reduction, greaterThan(0.50),
          reason: 'the model must remove most of the residual error: '
              'baseline err ${(baselineErr * 100).toStringAsFixed(1)}% → '
              'model err ${(modelErr * 100).toStringAsFixed(1)}% '
              '(${(reduction * 100).toStringAsFixed(0)}% reduction)');
    });

    test('the value concentrates where substring matching structurally fails',
        () {
      // Where the model actually earns its place: character-level variants.
      // Prefix/suffix noise leaves the merchant substring intact, so the
      // baseline survives it — the model is not needed there and the aggregate
      // number hides that. Measuring per-perturbation keeps the claim honest.
      for (final name in const [
        'alef variants',
        'teh marbuta',
        'diacritised',
      ]) {
        final perturb = _perturbations[name]!;
        var mOk = 0, bOk = 0, n = 0;
        for (final e in seeds.entries) {
          final v = perturb(e.key);
          if (v == e.key) continue; // perturbation did not apply
          n++;
          final p = model.predict(v);
          if (p != null && p.categoryKey == e.value) mOk++;
          if (_exactBaseline(v) == e.value) bOk++;
        }
        if (n == 0) continue;
        // ignore: avoid_print
        print('  $name: n=$n model=${(mOk / n * 100).toStringAsFixed(0)}% '
            'baseline=${(bOk / n * 100).toStringAsFixed(0)}%');
        expect(mOk, greaterThan(bOk),
            reason: '$name is exactly the case substring matching cannot '
                'handle; the model must win it');
      }
    });
  });

  group('precision when it speaks — abstention is the promise', () {
    test('unrelated strings are refused rather than guessed', () {
      // Coverage is not the product promise; precision is. These resemble no
      // catalog merchant, so the honest answer is silence.
      for (final noise in const [
        'ZZZQQQ XKCD 9931',
        'حوالة داخلية',
        'a',
        '',
        '   ',
        '00000000',
      ]) {
        expect(model.predict(noise), isNull, reason: 'should abstain on "$noise"');
      }
    });

    test('when it does speak on perturbed input, it is usually right', () {
      var spoke = 0, right = 0;
      for (final e in seeds.entries) {
        for (final perturb in _perturbations.values) {
          final p = model.predict(perturb(e.key));
          if (p == null) continue;
          spoke++;
          if (p.categoryKey == e.value) right++;
        }
      }
      final precision = right / spoke;
      expect(precision, greaterThan(0.90),
          reason: 'precision above the abstain floor was '
              '${(precision * 100).toStringAsFixed(1)}%');
    });
  });

  group('on-device learning — what a lookup table cannot do', () {
    test('a user correction changes later predictions, with no egress', () {
      final m = CharNgramMerchantClassifier();
      const novel = 'مطعم الحاتي الشامي';
      expect(m.predict(novel), isNull, reason: 'unknown before learning');

      m.learn(novel, Categories.restaurants.key);

      final after = m.predict(novel);
      expect(after, isNotNull);
      expect(after!.categoryKey, Categories.restaurants.key);
      expect(m.learnedCount, 1);
    });

    test('learning generalises to variants of the corrected merchant', () {
      // The point of a model rather than a map: correcting one spelling should
      // cover the spellings the bank will send next month.
      final m = CharNgramMerchantClassifier();
      m.learn('مطعم الحاتي الشامي', Categories.restaurants.key);
      final variant = m.predict('شراء من مطعم الحاتى الشامي - فرع ٣');
      expect(variant, isNotNull,
          reason: 'a corrected merchant should survive normal bank noise');
      expect(variant!.categoryKey, Categories.restaurants.key);
    });

    test('a correction outranks a catalog seed for the same text', () {
      final m = CharNgramMerchantClassifier();
      final seed = seeds.entries.first;
      m.learn(seed.key, Categories.other.key);
      expect(m.predict(seed.key)!.categoryKey, Categories.other.key,
          reason: "the user's own decision wins over a shipped seed");
    });
  });

  group('normalisation', () {
    test('collapses the variants banks actually emit', () {
      const canonical = 'كارفور';
      for (final variant in const [
        'كارفور',
        'كَارفور',
        'شراء من كارفور',
        'كارفور - فرع ١٢٣',
        'كارفور   ',
      ]) {
        expect(normalizeMerchant(variant), canonical, reason: variant);
      }
    });

    test('does not fold two genuinely different merchants together', () {
      expect(normalizeMerchant('امازون'), isNot(normalizeMerchant('كارفور')));
      expect(normalizeMerchant('STARBUCKS'), isNot(normalizeMerchant('SUBWAY')));
    });

    test('leaves a merchant that merely contains a boilerplate word alone', () {
      // «شراء» is stripped only as an anchored prefix. A shop whose NAME
      // contains it must survive.
      expect(normalizeMerchant('مركز الشراء الذكي'), contains('الشراء'));
    });
  });

  group('the model is wired into the real abstain path', () {
    ParsedTransaction txn(String merchant) => ParsedTransaction(
          amountText: '100',
          amount: 100,
          currency: 'SAR',
          type: TransactionType.payment,
          source: TransactionSource.bank,
          rawMerchant: merchant,
        );

    test('a novel variant reaches a category through the model', () {
      // The integration assertion. If this cannot be written, the model is
      // decorative by construction.
      final withModel = Categorizer(intelligence: CharNgramMerchantClassifier());
      final withoutModel = Categorizer();

      final seed = seeds.entries.firstWhere(
          (e) => e.key.length > 6 && !e.key.contains(' '),
          orElse: () => seeds.entries.first);
      final variant = 'شراء من ${seed.key} - فرع ١٢';

      final plain = withoutModel.categorize(txn(variant));
      final smart = withModel.categorize(txn(variant));

      if (plain.source == CategorySource.fallback) {
        expect(smart.source, CategorySource.model,
            reason: 'where determinism gave up, the model must be reached');
        expect(smart.categoryKey, seed.value);
      } else {
        // The deterministic path already handled it — then the model must NOT
        // have been consulted at all.
        expect(smart.source, plain.source);
        expect(smart.categoryKey, plain.categoryKey);
      }
    });

    test('deterministic sources are never overridden by the model', () {
      final withModel = Categorizer(intelligence: CharNgramMerchantClassifier());
      // A withdrawal is decided by a type rule before any merchant logic runs.
      final r = withModel.categorize(ParsedTransaction(
        amountText: '100',
        amount: 100,
        currency: 'SAR',
        type: TransactionType.withdrawal,
        source: TransactionSource.bank,
        rawMerchant: 'كارفور',
      ));
      expect(r.source, CategorySource.typeRule);
      expect(r.categoryKey, Categories.cash.key);
    });

    test('a model result never outranks a deterministic confidence', () {
      final withModel = Categorizer(intelligence: CharNgramMerchantClassifier());
      final r = withModel.categorize(txn('شراء من ${seeds.keys.first} - فرع ١٢'));
      if (r.source == CategorySource.model) {
        expect(r.confidence, lessThanOrEqualTo(0.75),
            reason: 'model confidence is capped below the deterministic '
                'sources, so it can never win a comparison against them');
      }
    });

    test('with no model supplied, behaviour is exactly as before', () {
      // The model must never be a hard dependency of transaction capture.
      final plain = Categorizer();
      final r = plain.categorize(txn('ZZZ UNKNOWN MERCHANT'));
      expect(r.source, CategorySource.fallback);
      expect(r.categoryKey, Categories.other.key);
    });
  });

  group('performance — it must be free at runtime too', () {
    test('a prediction is fast enough to run inline on every message', () {
      final sw = Stopwatch()..start();
      final probe = 'شراء من ${seeds.keys.first} - فرع ١٢٣';
      for (var i = 0; i < 200; i++) {
        model.predict(probe);
      }
      sw.stop();
      final perCall = sw.elapsedMicroseconds / 200;
      expect(perCall, lessThan(5000),
          reason: 'inference took ${perCall.toStringAsFixed(0)}µs per call');
    });

    test('predictions are deterministic across runs', () {
      // Use a merchant the catalog actually contains — asserting determinism on
      // an abstention would pass trivially and prove nothing.
      final seed = seeds.keys.first;
      final input = 'شراء من $seed';
      final a = model.predict(input);
      final b = model.predict(input);
      expect(a, isNotNull, reason: 'fixture must be a merchant the model knows');
      expect(a!.categoryKey, b!.categoryKey);
      expect(a.confidence, b.confidence);
    });
  });
}
