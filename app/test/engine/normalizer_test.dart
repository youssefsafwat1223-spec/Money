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

  group('Normalizer — grouping is preserved for exact money validation', () {
    test('single group stays lexical', () {
      expect(Normalizer.normalize('18,000.00'), '18,000.00');
    });
    test('multi-group stays lexical', () {
      expect(Normalizer.normalize('1,234,567.89'), '1,234,567.89');
    });
    test('grouping stays lexical in context', () {
      expect(
          Normalizer.normalize('الرصيد: SAR 2,310.50'), 'الرصيد: SAR 2,310.50');
    });
    test('multiple grouped tokens stay lexical', () {
      expect(Normalizer.normalize('14,379.13 and 5,620.87'),
          '14,379.13 and 5,620.87');
    });
    test('ambiguous comma stays visible for rejection at the money boundary', () {
      expect(Normalizer.normalize('12,50'), '12,50');
    });
    test('no commas unchanged', () {
      expect(Normalizer.normalize('250.93'), '250.93');
    });
  });

  group('Normalizer — tashkeel stripping', () {
    test('removes fathah (U+064E)', () {
      expect(Normalizer.normalize('مَبلغ'), 'مبلغ');
    });
    test('removes kasrah (U+0650)', () {
      expect(Normalizer.normalize('بِـ'), 'ب');
    });
  });
}
