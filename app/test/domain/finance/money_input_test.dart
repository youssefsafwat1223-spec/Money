import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/finance/decimal_minor.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/finance/money_input.dart';

// MALI-026 (Phase-8 B8-1 §4) — the localized money-input adapter normalizes
// Arabic-Indic/Persian digits, the Arabic decimal separator, and grouping into
// canonical decimal text, then defers to the strict, locale-agnostic Money
// parser. No double.parse anywhere in the path.

void main() {
  group('normalizeLocalizedDecimal', () {
    test('Arabic-Indic and Persian digits → ASCII', () {
      expect(normalizeLocalizedDecimal('١٩٫٩٩'), '19.99'); // Arabic + ٫
      expect(normalizeLocalizedDecimal('۱۹.۹۹'), '19.99'); // Persian + .
      expect(normalizeLocalizedDecimal('١٢٣٤'), '1234');
    });
    test('grouping separators are stripped; sign kept', () {
      expect(normalizeLocalizedDecimal('1,234.50'), '1234.50');
      expect(normalizeLocalizedDecimal('1٬234٫50'), '1234.50');
      expect(normalizeLocalizedDecimal('-1 234.5'), '-1234.5');
      expect(normalizeLocalizedDecimal(' 19.99 '), '19.99');
    });
    test('rejects malformed / multi-separator / letters', () {
      for (final bad in ['', '   ', 'abc', '1.2.3', '12x', '.,']) {
        expect(() => normalizeLocalizedDecimal(bad),
            throwsA(isA<MoneyInputException>()), reason: bad);
      }
    });

    // Blocker 2 — comma ambiguity must NEVER silently change magnitude.
    test('structurally-valid thousands grouping is accepted', () {
      expect(normalizeLocalizedDecimal('1,234'), '1234');
      expect(normalizeLocalizedDecimal('1,234.50'), '1234.50');
      expect(normalizeLocalizedDecimal('١٬٢٣٤٫٥٠'), '1234.50'); // Arabic ٬ + ٫
      expect(normalizeLocalizedDecimal('12,345,678.90'), '12345678.90');
    });
    test('AMBIGUOUS comma/decimal forms are REJECTED, never guessed', () {
      for (final ambiguous in [
        '12,50', // could be 12.50 or 1250 — never 1250
        '١٢,٥٠', // same, Arabic digits
        '1.234,50', // European decimal-comma — not our contract
        '1,23', // 2-digit group
        '1,2345', // 4-digit group
        '1,23,456', // mis-grouped
      ]) {
        expect(() => normalizeLocalizedDecimal(ambiguous),
            throwsA(isA<MoneyInputException>()), reason: ambiguous);
      }
    });
  });

  group('parseLocalizedMoney', () {
    test('localized text → canonical Money', () {
      expect(parseLocalizedMoney('١٩٫٩٩', 'EGP').minorUnits, 1999);
      expect(parseLocalizedMoney('1,234.50', 'EGP').minorUnits, 123450);
      expect(parseLocalizedMoney('١٫٢٣٤', 'KWD').minorUnits, 1234);
    });
    test('over-precision is a validation error (never silently rounded)', () {
      expect(() => parseLocalizedMoney('19٫995', 'EGP'),
          throwsA(isA<DecimalFormatException>()));
    });
    test('unsupported currency throws', () {
      expect(() => parseLocalizedMoney('1.00', 'ZZZ'), throwsA(isA<Object>()));
    });
  });

  group('§2 int64 adversarial coverage', () {
    test('MAX/MIN construct; MAX+1 / MIN-1 overflow on ± ', () {
      final max = Money(9223372036854775807, 'EGP');
      final min = Money(-9223372036854775808, 'EGP');
      expect(max.minorUnits, 9223372036854775807);
      // MAX + 1 minor
      expect(() => max + Money(1, 'EGP'), throwsA(isA<MoneyOverflowException>()));
      // MIN - 1 minor
      expect(() => min - Money(1, 'EGP'), throwsA(isA<MoneyOverflowException>()));
    });
    test('negate(INT64_MIN) overflows (no wraparound)', () {
      expect(() => -Money(-9223372036854775808, 'EGP'),
          throwsA(isA<MoneyOverflowException>()));
    });
    test('MAX * 2 and MIN * -1 overflow', () {
      expect(() => Money(9223372036854775807, 'EGP') * 2,
          throwsA(isA<MoneyOverflowException>()));
      expect(() => Money(-9223372036854775808, 'EGP') * -1,
          throwsA(isA<MoneyOverflowException>()));
    });
    test('rate intermediate exceeds int64 but final result is valid', () {
      // 9.2e18 minor × 1000000 / 1000000 → back to 9.2e18 (intermediate huge)
      final r = Money(9223372036854775807, 'EGP').applyRate(
          rateNumerator: BigInt.from(1000000),
          rateDenominator: BigInt.from(1000000));
      expect(r.minorUnits, 9223372036854775807);
    });
    test('rate whose FINAL result exceeds int64 overflows', () {
      expect(
          () => Money(9223372036854775807, 'EGP')
              .applyRate(rateNumerator: BigInt.two, rateDenominator: BigInt.one),
          throwsA(isA<MoneyOverflowException>()));
    });
    test('allocation of extreme signed value conserves the total', () {
      final whole = Money(-9223372036854775807, 'EGP');
      final parts = whole.allocate([1, 1, 1]);
      // sum re-adds in BigInt via Money.sum (checked) → equals the whole
      expect(Money.sum(parts, 'EGP'), whole);
    });
  });

  group('§3 currency canonicalization', () {
    test('case/whitespace variants canonicalize to the same currency', () {
      final a = Money.parse('1.00', 'egp');
      final b = Money.parse('1.00', ' EgP ');
      final c = Money.parse('1.00', 'EGP');
      expect(a.currency, 'EGP');
      expect(b.currency, 'EGP');
      expect(a, c);
      expect(b, c);
      // same-currency arithmetic works across the variants (no false mismatch)
      expect((a + b + c).minorUnits, 300);
    });
    test('persisted currency is uppercase canonical', () {
      expect(Money(100, 'kwd').currency, 'KWD');
    });
  });
}
