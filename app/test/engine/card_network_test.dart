import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/parser/card_network.dart';

void main() {
  group('CardNetworkDetector.detect', () {
    test('مدى', () {
      expect(
          CardNetworkDetector.detect('بطاقة:مدى;****4521'), CardNetwork.mada);
      expect(CardNetworkDetector.detect('mada card'), CardNetwork.mada);
    });
    test('Visa', () {
      expect(CardNetworkDetector.detect('VISA ending 1234'), CardNetwork.visa);
      expect(CardNetworkDetector.detect('بطاقة فيزا'), CardNetwork.visa);
    });
    test('Mastercard', () {
      expect(CardNetworkDetector.detect('Mastercard purchase'),
          CardNetwork.mastercard);
      expect(CardNetworkDetector.detect('بطاقة ماستر كارد'),
          CardNetwork.mastercard);
    });
    test('غير معروف', () {
      expect(CardNetworkDetector.detect('عملية شراء 45 ريال'),
          CardNetwork.unknown);
    });
  });
}
