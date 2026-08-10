import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/finance/currency_scale.dart';

// MALI-026 (Phase-8 B8-0) — the currency-scale registry is explicit and tested
// (Decision 2): known -> scale; unknown -> UnsupportedCurrencyException. No
// silent default-2 for persisted Money.

void main() {
  test('every registered scale is 0, 2, or 3', () {
    for (final entry in kCurrencyScale.entries) {
      expect(const [0, 2, 3].contains(entry.value), isTrue,
          reason: '${entry.key}=${entry.value}');
    }
  });

  test('the known 3-decimal and 0-decimal groups are correct', () {
    for (final c in const ['KWD', 'BHD', 'OMR', 'JOD', 'TND', 'LYD', 'IQD']) {
      expect(currencyScale(c), 3, reason: c);
    }
    for (final c in const [
      'JPY', 'KRW', 'ISK', 'CLP', 'VND', 'XAF', 'XOF', 'UGX', 'RWF', 'DJF',
      'GNF', 'PYG', 'KMF'
    ]) {
      expect(currencyScale(c), 0, reason: c);
    }
    for (final c in const ['SAR', 'EGP', 'USD', 'EUR', 'AED', 'TRY']) {
      expect(currencyScale(c), 2, reason: c);
    }
  });

  test('lookup is case- and whitespace-insensitive', () {
    expect(currencyScale(' egp '), 2);
    expect(currencyScale('kwd'), 3);
    expect(isSupportedCurrency('Jpy'), isTrue);
  });

  test('unknown currency is an explicit unsupported state (never default-2)', () {
    expect(isSupportedCurrency('ZZZ'), isFalse);
    expect(isSupportedCurrency(''), isFalse);
    expect(() => currencyScale('ZZZ'),
        throwsA(isA<UnsupportedCurrencyException>()));
    expect(() => currencyScale('BTC'),
        throwsA(isA<UnsupportedCurrencyException>()));
  });

  test('every Currency.arabicLabel code has a registered scale (no gaps)', () {
    // The persisted-money registry must cover every currency the app offers a
    // label for, so a supported currency can never fall through to unsupported.
    const labelled = [
      'SAR', 'AED', 'EGP', 'KWD', 'QAR', 'BHD', 'OMR', 'JOD', 'ILS', 'LBP',
      'LYD', 'SYP', 'MAD', 'MRU', 'DZD', 'TND', 'SDG', 'IQD', 'YER', 'SOS',
      'DJF', 'KMF', 'TRY', 'USD', 'EUR', 'GBP', 'INR', 'PKR', 'BDT', 'PHP',
      'IDR', 'MYR', 'SGD', 'NGN', 'KES', 'ZAR', 'ETB', 'GHS', 'UGX', 'TZS',
    ];
    for (final c in labelled) {
      expect(isSupportedCurrency(c), isTrue, reason: '$c has a label but no scale');
    }
  });
}
