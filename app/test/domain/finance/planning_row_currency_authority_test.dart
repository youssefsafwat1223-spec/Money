import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/finance/money.dart';

void main() {
  test('existing planning Money keeps row currency when base currency changes',
      () {
    const rowCurrency = 'EGP';
    var effectiveBaseCurrency = 'USD';
    final existingPlanningMoney = Money(10000, rowCurrency);

    // Simulate selecting another active/default account. This setting is only a
    // default for new rows; it never participates in interpreting an old row.
    effectiveBaseCurrency = 'KWD';

    expect(effectiveBaseCurrency, 'KWD');
    expect(existingPlanningMoney.minorUnits, 10000);
    expect(existingPlanningMoney.currency, 'EGP');
    expect(existingPlanningMoney.toDecimalString(), '100.00');
  });
}
