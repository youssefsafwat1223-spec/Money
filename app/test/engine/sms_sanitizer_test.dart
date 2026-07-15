import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/models/transaction_type.dart';
import 'package:money_companion/engine/privacy/sms_sanitizer.dart';

void main() {
  group('SmsSanitizer — required transfer/purchase distinction', () {
    // ── REQUIRED TEST 1: transfer SMS → beneficiary absent in AI payload ──
    test(
      'transfer SMS: إلى: NAME is stripped — real person name must not reach AI',
      () {
        const sms = 'تحويل داخلي صادر\n'
            'المبلغ: 1500.00 ر.س\n'
            'إلى: سارة الأسمري\n'
            'حساب: *5438\n'
            'في: 16/04/2026 10:30';
        final sanitized = SmsSanitizer.sanitize(
          sms,
          detectedType: TransactionType.transfer,
        );
        expect(sanitized, isNot(contains('سارة')),
            reason: 'Beneficiary first name must be stripped');
        expect(sanitized, isNot(contains('الأسمري')),
            reason: 'Beneficiary family name must be stripped');
        expect(sanitized, contains('إلى:'),
            reason: 'The إلى: keyword itself is kept for context');
        expect(sanitized, contains('[REDACTED]'));
        expect(sanitized, contains('1500.00'),
            reason: 'Amount must survive — AI needs it for grounding check');
      },
    );

    // ── REQUIRED TEST 2: purchase SMS → merchant name present in AI payload ──
    test(
      'purchase/POS SMS: merchant name is kept — business name is not PII',
      () {
        const sms = 'شراء عبر نقاط البيع\n'
            'بـ: SAR 45.00\n'
            'لدى: STARBUCKS RIYADH PARK\n'
            'بطاقة: *9221\n'
            'في: 2026-04-16 09:00';
        final sanitized = SmsSanitizer.sanitize(
          sms,
          detectedType: TransactionType.payment,
        );
        expect(sanitized, contains('STARBUCKS'),
            reason: 'Merchant (business) must be kept for AI categorization');
        expect(sanitized, contains('45.00'));
      },
    );

    // ── Unknown type → strip (safer) ──
    test(
      'unknown type (null): إلى: content stripped — cannot confirm it is a business',
      () {
        const sms =
            'Amount: SAR 200.00\nTo: ABDELRAHMAN ABDALLA\nDate: 2026-04-16';
        final sanitized = SmsSanitizer.sanitize(sms);
        expect(sanitized, isNot(contains('ABDELRAHMAN')));
        expect(sanitized, isNot(contains('ABDALLA')));
        expect(sanitized, contains('To: [REDACTED]'));
        expect(sanitized, contains('200.00'));
      },
    );
  });

  group('SmsSanitizer — PII field stripping', () {
    test('full 16-digit card number is replaced with [CARD]', () {
      const sms = 'Your card 4111 1111 1111 1111 was charged SAR 50.00';
      final sanitized = SmsSanitizer.sanitize(sms);
      expect(sanitized, isNot(contains('4111')));
      expect(sanitized, contains('[CARD]'));
      expect(sanitized, contains('SAR 50.00'));
    });

    test('card with dashes is replaced', () {
      const sms = 'Charge on 4111-1111-1111-1111 at NOON for SAR 120.00';
      final sanitized = SmsSanitizer.sanitize(sms);
      expect(sanitized, isNot(contains('4111')));
      expect(sanitized, contains('[CARD]'));
    });

    test('masked *1234 last-4 form is kept — not PII', () {
      const sms = 'بطاقتك *9221 تم خصم SAR 25.00';
      final sanitized = SmsSanitizer.sanitize(sms);
      expect(sanitized, contains('*9221'),
          reason:
              'Masked last-4 is not sensitive and helps users identify card');
    });

    test('Saudi mobile number is replaced', () {
      const sms = 'للاستفسار اتصل بـ 0512345678 أو زيارة الفرع';
      final sanitized = SmsSanitizer.sanitize(sms);
      expect(sanitized, isNot(contains('0512345678')));
      expect(sanitized, contains('[PHONE]'));
    });

    test('Egyptian mobile number is replaced', () {
      const sms = 'للمساعدة 01012345678 أو اتصل بالرقم 19623';
      final sanitized = SmsSanitizer.sanitize(sms);
      expect(sanitized, isNot(contains('01012345678')));
      expect(sanitized, contains('[PHONE]'));
      // 5-digit hotline (19623) should NOT be stripped — below 10-digit threshold
      expect(sanitized, contains('19623'));
    });

    test('international +966 phone is replaced', () {
      const sms = 'Contact us at +966512345678 for support';
      final sanitized = SmsSanitizer.sanitize(sms);
      expect(sanitized, isNot(contains('+966512345678')));
      expect(sanitized, contains('[PHONE]'));
    });

    test('long account number (10+ digits) is replaced', () {
      const sms = 'تم تحويل المبلغ من حساب 1234567890 إلى 0987654321';
      final sanitized = SmsSanitizer.sanitize(sms);
      expect(sanitized, isNot(contains('1234567890')));
      expect(sanitized, isNot(contains('0987654321')));
      expect(sanitized, contains('[ACCOUNT]'));
    });

    test('short amounts are not stripped by account-number pattern', () {
      // 250000 is 6 digits — under the 10-digit threshold
      const sms = 'Purchase SAR 250000 at BIG STORE on 2026-04-16';
      final sanitized = SmsSanitizer.sanitize(sms);
      expect(sanitized, contains('250000'),
          reason: '6-digit amount must not be stripped as an account number');
    });

    test('Arabic greeting with name is replaced', () {
      const sms = 'عزيزي أحمد، تم خصم SAR 100.00 من حسابك لدى NOON';
      final sanitized = SmsSanitizer.sanitize(sms);
      expect(sanitized, isNot(contains('أحمد')));
      expect(sanitized, contains('[REDACTED]'));
      expect(sanitized, contains('100.00'));
      // NOON is a merchant, kept (payment type not specified → default strips إلى: only)
      expect(sanitized, contains('NOON'));
    });

    test('income type strips sender name (salary payer may be a person)', () {
      const sms =
          'إيداع من: محمد الغامدي\nالمبلغ: 8500.00 SAR\nإلى: حسابك *1234';
      final sanitized = SmsSanitizer.sanitize(
        sms,
        detectedType: TransactionType.income,
      );
      // Income is treated like transfer — strip إلى: content
      expect(sanitized, isNot(contains('حسابك')),
          reason: 'Income also strips the إلى: portion');
      expect(sanitized, contains('8500.00'));
    });
  });

  group('SmsSanitizer — amounts and dates survive', () {
    test('all amount forms are preserved after sanitization', () {
      const sms = 'Debit SAR 1,234.56 on card *4321. Balance: SAR 18,000.00';
      final sanitized = SmsSanitizer.sanitize(
        sms,
        detectedType: TransactionType.payment,
      );
      expect(sanitized, contains('1,234.56'));
      expect(sanitized, contains('18,000.00'));
    });

    test('dates are preserved', () {
      const sms = 'Purchase SAR 75.00 at CAFE ARABICA on 16/04/2026 09:30';
      final sanitized = SmsSanitizer.sanitize(
        sms,
        detectedType: TransactionType.payment,
      );
      expect(sanitized, contains('16/04/2026'));
      expect(sanitized, contains('09:30'));
    });

    test('sender bank short codes are preserved', () {
      const sms = 'SNB: شراء SAR 45.00 لدى HERFY بطاقة *5678';
      final sanitized = SmsSanitizer.sanitize(
        sms,
        detectedType: TransactionType.payment,
      );
      expect(sanitized, contains('SNB'));
      expect(sanitized, contains('HERFY'));
    });

    // ── REQUIRED: amount-with-currency suffix survives (e.g. CIB Egypt) ──
    test(
      '60.00EGP (amount glued to currency code) survives — digits < 10 are not account numbers',
      () {
        // Real CIB Egypt SMS shape. 60.00 is only 4 digits; EGP is the currency.
        const sms = 'تم خصم 60.00EGP من بطاقة المدفوعة مقدماً رقم 4907 '
            'عند FAWRY*NWR يوم 14/03 الساعه 22:29 المتاح 28.14 '
            'للمزيد إتصل ب 19623';
        final sanitized = SmsSanitizer.sanitize(
          sms,
          detectedType: TransactionType.payment,
        );
        expect(sanitized, contains('60.00EGP'),
            reason:
                'Transaction amount must survive — grounding check needs it');
        expect(sanitized, contains('28.14'),
            reason: 'Balance (5 digits max with decimal) must also survive');
        // 4907 is a 4-digit last-4 — not stripped
        expect(sanitized, contains('4907'));
        // 19623 is a 5-digit hotline — not stripped
        expect(sanitized, contains('19623'));
      },
    );

    // ── REQUIRED: 10-digit reference stripped; amount on the same message survives ──
    test(
      'ANB-style: 10-digit reference 6824106852 is stripped, amount SAR 242.00 is NOT',
      () {
        // Real ANB ATM withdrawal shape from the golden fixture corpus.
        // The reference number (6824106852) has 10 consecutive digits → stripped.
        // The amount (242.00) has only 3 consecutive digits before the decimal → kept.
        const sms = 'ATM Withdrawal\n'
            'Amount: SAR 242.00\n'
            'Card: *3456\n'
            'Reference: 6824106852\n'
            'Date: 2026-04-10 14:30';
        final sanitized = SmsSanitizer.sanitize(
          sms,
          detectedType: TransactionType.withdrawal,
        );
        expect(sanitized, isNot(contains('6824106852')),
            reason: '10-digit reference number must be stripped as [ACCOUNT]');
        expect(sanitized, contains('[ACCOUNT]'));
        expect(sanitized, contains('242.00'),
            reason: 'Transaction amount must survive intact');
        expect(sanitized, contains('SAR'), reason: 'Currency must survive');
        // *3456 is a masked last-4 — kept
        expect(sanitized, contains('*3456'));
      },
    );

    // ── Mix: two long reference numbers + two small amounts in one message ──
    test(
      'multiple long references stripped, multiple amounts kept in one message',
      () {
        const sms = 'Purchase SAR 150.00 at NOON\n'
            'Card: *7890\n'
            'Auth: 9876543210\n' // 10-digit auth code → stripped
            'Trace: 12345678901\n' // 11-digit trace → stripped
            'Balance: SAR 4,820.50\n'
            'Date: 2026-06-16';
        final sanitized = SmsSanitizer.sanitize(
          sms,
          detectedType: TransactionType.payment,
        );
        expect(sanitized, isNot(contains('9876543210')));
        expect(sanitized, isNot(contains('12345678901')));
        expect(sanitized, contains('150.00'),
            reason: 'Primary amount must survive');
        expect(sanitized, contains('4,820.50'),
            reason: 'Balance with thousands separator must survive');
      },
    );
  });
}
