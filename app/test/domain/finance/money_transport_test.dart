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
}
