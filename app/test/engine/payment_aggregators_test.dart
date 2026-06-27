import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/parser/payment_aggregators.dart';

void main() {
  group('PaymentAggregators.resolveMerchant', () {
    test('strips a leading gateway and returns the real merchant', () {
      expect(PaymentAggregators.resolveMerchant('Fawry MCDONALDS'), 'MCDONALDS');
      expect(PaymentAggregators.resolveMerchant('FAWRY*ABU SHAKRA'),
          'ABU SHAKRA');
      expect(PaymentAggregators.resolveMerchant('fawry - Spinneys'), 'Spinneys');
    });

    test('keeps a bare gateway name unchanged (no merchant to extract)', () {
      expect(PaymentAggregators.resolveMerchant('Fawry'), 'Fawry');
      expect(PaymentAggregators.resolveMerchant('FAWRY '), 'FAWRY ');
    });

    test('does not strip when the gateway is only a name prefix', () {
      // "FAWRYZONE" is a real merchant, not "Fawry" + "ZONE".
      expect(PaymentAggregators.resolveMerchant('FAWRYZONE'), 'FAWRYZONE');
    });

    test('leaves non-gateway merchants untouched', () {
      expect(PaymentAggregators.resolveMerchant('STARBUCKS'), 'STARBUCKS');
      expect(PaymentAggregators.resolveMerchant(null), isNull);
    });
  });

  group('PaymentAggregators.isAggregator', () {
    test('true only for an exact bare gateway name', () {
      expect(PaymentAggregators.isAggregator('Fawry'), isTrue);
      expect(PaymentAggregators.isAggregator('  fawry '), isTrue);
      expect(PaymentAggregators.isAggregator('Fawry MCDONALDS'), isFalse);
      expect(PaymentAggregators.isAggregator('STARBUCKS'), isFalse);
      expect(PaymentAggregators.isAggregator(null), isFalse);
    });
  });
}
