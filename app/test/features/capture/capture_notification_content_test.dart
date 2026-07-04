import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/features/capture/services/capture_notification_content.dart';

final _fixedNow = DateTime.utc(2026, 7, 2, 14);

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
    test('full details: labeled line per field, no balance line', () {
      final content = buildConfirmedCaptureContent(
        _tx(
          rawMerchant: 'STARBUCKS',
          categoryId: 'cafes',
          cardLast4: '1234',
          balanceAfter: 3450,
        ),
        now: _fixedNow,
      );

      expect(content.title, 'تم رصد عملية شراء 🛒');
      final lines = content.body.split('\n');
      expect(lines[0], 'المبلغ: 150 SAR');
      expect(lines[1], 'التاجر: STARBUCKS');
      expect(lines[2], 'البطاقة: ****1234');
      expect(lines[3], startsWith('الوقت: '));
      expect(lines[4], 'التصنيف: مقاهي ☕');
      // الرصيد لا يظهر أبداً في الإشعار (خصوصية شاشة القفل).
      expect(content.body.contains('رصيد'), isFalse);
    });

    test('income uses إيداع title and المصدر label', () {
      final content = buildConfirmedCaptureContent(
        _tx(
          type: TransactionTypeEntity.income,
          amount: 5000,
          rawMerchant: 'شركة أرامكو',
        ),
        now: _fixedNow,
      );

      expect(content.title, 'تم رصد إيداع 💰');
      expect(content.body, contains('المصدر: شركة أرامكو'));
    });

    test('foreign amount shown in parentheses in the amount line', () {
      final content = buildConfirmedCaptureContent(
        _tx(amount: 187.5, foreignAmount: 50, foreignCurrency: 'USD'),
        now: _fixedNow,
      );

      expect(content.body, contains('المبلغ: 187.50 SAR (50 USD)'));
    });

    test('minimal transaction still shows amount and time lines', () {
      final content = buildConfirmedCaptureContent(_tx(), now: _fixedNow);
      final lines = content.body.split('\n');
      expect(lines[0], 'المبلغ: 150 SAR');
      expect(lines[1], startsWith('الوقت: '));
    });

    test('null transaction has a generic fallback', () {
      final content = buildConfirmedCaptureContent(null);
      expect(content.title, 'تم التقاط العملية');
    });
  });

  group('buildReviewCaptureContent', () {
    test('title asks to confirm; body has details plus tap hint', () {
      final content = buildReviewCaptureContent(
        _tx(
          type: TransactionTypeEntity.withdrawal,
          amount: 500,
          cardLast4: '9876',
        ),
        now: _fixedNow,
      );

      expect(content.title, 'أكّد السحب — 500 SAR');
      expect(content.body, contains('المبلغ: 500 SAR'));
      expect(content.body, contains('البطاقة: ****9876'));
      expect(content.body, endsWith('اضغط للمراجعة والتأكيد.'));
    });

    test('null transaction has a generic fallback', () {
      final content = buildReviewCaptureContent(null);
      expect(content.title, 'أكّد العملية');
    });
  });

  group('buildDuplicateCaptureContent', () {
    test('body includes details and review hint', () {
      final content = buildDuplicateCaptureContent(
        _tx(rawMerchant: 'AMAZON'),
        now: _fixedNow,
      );

      expect(content.title, 'عملية مشابهة ⚠️');
      expect(content.body, contains('المبلغ: 150 SAR'));
      expect(content.body, contains('التاجر: AMAZON'));
      expect(content.body, endsWith('موجودة مسبقاً؟ اضغط للمراجعة.'));
    });
  });

  group('captureTimeLabel', () {
    test('same day → اليوم with 12h time', () {
      final occurred = DateTime(2026, 7, 2, 21, 41);
      final now = DateTime(2026, 7, 2, 23);
      expect(captureTimeLabel(occurred, now: now), 'اليوم 9:41 م');
    });

    test('previous day → أمس', () {
      final occurred = DateTime(2026, 7, 1, 9, 5);
      final now = DateTime(2026, 7, 2, 23);
      expect(captureTimeLabel(occurred, now: now), 'أمس 9:05 ص');
    });

    test('older → d/M', () {
      final occurred = DateTime(2026, 6, 20, 12, 0);
      final now = DateTime(2026, 7, 2, 23);
      expect(captureTimeLabel(occurred, now: now), '20/6 12:00 م');
    });
  });

  test('fmtCaptureAmount trims whole numbers and keeps 2dp otherwise', () {
    expect(fmtCaptureAmount(150), '150');
    expect(fmtCaptureAmount(150.5), '150.50');
  });
}
