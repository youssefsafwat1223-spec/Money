import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/money_codec.dart';
import 'package:money_companion/domain/finance/money.dart';

// MALI-026 (Phase-8 B8-2 §2) — the dual-schema money codec. Proves the exact
// physical⇄Money conversion in BOTH modes, so the v30-capable read/write path is
// verified now (schema stays v29).

void main() {
  const v29 = MoneyCodec(MoneyStorageMode.v29Real);
  const v30 = MoneyCodec(MoneyStorageMode.v30Minor);

  group('v29 REAL mode (authoritative today)', () {
    test('read REAL → Money via deterministic legacy quantization', () {
      expect(v29.read(real: 19.99, currency: 'EGP'), Money(1999, 'EGP'));
      expect(v29.read(real: 19.989999999, currency: 'USD'), Money(1999, 'USD'));
      expect(v29.read(real: 1.234, currency: 'KWD'), Money(1234, 'KWD'));
      expect(v29.read(real: 1234.0, currency: 'JPY'), Money(1234, 'JPY'));
    });

    test('readNullable maps null REAL → null Money', () {
      expect(v29.readNullable(real: null, currency: 'EGP'), isNull);
      expect(v29.readNullable(real: 5.5, currency: 'USD'), Money(550, 'USD'));
    });

    test('toReal encodes typical money exactly', () {
      expect(v29.toReal(Money(1999, 'EGP')), 19.99);
      expect(v29.toReal(Money(-50, 'EGP')), -0.50);
      expect(v29.toReal(Money(1234, 'JPY')), 1234.0);
      expect(v29.toReal(Money(1234, 'KWD')), 1.234);
    });

    test('sql literals are EXACT decimals; NULL for absent money', () {
      expect(v29.sqlRealLiteral(Money(1999, 'EGP')), '19.99');
      expect(v29.sqlRealLiteral(Money(-50, 'EGP')), '-0.50');
      expect(v29.sqlRealLiteral(Money(1234, 'KWD')), '1.234');
      expect(v29.sqlRealLiteral(Money(1234, 'JPY')), '1234');
      expect(v29.sqlNullableRealLiteral(null), 'NULL');
      expect(v29.sqlNullableRealLiteral(Money(1999, 'EGP')), '19.99');
    });

    test('bound REAL variables', () {
      expect(v29.realVar(Money(1999, 'EGP')).value, 19.99);
      expect(v29.realVarOrNull(null).value, isNull);
      expect(v29.realVarOrNull(Money(1234, 'KWD')).value, 1.234);
    });
  });

  group('v30 minor mode (v30-capable path proven now)', () {
    test('read minor → exact Money', () {
      expect(v30.read(minor: 1999, currency: 'EGP'), Money(1999, 'EGP'));
      expect(v30.readNullable(minor: null, currency: 'EGP'), isNull);
      expect(v30.readNullable(minor: 1234, currency: 'KWD'), Money(1234, 'KWD'));
    });

    test('toMinor is exact identity', () {
      expect(v30.toMinor(Money(1999, 'EGP')), 1999);
      expect(v30.toMinor(Money(-550, 'USD')), -550);
    });

    test('minor mode preserves values above 2^53 that the REAL shadow loses', () {
      const big = (1 << 53) + 7; // odd → not distinctly representable as a double
      final m = Money(big, 'JPY'); // JPY scale 0: 1 minor = 1 yen
      // v30 authoritative: exact.
      expect(v30.toMinor(m), big);
      expect(v30.read(minor: big, currency: 'JPY').minorUnits, big);
      // v29 REAL shadow: cannot round-trip the exact minor units.
      final realShadow = v29.toReal(m);
      expect(v29.read(real: realShadow, currency: 'JPY').minorUnits, isNot(big));
    });
  });

  test('read fails closed when the mode-required value is absent', () {
    expect(() => v29.read(real: null, currency: 'EGP'),
        throwsA(isA<MoneyStorageException>()));
    expect(() => v30.read(minor: null, currency: 'EGP'),
        throwsA(isA<MoneyStorageException>()));
  });
}
