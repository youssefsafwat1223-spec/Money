import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/engine/parser/amount_candidate.dart';
import 'package:money_companion/engine/parser/capture_money.dart';

void main() {
  final now = DateTime.utc(2026, 8, 11);

  TransactionEntity transaction({
    Money? amountMoney,
    String currency = 'SAR',
    Money? foreignMoney,
    String? foreignCurrency,
  }) {
    return TransactionEntity(
      id: 'tx-1',
      amountMoney: amountMoney ?? Money.parse('12.34', currency),
      currency: currency,
      type: TransactionTypeEntity.payment,
      source: TransactionSourceEntity.bank,
      occurredAt: now,
      rawMessage: 'purchase',
      parseConfidence: 0.9,
      status: TransactionStatus.confirmed,
      createdAt: now,
      updatedAt: now,
      foreignMoney: foreignMoney,
      foreignCurrency: foreignCurrency,
    );
  }

  group('transaction foreign-money invariant', () {
    test('domestic transaction has neither foreign leg field', () {
      final tx = transaction();

      expect(tx.amountMoney, Money.parse('12.34', 'SAR'));
      expect(tx.foreignMoney, isNull);
      expect(tx.foreignCurrency, isNull);
    });

    test('priced FX transaction carries money and matching currency together',
        () {
      final tx = transaction(
        amountMoney: Money.parse('187.50', 'SAR'),
        foreignMoney: Money.parse('50.00', 'USD'),
        foreignCurrency: 'USD',
      );

      expect(tx.amountMoney, Money.parse('187.50', 'SAR'));
      expect(tx.foreignMoney, Money.parse('50.00', 'USD'));
      expect(tx.foreignCurrency, 'USD');
    });

    test('foreign-unpriced shape zeroes home leg and preserves original leg',
        () {
      final tx = transaction(
        amountMoney: Money.zero('SAR'),
        foreignMoney: Money.parse('99.00', 'USD'),
        foreignCurrency: 'USD',
      );

      expect(tx.amountMoney.isZero, isTrue);
      expect(tx.amountMoney.currency, 'SAR');
      expect(tx.foreignMoney, Money.parse('99.00', 'USD'));
      expect(tx.foreignCurrency, 'USD');
    });

    test('foreign money without a currency is rejected', () {
      expect(
        () => transaction(foreignMoney: Money.parse('50.00', 'USD')),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  test('candidate confidence cannot enter the capture-money conversion API',
      () {
    const candidate = AmountCandidate(
      value: 19.99,
      raw: '19.99',
      line: 'Paid SAR 19.99',
      kind: AmountCandidateKind.transactionAmount,
      score: 0.97,
    );

    final dynamic confidence = candidate.score;
    expect(confidence, isA<double>());
    expect(
      () => Function.apply(parseCaptureMoney, [confidence, 'SAR']),
      throwsA(isA<TypeError>()),
    );
    expect(
      parseCaptureMoney(candidate.raw, 'SAR'),
      Money.parse('19.99', 'SAR'),
    );
  });

  test('non-money copyWith preserves a JPY amount beyond 2^53 minor units',
      () {
    final original = transaction(
      amountMoney: Money(9007199254740993, 'JPY'),
      currency: 'JPY',
    );

    final edited = original.copyWith(note: 'edited without touching money');

    expect(edited.amountMoney, original.amountMoney);
    expect(edited.amountMoney.minorUnits, 9007199254740993);
  });
}
