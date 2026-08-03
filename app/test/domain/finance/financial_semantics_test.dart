import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/utils/riyadh_time.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/financial_period.dart';
import 'package:money_companion/domain/finance/financial_semantics.dart';
import 'package:money_companion/domain/finance/money_format.dart';

// Phase 4 Batch 1 — the canonical financial-semantics contract.

void main() {
  group('type matrix', () {
    test('payment and withdrawal are net expense (sign +1), not income', () {
      for (final t in [
        TransactionTypeEntity.payment,
        TransactionTypeEntity.withdrawal,
      ]) {
        final s = semanticsFor(t);
        expect(s.contributesToExpense, isTrue);
        expect(s.contributesToIncome, isFalse);
        expect(s.expenseSign, 1);
        expect(s.affectsBudget, isTrue);
        expect(s.affectsCategorySpending, isTrue);
      }
    });

    test('refund nets against expense (sign −1) and is NEVER income', () {
      final s = semanticsFor(TransactionTypeEntity.refund);
      expect(s.expenseSign, -1);
      expect(s.contributesToExpense, isTrue);
      expect(s.contributesToIncome, isFalse, reason: 'refund is not income');
      expect(s.grossInflow, isTrue, reason: 'gross-flow surfaces may show it in');
      expect(s.affectsBudget, isTrue);
    });

    test('income is income only, never expense', () {
      final s = semanticsFor(TransactionTypeEntity.income);
      expect(s.contributesToIncome, isTrue);
      expect(s.contributesToExpense, isFalse);
      expect(s.affectsBudget, isFalse);
    });

    test('transfer and unknown are excluded from net income AND expense', () {
      for (final t in [
        TransactionTypeEntity.transfer,
        TransactionTypeEntity.unknown,
      ]) {
        final s = semanticsFor(t);
        expect(s.excludedFromNetSpend, isTrue);
        expect(s.affectsBudget, isFalse);
        expect(s.affectsCategorySpending, isFalse);
      }
      // Transfer still moves account cash; unknown moves nothing.
      expect(semanticsFor(TransactionTypeEntity.transfer).affectsAccountCashFlow,
          isTrue);
      expect(semanticsFor(TransactionTypeEntity.unknown).affectsAccountCashFlow,
          isFalse);
    });
  });

  group('status treatment', () {
    test('only confirmed counts; pending is pending-only; ignored excluded', () {
      expect(statusTreatment(TransactionStatus.confirmed),
          FinancialStatusTreatment.counted);
      expect(statusTreatment(TransactionStatus.pending),
          FinancialStatusTreatment.pendingOnly);
      expect(statusTreatment(TransactionStatus.ignored),
          FinancialStatusTreatment.excluded);
    });
  });

  group('canonical SQL fragments', () {
    test('net-expense signed amount subtracts refunds, adds payment/withdrawal',
        () {
      final sql = FinancialSql.netExpenseSignedAmount(alias: 't');
      expect(sql, contains("t.type = 'refund' THEN -t.amount"));
      expect(sql, contains("t.type IN ('payment', 'withdrawal') THEN t.amount"));
      expect(sql, contains('ELSE 0'));
    });

    test('confirmed predicate + type filters', () {
      expect(FinancialSql.confirmedPredicate(), "status = 'confirmed'");
      expect(FinancialSql.netExpenseTypePredicate(),
          "type IN ('payment', 'withdrawal', 'refund')");
      expect(FinancialSql.incomeTypePredicate(), "type = 'income'");
    });
  });

  group('canonical period (half-open, Saturday week)', () {
    test('day is [startOfDay, nextDay)', () {
      final r = FinancialPeriod.day(DateTime(2026, 7, 14, 23, 30));
      expect(r.from, DateTime(2026, 7, 14));
      expect(r.to, DateTime(2026, 7, 15));
      expect(r.contains(DateTime(2026, 7, 14, 0, 0)), isTrue);
      expect(r.contains(DateTime(2026, 7, 15, 0, 0)), isFalse,
          reason: 'toExclusive belongs to the next day');
    });

    test('the week starts on Saturday for every weekday input', () {
      // 2026-08-01 is a Saturday.
      for (var i = 0; i < 7; i++) {
        final d = DateTime(2026, 8, 1).add(Duration(days: i));
        expect(RiyadhTime.startOfWeek(d), DateTime(2026, 8, 1),
            reason: '${d.weekday} should map to Sat 2026-08-01');
      }
      // The following Saturday starts a new week.
      expect(RiyadhTime.startOfWeek(DateTime(2026, 8, 8)), DateTime(2026, 8, 8));
      final w = FinancialPeriod.week(DateTime(2026, 8, 4));
      expect(w.from, DateTime(2026, 8, 1));
      expect(w.to, DateTime(2026, 8, 8));
    });

    test('year is [Jan 1, next Jan 1)', () {
      final r = FinancialPeriod.year(DateTime(2026, 7, 14));
      expect(r.from, DateTime(2026));
      expect(r.to, DateTime(2027));
    });
  });

  group('currency exponents (presentation only)', () {
    test('digits: 3-decimal / 2-decimal / 0-decimal', () {
      expect(currencyDecimalDigits('KWD'), 3);
      expect(currencyDecimalDigits('BHD'), 3);
      expect(currencyDecimalDigits('SAR'), 2);
      expect(currencyDecimalDigits('USD'), 2);
      expect(currencyDecimalDigits('JPY'), 0);
      expect(currencyDecimalDigits('unknown'), 2, reason: 'default 2');
    });

    test('formats with the currency exponent, not a hardcoded 2', () {
      expect(formatMoneyAmount(1234.5, 'KWD'), '1,234.500');
      expect(formatMoneyAmount(1234.5, 'SAR'), '1,234.50');
      expect(formatMoneyAmount(1234.5, 'JPY'), '1,235');
    });
  });
}
