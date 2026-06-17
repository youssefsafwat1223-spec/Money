import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/onboarding/onboarding_options.dart';

void main() {
  group('currencyKeywords', () {
    test('SAR returns expected keywords', () {
      expect(currencyKeywords('SAR'), containsAll(['SAR', 'ريال', 'ر.س']));
    });

    test('AED returns expected keywords', () {
      expect(currencyKeywords('AED'), containsAll(['AED', 'درهم', 'د.إ']));
    });

    test('EGP returns expected keywords', () {
      expect(currencyKeywords('EGP'), containsAll(['EGP', 'جنيه', 'ج.م']));
    });

    test('KWD returns expected keywords', () {
      expect(currencyKeywords('KWD'), containsAll(['KWD', 'دينار']));
    });

    test('QAR returns expected keywords', () {
      expect(currencyKeywords('QAR'), containsAll(['QAR', 'ريال']));
    });

    test('BHD returns expected keywords', () {
      expect(currencyKeywords('BHD'), containsAll(['BHD', 'دينار']));
    });

    test('OMR returns expected keywords', () {
      expect(currencyKeywords('OMR'), containsAll(['OMR', 'ريال']));
    });

    test('JOD returns expected keywords', () {
      expect(currencyKeywords('JOD'), containsAll(['JOD', 'دينار']));
    });

    test('unknown currency returns [currencyCode] as fallback', () {
      expect(currencyKeywords('XYZ'), equals(['XYZ']));
    });

    test('first keyword is always the currency code', () {
      for (final country in onboardingCountries.take(8)) {
        final keywords = currencyKeywords(country.currencyCode);
        expect(keywords.first, country.currencyCode,
            reason: '${country.currencyCode}: first keyword must be the code');
      }
    });
  });
}
