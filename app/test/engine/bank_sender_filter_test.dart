import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/parser/bank_sender_filter.dart';

void main() {
  group('BankSenderFilter.isLikelyBank', () {
    test('مُعرّف مرسِل أبجدي (بنك) → مقبول', () {
      expect(BankSenderFilter.isLikelyBank('AlRajhiBank'), isTrue);
      expect(BankSenderFilter.isLikelyBank('STCPay'), isTrue);
      expect(BankSenderFilter.isLikelyBank('mada'), isTrue);
    });

    test('رقم هاتف شخصي → مرفوض', () {
      expect(BankSenderFilter.isLikelyBank('+966500000000'), isFalse);
      expect(BankSenderFilter.isLikelyBank('0551234567'), isFalse);
      expect(BankSenderFilter.isLikelyBank('966 55 123 4567'), isFalse);
    });

    test('بنك معروف عبر النص → مقبول حتى لو المرسِل رقم', () {
      expect(
        BankSenderFilter.isLikelyBank('123456', text: 'تنبيه من الراجحي'),
        isTrue,
      );
    });

    test('بلا مُرسِل (لصق/مشاركة) → مقبول', () {
      expect(BankSenderFilter.isLikelyBank(null), isTrue);
      expect(BankSenderFilter.isLikelyBank(''), isTrue);
    });

    test('رسالة شخصية برقم هاتف لا تُقرأ', () {
      expect(
        BankSenderFilter.isLikelyBank('+966512223344',
            text: 'حولتلك ٥٠ ريال يا صاحبي'),
        isFalse,
      );
    });
  });
}
