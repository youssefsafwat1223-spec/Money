import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/subscriptions/bill_payment_attempt.dart';

BillPaymentEntity _payment(String id, DateTime paidAt) => BillPaymentEntity(
      id: id,
      billId: 'bill-1',
      amountMoney: Money.fromLegacyReal(25, 'EGP'),
      currency: 'EGP',
      periodStart: DateTime.utc(2026, 7, 1),
      periodEnd: DateTime.utc(2026, 7, 31),
      paidAt: paidAt,
    );

TransactionEntity _transaction(String id) => TransactionEntity(
      id: id,
      type: TransactionTypeEntity.payment,
      amount: 25,
      currency: 'EGP',
      occurredAt: DateTime.utc(2026, 7, 14),
      rawMerchant: 'QA Bill',
      source: TransactionSourceEntity.unknown,
      rawMessage: 'QA Bill',
      parseConfidence: 1,
      status: TransactionStatus.confirmed,
      createdAt: DateTime.utc(2026, 7, 14),
      updatedAt: DateTime.utc(2026, 7, 14),
    );

void main() {
  test('concurrent submits perform one transaction and one payment request',
      () async {
    final attempt = BillPaymentAttempt(
      requestId: 'stable-payment',
      paidAt: DateTime.utc(2026, 7, 14),
    );
    final gate = Completer<void>();
    var transactionCalls = 0;
    var paymentCalls = 0;

    Future<void> submit() => attempt.submit(
          buildPayment: _payment,
          createTransaction: (_) async {
            transactionCalls += 1;
            return _transaction('transaction-1');
          },
          recordPayment: (payment) async {
            paymentCalls += 1;
            expect(payment.id, 'stable-payment');
            await gate.future;
          },
        );

    final first = submit();
    final second = submit();
    await Future<void>.delayed(Duration.zero);
    expect(transactionCalls, 1);
    expect(paymentCalls, 1);
    gate.complete();
    await Future.wait([first, second]);
  });

  test('retry reuses payment id, paid time, and saved transaction', () async {
    final paidAt = DateTime.utc(2026, 7, 14, 12);
    final attempt = BillPaymentAttempt(
      requestId: 'stable-payment',
      paidAt: paidAt,
    );
    var transactionCalls = 0;
    final recorded = <BillPaymentEntity>[];

    Future<void> submit() => attempt.submit(
          buildPayment: _payment,
          createTransaction: (_) async {
            transactionCalls += 1;
            return _transaction('transaction-1');
          },
          recordPayment: (payment) async {
            recorded.add(payment);
            if (recorded.length == 1) throw Exception('timeout');
          },
        );

    await expectLater(submit(), throwsException);
    await submit();

    expect(transactionCalls, 1);
    expect(recorded, hasLength(2));
    expect(recorded.map((item) => item.id).toSet(), {'stable-payment'});
    expect(recorded.map((item) => item.paidAt).toSet(), {paidAt});
    expect(
        recorded.map((item) => item.transactionId).toSet(), {'transaction-1'});
  });
}
