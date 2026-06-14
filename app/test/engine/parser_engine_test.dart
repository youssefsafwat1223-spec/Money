import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/models/transaction_source.dart';
import 'package:money_companion/engine/models/transaction_type.dart';
import 'package:money_companion/engine/parser/bank_profile.dart';
import 'package:money_companion/engine/parser/parser_engine.dart';

import 'fixtures/sample_messages.dart';

void main() {
  const engine = ParserEngine();

  group('ParserEngine — استخراج العمليات', () {
    test('دفع ببطاقة (عربي): generic parser لا يصلح للحفظ التلقائي', () {
      final r = engine.parse(SampleMessages.cardPaymentAr);
      expect(r.isTransaction, isTrue);
      final t = r.transaction!;
      expect(t.amount, 45.00);
      expect(t.currency, 'SAR');
      expect(t.rawMerchant, 'BURGER BOUTIQUE');
      expect(t.type, TransactionType.payment);
      expect(t.source, TransactionSource.card);
      expect(t.cardLast4, '4521');
      expect(t.balanceAfter, 2310.50);
      expect(t.occurredAt, DateTime(2026, 4, 8, 12, 45));
      expect(t.parseConfidence, ParserEngine.genericMaxConfidence);
    });

    test('دفع ببطاقة (عربي): senderId معروف يرفع الثقة للحفظ الآمن', () {
      final r = engine.parse(SampleMessages.cardPaymentAr, senderId: 'SNB');
      expect(r.bankKey, 'snb');
      expect(r.isTransaction, isTrue);
      expect(r.transaction!.parseConfidence, greaterThanOrEqualTo(0.92));
    });

    test('دفع ببطاقة (إنجليزي مختلط)', () {
      final r = engine.parse(SampleMessages.cardPaymentEn);
      expect(r.isTransaction, isTrue);
      final t = r.transaction!;
      expect(t.amount, 45.00);
      expect(t.rawMerchant, 'BURGER BOUTIQUE');
      expect(t.cardLast4, '4521');
      expect(t.type, TransactionType.payment);
    });

    test('سحب نقدي من الصراف', () {
      final t = engine.parse(SampleMessages.atmWithdrawal).transaction!;
      expect(t.amount, 500.00);
      expect(t.type, TransactionType.withdrawal);
      expect(t.cardLast4, '4521');
      expect(t.balanceAfter, 1810.50);
    });

    test('تحويل صادر', () {
      final t = engine.parse(SampleMessages.transfer).transaction!;
      expect(t.amount, 300.00);
      expect(t.type, TransactionType.transfer);
    });

    test('إيداع راتب (دخل)', () {
      final t = engine.parse(SampleMessages.salaryIncome).transaction!;
      expect(t.amount, 9500.00);
      expect(t.type, TransactionType.income);
    });

    test('استرداد مبلغ', () {
      final t = engine.parse(SampleMessages.refund).transaction!;
      expect(t.amount, 45.00);
      expect(t.type, TransactionType.refund);
      expect(t.rawMerchant, 'BURGER BOUTIQUE');
    });

    test('STC Pay — العملة بعد الرقم + محفظة (عبر senderId)', () {
      final t =
          engine.parse(SampleMessages.stcPay, senderId: 'STCPay').transaction!;
      expect(t.amount, 30.00);
      expect(t.rawMerchant, 'JARIR');
      expect(t.type, TransactionType.payment);
      expect(t.source, TransactionSource.wallet);
    });

    test('أرقام هندية تُطبَّع وتُستخرج', () {
      final t = engine.parse(SampleMessages.arabicIndicDigits).transaction!;
      expect(t.amount, 250.75);
      expect(t.rawMerchant, 'بنده');
      expect(t.occurredAt, DateTime(2026, 4, 8, 14, 30));
    });

    test('يستخرج عملات غير SAR', () {
      final egp = engine
          .parse('شراء بمبلغ 125.50 جنيه مصري لدى MARKET 2026-04-08 12:00')
          .transaction!;
      expect(egp.amount, 125.50);
      expect(egp.currency, 'EGP');

      final aed = engine
          .parse('Purchase AED 42.00 At COFFEE SHOP 2026-04-08 12:00')
          .transaction!;
      expect(aed.amount, 42.00);
      expect(aed.currency, 'AED');
    });

    test('لا يخلط مبلغ العملية مع الرصيد أو reference أو آخر 4 أرقام', () {
      final t = engine.parse(
        '''
Purchase SAR 45.00 At GROCERY
Card ending 4521
Balance SAR 200.00
Ref 987654
2026-04-08 12:00''',
        senderId: 'SNB',
      ).transaction!;

      expect(t.amount, 45.00);
      expect(t.balanceAfter, 200.00);
      expect(t.cardLast4, '4521');
      expect(t.rawMerchant, 'GROCERY');
      expect(t.parseConfidence, greaterThanOrEqualTo(0.92));
    });

    test('أكثر من مبلغ عملية قوي يجعل الرسالة تحتاج confirmation', () {
      final t = engine.parse(
        '''
Purchase SAR 45.00 At GROCERY
Amount SAR 50.00
2026-04-08 12:00''',
        senderId: 'SNB',
      ).transaction!;

      expect(t.parseConfidence,
          greaterThanOrEqualTo(ParserEngine.pendingThreshold));
      expect(t.parseConfidence, lessThan(0.92));
    });
  });

  group('ParserEngine — تجاهل غير المالي (§24.6)', () {
    test('رسالة OTP تُتجاهَل', () {
      expect(engine.parse(SampleMessages.otpMessage).isTransaction, isFalse);
    });

    test('رسالة عرض ترويجي تُتجاهَل', () {
      expect(engine.parse(SampleMessages.promoMessage).isTransaction, isFalse);
    });
  });

  group('ParserEngine — كشف البنك', () {
    test('STC Pay يُكتشف كـ stcpay عبر senderId', () {
      expect(
        engine.parse(SampleMessages.stcPay, senderId: 'STCPay').bankKey,
        'stcpay',
      );
    });

    test('profiles خارجية توسع كشف البنك بدون تغيير المحرك', () {
      final result = engine.parse(
        'Purchase EGP 85.00 At GROCERY 2026-04-08 12:00',
        senderId: 'CIB Alerts',
        bankProfiles: const [
          BankProfile(
            bankKey: 'cib_eg',
            displayName: 'CIB Egypt',
            keywords: ['cib alerts'],
            defaultSource: TransactionSource.bank,
          ),
        ],
      );

      expect(result.bankKey, 'cib_eg');
      expect(result.transaction!.currency, 'EGP');
    });
  });
}
