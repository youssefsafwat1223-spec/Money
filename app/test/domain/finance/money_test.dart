import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/finance/currency_scale.dart';
import 'package:money_companion/domain/finance/decimal_minor.dart';
import 'package:money_companion/domain/finance/money.dart';

// MALI-026 (Phase-8 B8-0) — the Money value type: exact arithmetic, currency
// isolation, largest-remainder allocation, exact rate application, int64 bounds.

void main() {
  group('construction + parsing', () {
    test('parse exact user money; reject over-precision', () {
      expect(Money.parse('19.99', 'EGP').minorUnits, 1999);
      expect(Money.parse('1.234', 'KWD').minorUnits, 1234);
      expect(Money.parse('1234', 'JPY').minorUnits, 1234);
      expect(() => Money.parse('19.995', 'EGP'),
          throwsA(isA<DecimalFormatException>()));
    });
    test('unsupported currency throws (never guesses scale)', () {
      expect(() => Money(100, 'ZZZ'),
          throwsA(isA<UnsupportedCurrencyException>()));
      expect(() => Money.parse('1.00', 'BTC'),
          throwsA(isA<UnsupportedCurrencyException>()));
    });
    test('legacy REAL conversion (migration only)', () {
      expect(Money.fromLegacyReal(0.1 + 0.2, 'EGP').minorUnits, 30);
      expect(Money.fromLegacyReal(19.989999999, 'USD').minorUnits, 1999);
    });
  });

  group('exact arithmetic + currency isolation', () {
    test('add/subtract/negate same currency', () {
      final a = Money.parse('0.10', 'EGP');
      final b = Money.parse('0.20', 'EGP');
      expect((a + b).minorUnits, 30); // exact 0.30
      expect((b - a).minorUnits, 10);
      expect((-a).minorUnits, -10);
    });
    test('cross-currency arithmetic is forbidden', () {
      final egp = Money.parse('1.00', 'EGP');
      final usd = Money.parse('1.00', 'USD');
      expect(() => egp + usd, throwsArgumentError);
      expect(() => egp.compareTo(usd), throwsArgumentError);
    });
    test('exact whole-factor multiply (monthly bill × 12)', () {
      expect((Money.parse('9.99', 'EGP') * 12).minorUnits, 11988);
    });
    test('exact sum over many rows (no float drift)', () {
      final rows = List.generate(10000, (_) => Money.parse('0.01', 'EGP'));
      expect(Money.sum(rows, 'EGP').minorUnits, 10000); // exactly 100.00
    });
    test('sum() rejects mixed currencies', () {
      expect(() => Money.sum([Money.parse('1', 'EGP'), Money.parse('1', 'USD')], 'EGP'),
          throwsArgumentError);
    });
  });

  group('applyRate (derived money — exact ratio, quantize once)', () {
    test('percentage of money rounds once, half-away', () {
      // 15% of 10.00 EGP = 1.50
      final r = Money.parse('10.00', 'EGP')
          .applyRate(rateNumerator: BigInt.from(15), rateDenominator: BigInt.from(100));
      expect(r.minorUnits, 150);
    });
    test('1/3 of 10.00 rounds half-away at the final boundary', () {
      final r = Money.parse('10.00', 'EGP')
          .applyRate(rateNumerator: BigInt.one, rateDenominator: BigInt.from(3));
      expect(r.minorUnits, 333); // 3.3333 -> 3.33
    });
    test('rate denominator must be positive', () {
      expect(
          () => Money.parse('1', 'EGP')
              .applyRate(rateNumerator: BigInt.one, rateDenominator: BigInt.zero),
          throwsArgumentError);
    });
  });

  group('allocate (largest-remainder — sum(parts) == whole ALWAYS)', () {
    test('splitting 10.00 into 3 equal parts loses no cent', () {
      final parts = Money.parse('10.00', 'EGP').allocate([1, 1, 1]);
      expect(parts.map((p) => p.minorUnits).toList(), [334, 333, 333]);
      expect(Money.sum(parts, 'EGP').minorUnits, 1000);
    });
    test('weighted split sums to the whole', () {
      final parts = Money.parse('100.00', 'EGP').allocate([1, 2, 3]);
      expect(Money.sum(parts, 'EGP'), Money.parse('100.00', 'EGP'));
    });
    test('negative totals allocate and still sum to the whole', () {
      final parts = Money.parse('-10.00', 'EGP').allocate([1, 1, 1]);
      expect(Money.sum(parts, 'EGP').minorUnits, -1000);
    });
    test('property: random splits always conserve the total', () {
      for (var total = -5000; total <= 5000; total += 371) {
        final whole = Money(total, 'EGP');
        final parts = whole.allocate([3, 5, 7, 11]);
        expect(Money.sum(parts, 'EGP'), whole, reason: 'total=$total');
      }
    });
  });

  group('formatting + equality', () {
    test('toDecimalString is exact at scale', () {
      expect(Money.parse('19.99', 'EGP').toDecimalString(), '19.99');
      expect(Money(1234, 'KWD').toDecimalString(), '1.234');
      expect(Money(1234, 'JPY').toDecimalString(), '1234');
    });
    test('value equality by (minor, currency)', () {
      expect(Money(100, 'EGP'), Money.parse('1.00', 'EGP'));
      expect(Money(100, 'EGP') == Money(100, 'USD'), isFalse);
    });
  });
}
