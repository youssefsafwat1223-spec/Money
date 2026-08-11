import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/money_codec.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/entities/plan_entity.dart';
import 'package:money_companion/domain/entities/suspected_duplicate_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';

const _v30Codec = MoneyCodec(MoneyStorageMode.v30Minor);
final _adversarialMoney = Money((1 << 53) + 7, 'JPY');
final _now = DateTime.utc(2026, 8, 11);

void _expectIdentityAndV30RoundTrip(Money before, Money after) {
  expect(after.minorUnits, before.minorUnits);
  expect(after.currency, before.currency);

  final minor = _v30Codec.toMinor(after);
  expect(minor, after.minorUnits);
  expect(
    _v30Codec.read(minor: minor, currency: after.currency),
    after,
  );
}

void main() {
  group('non-money RMW preserves >2^53 minor-unit identity', () {
    test('TransactionEntity', () {
      final entity = TransactionEntity(
        id: 'transaction-1',
        amountMoney: _adversarialMoney,
        currency: 'JPY',
        type: TransactionTypeEntity.payment,
        source: TransactionSourceEntity.imported,
        occurredAt: _now,
        rawMessage: 'fixture',
        parseConfidence: 1,
        status: TransactionStatus.confirmed,
        createdAt: _now,
        updatedAt: _now,
      );

      final edited = entity.copyWith(note: 'non-money edit');

      _expectIdentityAndV30RoundTrip(entity.amountMoney, edited.amountMoney);
    });

    test('AccountEntity', () {
      final entity = AccountEntity(
        id: 'account-1',
        name: 'Before',
        currency: 'JPY',
        type: AccountType.bank,
        initialBalanceMoney: _adversarialMoney,
        isDefault: false,
        sortOrder: 0,
        createdAt: _now,
        updatedAt: _now,
      );

      final edited = entity.copyWith(name: 'After');

      _expectIdentityAndV30RoundTrip(
        entity.initialBalanceMoney!,
        edited.initialBalanceMoney!,
      );
    });

    test('BillEntity', () {
      final entity = BillEntity(
        id: 'bill-1',
        name: 'Before',
        amountMoney: _adversarialMoney,
        currency: 'JPY',
        type: BillType.subscription,
        frequency: BillFrequency.monthly,
        nextDueDate: _now,
        reminderOn: true,
        isConfirmed: true,
        createdAt: _now,
      );

      final edited = entity.copyWith(status: BillStatus.paused);

      _expectIdentityAndV30RoundTrip(entity.amountMoney, edited.amountMoney);
    });

    test('BillPaymentEntity', () {
      final entity = BillPaymentEntity(
        id: 'payment-1',
        billId: 'bill-1',
        amountMoney: _adversarialMoney,
        currency: 'JPY',
        periodStart: _now,
        periodEnd: _now.add(const Duration(days: 30)),
        paidAt: _now,
      );

      final edited = entity.copyWith(transactionId: 'transaction-1');

      _expectIdentityAndV30RoundTrip(entity.amountMoney, edited.amountMoney);
    });

    test('PlanEntity', () {
      final entity = PlanEntity(
        id: 'plan-1',
        name: 'Before',
        budgetAmountMoney: _adversarialMoney,
        currency: 'JPY',
        startDate: _now,
        endDate: _now.add(const Duration(days: 30)),
        accountIds: const [],
        cardLast4s: const [],
        status: PlanStatus.active,
        createdAt: _now,
      );

      final edited = entity.copyWith(name: 'After');

      _expectIdentityAndV30RoundTrip(
        entity.budgetAmountMoney,
        edited.budgetAmountMoney,
      );
    });

    test('SuspectedDuplicateEntity', () {
      final entity = SuspectedDuplicateEntity(
        id: 'duplicate-1',
        rawMessage: 'fixture',
        existingTransactionId: 'transaction-1',
        amountMoney: _adversarialMoney,
        currency: 'JPY',
        occurredAt: _now,
        createdAt: _now,
      );

      final edited = entity.copyWith(rawMerchant: 'After');

      _expectIdentityAndV30RoundTrip(entity.amountMoney, edited.amountMoney);
    });
  });
}
