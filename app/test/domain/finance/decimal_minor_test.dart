import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/finance/decimal_minor.dart';

// MALI-026 (Phase-8 B8-0) — the exact decimal ⇄ minor engine, proven BEFORE any
// schema work. Legacy REAL conversion, exact user parsing, half-away rounding,
// and the signed-int64 boundary.

void main() {
  group('roundHalfAwayFromZero', () {
    BigInt r(int n, int d) =>
        roundHalfAwayFromZero(BigInt.from(n), BigInt.from(d));
    test('ties go away from zero, symmetrically', () {
      expect(r(5, 2), BigInt.from(3)); // 2.5 -> 3
      expect(r(-5, 2), BigInt.from(-3)); // -2.5 -> -3
      expect(r(3, 2), BigInt.from(2)); // 1.5 -> 2
      expect(r(1, 2), BigInt.one); // 0.5 -> 1
      expect(r(-1, 2), BigInt.from(-1));
      expect(r(4, 3), BigInt.one); // 1.33 -> 1
      expect(r(5, 3), BigInt.two); // 1.66 -> 2
    });
  });

  group('parseExactDecimalToMinor (Decision 1A — user money, no silent round)', () {
    test('exact values at scale convert precisely', () {
      expect(parseExactDecimalToMinor('19.99', 2), 1999);
      expect(parseExactDecimalToMinor('-19.99', 2), -1999);
      expect(parseExactDecimalToMinor('0', 2), 0);
      expect(parseExactDecimalToMinor('0.1', 2), 10);
      expect(parseExactDecimalToMinor('1000', 2), 100000);
      expect(parseExactDecimalToMinor('1.234', 3), 1234); // 3-decimal currency
      expect(parseExactDecimalToMinor('5', 0), 5); // 0-decimal currency
      expect(parseExactDecimalToMinor('19.90', 2), 1990); // trailing zero ok
    });
    test('more NON-ZERO precision than the scale is a validation error', () {
      expect(() => parseExactDecimalToMinor('19.995', 2),
          throwsA(isA<DecimalFormatException>()));
      expect(() => parseExactDecimalToMinor('1.2345', 3),
          throwsA(isA<DecimalFormatException>()));
      expect(() => parseExactDecimalToMinor('5.5', 0),
          throwsA(isA<DecimalFormatException>()));
    });
    test('malformed text throws', () {
      for (final bad in ['', 'abc', '1,000.00', '1.2.3', '0x10', '1e3', ' ']) {
        expect(() => parseExactDecimalToMinor(bad, 2),
            throwsA(isA<DecimalFormatException>()), reason: bad);
      }
    });
  });

  group('quantizeDecimalToMinor (Decision 1B/C — legacy/derived, half-away)', () {
    test('rounds excess precision half-away-from-zero', () {
      expect(quantizeDecimalToMinor('1.005', 2), 101); // -> 1.01
      expect(quantizeDecimalToMinor('-1.005', 2), -101); // -> -1.01
      expect(quantizeDecimalToMinor('1.004', 2), 100);
      expect(quantizeDecimalToMinor('-1.004', 2), -100);
      expect(quantizeDecimalToMinor('19.989999999', 2), 1999);
      expect(quantizeDecimalToMinor('2.7182818', 2), 272);
    });
  });

  group('legacyRealToMinor (Decision 1B — the migration converter)', () {
    test('recovers the intended decimal (shortest round-trip), not float noise', () {
      expect(legacyRealToMinor(19.99, 2), 1999);
      expect(legacyRealToMinor(0.1, 2), 10);
      expect(legacyRealToMinor(0.2, 2), 20);
      expect(legacyRealToMinor(0.1 + 0.2, 2), 30); // 0.30000000000000004 -> 30
      expect(legacyRealToMinor(1.005, 2), 101); // half-away
      expect(legacyRealToMinor(-1.005, 2), -101);
      expect(legacyRealToMinor(19.989999999, 2), 1999);
      expect(legacyRealToMinor(0, 2), 0);
      expect(legacyRealToMinor(-0.0, 2), 0);
    });
    test('3-decimal + 0-decimal currencies', () {
      expect(legacyRealToMinor(1.234, 3), 1234); // KWD-class
      expect(legacyRealToMinor(1.2345, 3), 1235); // round 3rd
      expect(legacyRealToMinor(1234.0, 0), 1234); // JPY-class
      expect(legacyRealToMinor(1234.6, 0), 1235);
    });
    test('large and tiny magnitudes (incl. exponent form)', () {
      expect(legacyRealToMinor(1e12, 2), 100000000000000);
      expect(legacyRealToMinor(0.009, 2), 1); // 0.009 -> 0.01
      expect(legacyRealToMinor(0.004, 2), 0);
      expect(legacyRealToMinor(1e-7, 2), 0);
    });
    test('NaN / Infinity rejected', () {
      expect(() => legacyRealToMinor(double.nan, 2),
          throwsA(isA<DecimalFormatException>()));
      expect(() => legacyRealToMinor(double.infinity, 2),
          throwsA(isA<DecimalFormatException>()));
    });
  });

  group('minorToDecimalString (exact, no double)', () {
    test('round-trips at every scale', () {
      expect(minorToDecimalString(1999, 2), '19.99');
      expect(minorToDecimalString(-1999, 2), '-19.99');
      expect(minorToDecimalString(5, 2), '0.05');
      expect(minorToDecimalString(0, 2), '0.00');
      expect(minorToDecimalString(1234, 3), '1.234');
      expect(minorToDecimalString(1234, 0), '1234');
      expect(minorToDecimalString(100000, 2), '1000.00');
    });
  });

  group('checkedInt64 boundary contract', () {
    test('accepts the exact int64 bounds', () {
      expect(checkedInt64(int64Max), 9223372036854775807);
      expect(checkedInt64(int64Min), -9223372036854775808);
    });
    test('rejects MAX+1 / MIN-1 (MoneyOverflowException)', () {
      expect(() => checkedInt64(int64Max + BigInt.one),
          throwsA(isA<MoneyOverflowException>()));
      expect(() => checkedInt64(int64Min - BigInt.one),
          throwsA(isA<MoneyOverflowException>()));
    });
    test('overflow on a huge quantize is caught, not silently wrapped', () {
      // 10^20 at scale 2 = 10^22 minor > int64
      expect(() => quantizeDecimalToMinor('100000000000000000000', 2),
          throwsA(isA<MoneyOverflowException>()));
    });
  });

  group('property: exact round-trip and no float artifacts', () {
    test('minorToDecimalString ∘ parseExact is identity at scale', () {
      for (final s in const [0, 2, 3]) {
        for (var m = -100000; m <= 100000; m += 137) {
          final text = minorToDecimalString(m, s);
          expect(parseExactDecimalToMinor(text, s), m, reason: '$text @ $s');
        }
      }
    });
    test('repeated legacy addition stays exact (0.1 × 10 = 1.00)', () {
      var acc = BigInt.zero;
      for (var i = 0; i < 10; i++) {
        acc += BigInt.from(legacyRealToMinor(0.1, 2));
      }
      expect(acc, BigInt.from(100)); // exactly 1.00, not 0.9999999999999999
    });
  });
}
