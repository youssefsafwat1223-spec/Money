import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/parser/normalizer.dart';

void main() {
  group('Normalizer.normalizeDigits', () {
    test('يحوّل الأرقام العربية-الهندية إلى غربية', () {
      expect(Normalizer.normalizeDigits('٠١٢٣٤٥٦٧٨٩'), '0123456789');
    });

    test('يحوّل الأرقام الفارسية الممتدة', () {
      expect(Normalizer.normalizeDigits('۰۱۲۳۴۵۶۷۸۹'), '0123456789');
    });

    test('يترك الأرقام الغربية كما هي', () {
      expect(Normalizer.normalizeDigits('45.00'), '45.00');
    });
  });

  group('Normalizer.normalizeCurrencyTokens', () {
    test('يوحّد رموز العملة السعودية إلى SAR', () {
      expect(Normalizer.normalizeCurrencyTokens('45 ريال'), '45 SAR');
      expect(Normalizer.normalizeCurrencyTokens('45 ر.س'), '45 SAR');
      expect(Normalizer.normalizeCurrencyTokens('45 ﷼'), '45 SAR');
    });

    test('يوحّد عملات عربية متعددة', () {
      expect(Normalizer.normalizeCurrencyTokens('45 درهم'), '45 AED');
      expect(Normalizer.normalizeCurrencyTokens('45 جنيه مصري'), '45 EGP');
      expect(Normalizer.normalizeCurrencyTokens('45 دينار كويتي'), '45 KWD');
    });
  });

  group('Normalizer.normalize', () {
    test('يزيل التطويل ويوحّد المسافات', () {
      expect(Normalizer.normalize('شـــراء    عملية'), 'شراء عملية');
    });

    test('يحافظ على الأسطر الجديدة', () {
      final result = Normalizer.normalize('سطر١\n\nسطر٢');
      expect(result.split('\n').length, 2);
    });
  });
}
