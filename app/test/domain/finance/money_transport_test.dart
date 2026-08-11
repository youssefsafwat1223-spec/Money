import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/finance/money_transport.dart';

// MALI-026 (Phase-8 B8-2 §6/§7) — the single exact NUMERIC transport serializer.

void main() {
  test('PUSH: moneyToNumericText is the exact decimal string (no double)', () {
    expect(moneyToNumericText(Money(1999, 'EGP')), '19.99');
    expect(moneyToNumericText(Money(-50, 'EGP')), '-0.50');
    expect(moneyToNumericText(Money(1234, 'KWD')), '1.234');
    expect(moneyToNumericText(Money(1234, 'JPY')), '1234');
  });

  test('PULL: ::text String → exact Money; null → null', () {
    expect(moneyFromPulledValue('19.99', 'EGP'), Money(1999, 'EGP'));
    expect(moneyFromPulledValue('1.234', 'KWD'), Money(1234, 'KWD'));
    expect(moneyFromPulledValue(null, 'EGP'), isNull);
  });

  test('PULL fails EXPLICITLY when the value is not a ::text String (no silent '
      'toDouble)', () {
    // A JSON number means the ::text projection was not applied — reject it.
    expect(() => moneyFromPulledValue(19.99, 'EGP'),
        throwsA(isA<MoneyTransportException>()));
    expect(() => moneyFromPulledValue(1999, 'EGP'),
        throwsA(isA<MoneyTransportException>()));
    expect(() => moneyFromPulledValueRequired(null, 'EGP'),
        throwsA(isA<MoneyTransportException>()));
  });

  test('PULL required: non-null String → Money', () {
    expect(moneyFromPulledValueRequired('0.00', 'EGP'), Money(0, 'EGP'));
  });

  test('LEGACY JSON-number push shape is derived from Money (compat only)', () {
    expect(moneyToLegacyJsonNumber(Money(1999, 'EGP')), 19.99);
    expect(moneyToLegacyJsonNumber(Money(1234, 'JPY')), 1234);
  });

  // B8-2.8 §12 — EXACT push string-coercion proof: the canonical decimal STRING
  // survives Dart JSON encoding as a JSON STRING byte-unchanged (no double on the
  // path). Server coercion (JSON string -> PostgreSQL NUMERIC) stays EXTERNAL.
  group('EXACT push (moneyToNumericText) is a byte-exact JSON string', () {
    void expectString(Money m, String text) {
      expect(moneyToNumericText(m), text);
      expect(json.encode({'amount': moneyToNumericText(m)}),
          contains('"amount":"$text"'));
      // never a JSON number for the canonical field:
      expect(json.encode({'amount': moneyToNumericText(m)}).contains('"amount":$text'),
          isFalse);
    }

    test('scale 0 / 2 / 3 + negative', () {
      expectString(Money(1234, 'JPY'), '1234'); // 0-decimal
      expectString(Money(1999, 'EGP'), '19.99'); // 2-decimal
      expectString(Money(1234, 'KWD'), '1.234'); // 3-decimal
      expectString(Money(-50, 'EGP'), '-0.50'); // negative
    });

    test('beyond JS safe-integer precision stays exact as a string', () {
      const big = (1 << 53) + 7; // 9007199254740999 — not exactly a JS/double int
      final m = Money(big, 'JPY');
      expectString(m, '9007199254740999');
      // a lossy JSON *number* for the same magnitude would collapse to ...741000:
      final asNumber = json.encode({'amount': big.toDouble()});
      expect(asNumber.contains('9007199254740999'), isFalse);
    });

    test('INT64-near-boundary decimal stays exact as a string', () {
      final m = Money(9223372036854775807, 'JPY'); // int64 max
      expectString(m, '9223372036854775807');
      final m2 = Money(-9223372036854775807, 'EGP'); // near int64 min (2-dec)
      expectString(m2, '-92233720368547758.07');
    });
  });
}
