import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/common/transaction_direction.dart';

TransactionEntity _tx(
  TransactionTypeEntity type,
  String rawMessage, {
  TransactionDirectionEntity? direction,
}) {
  final now = DateTime.utc(2026, 6, 16, 12);
  return TransactionEntity(
    id: 't',
    amountMoney: Money.fromLegacyReal(100, 'SAR'),
    currency: 'SAR',
    type: type,
    source: TransactionSourceEntity.bank,
    occurredAt: now,
    rawMessage: rawMessage,
    parseConfidence: 0.9,
    status: TransactionStatus.confirmed,
    createdAt: now,
    updatedAt: now,
    direction: direction,
  );
}

void main() {
  test('payment and withdrawal are money-out', () {
    expect(
        transactionIsDebit(_tx(TransactionTypeEntity.payment, 'شراء')), isTrue);
    expect(transactionIsDebit(_tx(TransactionTypeEntity.withdrawal, 'سحب')),
        isTrue);
  });

  test('income and refund are money-in', () {
    expect(
        transactionIsDebit(_tx(TransactionTypeEntity.income, 'راتب')), isFalse);
    expect(transactionIsDebit(_tx(TransactionTypeEntity.refund, 'استرداد')),
        isFalse);
  });

  test('incoming transfer (credit wording) is money-in', () {
    expect(
      transactionIsDebit(
          _tx(TransactionTypeEntity.transfer, 'حوالة واردة 500')),
      isFalse,
    );
  });

  test('outgoing transfer (no credit wording) is money-out', () {
    expect(
      transactionIsDebit(
          _tx(TransactionTypeEntity.transfer, 'حوالة صادرة 500')),
      isTrue,
    );
  });

  test('stored AI direction wins for transfer display', () {
    expect(
      transactionIsDebit(_tx(
        TransactionTypeEntity.transfer,
        'ambiguous transfer text',
        direction: TransactionDirectionEntity.credit,
      )),
      isFalse,
    );
  });
}
