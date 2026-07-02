import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/features/capture/services/capture_notification_content.dart';

TransactionEntity _tx({
  double amount = 150,
  String currency = 'SAR',
  TransactionTypeEntity type = TransactionTypeEntity.payment,
  String? rawMerchant,
  String? categoryId,
  String? cardLast4,
  double? balanceAfter,
  double? foreignAmount,
  String? foreignCurrency,
}) {
  final now = DateTime.utc(2026, 7, 2, 12);
  return TransactionEntity(
    id: 'tx-1',
    amount: amount,
    currency: currency,
    type: type,
    source: TransactionSourceEntity.bank,
    occurredAt: now,
    rawMessage: 'msg',
    parseConfidence: 0.9,
    status: TransactionStatus.pending,
    createdAt: now,
    updatedAt: now,
    rawMerchant: rawMerchant,
    categoryId: categoryId,
    cardLast4: cardLast4,
    balanceAfter: balanceAfter,
    foreignAmount: foreignAmount,
    foreignCurrency: foreignCurrency,
  );
}

void main() {
  group('buildConfirmedCaptureContent', () {
    test('full details: type + amount + merchant + category + card + balance',
        () {
      final content = buildConfirmedCaptureContent(_tx(
        rawMerchant: 'STARBUCKS',
        categoryId: 'cafes',
        cardLast4: '1234',
        balanceAfter: 3450,
      ));

      expect(content.title, 'خصم ✓ 150 SAR');
      expect(
        content.body,
        'لدى STARBUCKS · مقاهي ☕ · بطاقة •1234 · رصيدك 3450 SAR',
      );
    });

    test('income uses إيداع and من for the sender', () {
      final content = buildConfirmedCaptureContent(_tx(
        type: TransactionTypeEntity.income,
        amount: 5000,
        rawMerchant: 'شركة أرامكو',
      ));

      expect(content.title, 'إيداع ✓ 5000 SAR');
      expect(content.body, 'من شركة أرامكو');
    });

    test('foreign amount shown in parentheses', () {
      final content = buildConfirmedCaptureContent(_tx(
        amount: 187.5,
        foreignAmount: 50,
        foreignCurrency: 'USD',
      ));

      expect(content.title, 'خصم ✓ 187.50 SAR (50 USD)');
    });

    test('no details falls back to account wording', () {
      expect(buildConfirmedCaptureContent(_tx()).body, 'من حسابك.');
      expect(
        buildConfirmedCaptureContent(_tx(type: TransactionTypeEntity.income))
            .body,
        'في حسابك.',
      );
    });

    test('null transaction has a generic fallback', () {
      final content = buildConfirmedCaptureContent(null);
      expect(content.title, 'تم التقاط العملية');
    });
  });

  group('buildReviewCaptureContent', () {
    test('title asks to confirm with definite type and amount', () {
      final content = buildReviewCaptureContent(_tx(
        type: TransactionTypeEntity.withdrawal,
        amount: 500,
        cardLast4: '9876',
      ));

      expect(content.title, 'أكّد السحب — 500 SAR');
      expect(content.body, 'بطاقة •9876');
    });

    test('null transaction has a generic fallback', () {
      final content = buildReviewCaptureContent(null);
      expect(content.title, 'أكّد العملية');
    });
  });

  group('buildDuplicateCaptureContent', () {
    test('body includes amount and merchant', () {
      final content = buildDuplicateCaptureContent(_tx(
        rawMerchant: 'AMAZON',
      ));

      expect(content.title, 'عملية مشابهة');
      expect(content.body, '150 SAR لدى AMAZON — موجودة مسبقاً؟ اضغط للمراجعة.');
    });
  });

  test('fmtCaptureAmount trims whole numbers and keeps 2dp otherwise', () {
    expect(fmtCaptureAmount(150), '150');
    expect(fmtCaptureAmount(150.5), '150.50');
  });
}
