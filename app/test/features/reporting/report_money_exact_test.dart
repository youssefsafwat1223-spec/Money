import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/reporting/composition/report_money_formatter.dart';

void main() {
  for (final language in ['ar', 'en']) {
    final formatter = ReportMoneyFormatter(language);
    test('KWD exact formatter retains minor units and signed magnitude in $language', () {
      final amount = Money(9007199254740993, 'KWD');
      final token = language == 'en' ? 'KWD' : 'دينار';
      final expected = '9,007,199,254,740.993 $token';
      expect(formatter.moneyExact(amount), expected);
      expect(formatter.moneyExact(-amount), expected);
      expect(formatter.signedMoneyExact(amount), '+$expected');
      expect(formatter.signedMoneyExact(-amount), '−$expected');
      expect(formatter.signedMoneyExact(amount, isExpense: true), '−$expected');
    });
    test('JPY and int64-min magnitudes format without floating point in $language', () {
      expect(formatter.signedMoneyExact(Money(-9007199254740993, 'JPY')),
          '−9,007,199,254,740,993 JPY');
      final token = language == 'en' ? 'KWD' : 'دينار';
      expect(formatter.signedMoneyExact(Money(-9223372036854775808, 'KWD')),
          '−9,223,372,036,854,775.808 $token');
    });
    test('privacy masks sign currency and magnitude in $language', () {
      final private = ReportMoneyFormatter(language, masked: true);
      expect(private.moneyExact(Money(9007199254740993, 'KWD')), '••••');
      expect(private.signedMoneyExact(Money(-9007199254740993, 'JPY')), '••••');
    });
  }
}
