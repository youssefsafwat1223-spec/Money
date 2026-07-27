import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/parser/parser_engine.dart';

void main() {
  const engine = ParserEngine();

  String? accountNumberOf(String sms) =>
      engine.parse(sms).transaction?.accountNumber;

  test('extracts masked account number stated next to "حساب" (xxxx4521)', () {
    expect(
      accountNumberOf('خصم 20 ريال من حسابك xxxx4521 لدى متجر'),
      '4521',
    );
  });

  test('extracts English "account no. 998877"', () {
    expect(
      accountNumberOf('Purchase 15 SAR from account no. 998877 at Store'),
      '998877',
    );
  });

  test('no account keyword → no account number (card-only SMS)', () {
    // بطاقة فقط، بلا ذكر حساب.
    expect(
      accountNumberOf('شراء 30 ريال بطاقة ****1234 لدى متجر'),
      isNull,
    );
  });
}
