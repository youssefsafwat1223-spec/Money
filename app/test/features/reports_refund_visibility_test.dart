import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/finance/money.dart';

/// UX-022 — refunds were netted invisibly.
///
/// `financial_semantics.dart` defines one documented contract —
/// `net expense = Σpayment + Σwithdrawal − Σrefund` — and it is correct. The
/// defect was that nothing on screen could explain it. The QA's real case:
///
/// | row | type | amount |
/// |---|---|---|
/// | مستشفى الدكتور سليمان | expense | 420.00 |
/// | نون | expense | 1,899.00 |
/// | نون «استرجاع طلب» | **refund** | **199.00** |
///
/// Reports displayed **2,120.00** — arithmetically right, and unexplainable:
/// no line accounted for the 199.
///
/// The constraint was explicit: *"do NOT change `net expense = payments +
/// withdrawals − refunds`. The contract is correct and centrally documented;
/// this is a rendering gap only."*
void main() {
  group('the contract is reported, not changed', () {
    test('gross − refunds = net, exactly', () {
      // The QA's case in minor units. `grossExpense` is DERIVED from the two
      // queried figures rather than queried separately, so the three numbers on
      // screen cannot disagree with each other.
      final net = Money(212000, 'SAR'); // 2,120.00
      final refunds = Money(19900, 'SAR'); // 199.00
      final gross = net + refunds;

      expect(gross, Money(231900, 'SAR')); // 2,319.00 = 420 + 1,899
      expect(gross - refunds, net);
    });

    test('a period with no refund is unchanged', () {
      final net = Money(212000, 'SAR');
      final refunds = Money.zero('SAR');
      expect(net + refunds, net,
          reason: 'the breakdown must not alter a period it does not apply to');
    });
  });

  group('the repository reports an input without altering the aggregate', () {
    final repo = File(
      'lib/data/repositories/drift_transaction_repository.dart',
    ).readAsStringSync();

    test('the netting SQL is untouched', () {
      // The signed CASE is the contract. If this disappears, the fix has
      // changed the maths instead of explaining it.
      expect(repo, contains("CASE WHEN \${prefix}type = 'refund' "),
          reason: 'the documented netting must remain the netting');
    });

    test('refundTotalBetween sums refunds as a positive magnitude', () {
      expect(repo, contains('refundTotalBetween'));
      final i = repo.indexOf('Future<Money> refundTotalBetween');
      final body = repo.substring(i, i + 900);
      expect(body, contains("type = 'refund'"));
      expect(body, contains('SUM(amount_minor)'),
          reason: 'exact minor units, never a REAL cast');
      expect(body.contains('-amount_minor'), isFalse,
          reason: 'this reports the magnitude; the sign belongs to the contract');
    });

    test('it uses the same window, scope and exclusions as the total', () {
      // If the two queries could disagree about scope, the displayed
      // `gross − refunds = net` would stop reconciling — which is worse than
      // the silent netting it replaces.
      final i = repo.indexOf('Future<Money> refundTotalBetween');
      final body = repo.substring(i, i + 900);
      expect(body, contains('_financialAggregateSql'));
      expect(body, contains('occurred_at >= ? AND occurred_at < ?'));
      expect(body, contains('_accountClause(accountId)'));
      expect(body, contains('UPPER(currency) = ?'));
    });
  });

  group('the screen states the three figures', () {
    final screen =
        File('lib/features/reports/reports_screen.dart').readAsStringSync();

    test('gross, refunds and net are each labelled', () {
      expect(screen, contains('إجمالي المصروفات'));
      expect(screen, contains('المرتجعات'));
      expect(screen, contains('الصافي'));
    });

    test('the breakdown appears only when a refund exists', () {
      expect(screen, contains('section.hasRefunds'),
          reason: 'a period without refunds keeps its single clean headline');
    });

    test('the headline says NET when refunds are present', () {
      expect(screen, contains('صافي مصروف الفترة'),
          reason: 'calling a netted figure «مصروف» is what made it misleading');
    });

    test('the figures render through MoneyText, not a double', () {
      expect(screen, contains('MoneyText(amount'),
          reason: 'R-8 — three figures that must reconcile cannot be rounded '
              'independently, which is the UX-001 failure in another place');
    });
  });
}
