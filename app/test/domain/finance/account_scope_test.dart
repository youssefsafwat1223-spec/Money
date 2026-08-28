import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/finance/account_scope.dart';
import 'package:money_companion/domain/finance/budget_period.dart';
import 'package:money_companion/domain/finance/money.dart';

/// R-2 / OD-08 — one account-scope definition, consumed by every surface.
///
/// F-026: with an account selected, the Dashboard used
/// `budget.accountId == accountId` (excluding global budgets) while the Budgets
/// screen used `accountId == null || accountId == selected` (including them). So
/// the Home ring and the Budgets screen computed over different sets and
/// disagreed — while both called the same canonical `budgetSpent`. The shared
/// helper was never the problem; the INPUT SCOPE was.
BudgetEntity _budget({required String id, String? accountId}) => BudgetEntity(
      id: id,
      categoryId: 'cat-1',
      currency: 'SAR',
      amountMoney: Money.parse('100.00', 'SAR'),
      lastNotifiedSpentMoney: Money.zero('SAR'),
      period: BudgetPeriod.monthly,
      startDate: DateTime.utc(2026, 8, 1),
      isActive: true,
      lastNotifiedPeriodStart: DateTime.utc(2026, 8, 1),
      accountId: accountId,
    );

void main() {
  group('OD-08 — a global budget applies to every account', () {
    test('an account scope includes global budgets', () {
      const scope = AccountScope.account('acc-1');
      expect(scope.includesBudget(null), isTrue,
          reason: 'excluding it makes the Home ring under-count — that is F-026');
      expect(scope.includesBudget('acc-1'), isTrue);
      expect(scope.includesBudget('acc-2'), isFalse);
    });

    test('the all-accounts scope includes everything', () {
      const scope = AccountScope.all();
      expect(scope.includesBudget(null), isTrue);
      expect(scope.includesBudget('acc-1'), isTrue);
      expect(scope.includesBudget('acc-2'), isTrue);
    });
  });

  group('rows are scoped more strictly than budgets', () {
    test('an unassigned transaction belongs to no account', () {
      // A budget with no account applies to all accounts. A TRANSACTION with no
      // account is merely unassigned — counting it under every account would
      // double-count money.
      const scope = AccountScope.account('acc-1');
      expect(scope.includesRow(null), isFalse);
      expect(scope.includesRow('acc-1'), isTrue);
      expect(scope.includesRow('acc-2'), isFalse);
    });

    test('all-accounts includes unassigned rows', () {
      const scope = AccountScope.all();
      expect(scope.includesRow(null), isTrue);
      expect(scope.includesRow('acc-9'), isTrue);
    });
  });

  test('resolve() maps a null selection to all-accounts', () {
    expect(AccountScope.resolve(null).isAll, isTrue);
    expect(AccountScope.resolve('acc-1').accountId, 'acc-1');
  });

  group('budgetsInScope', () {
    final all = [
      _budget(id: 'global'),
      _budget(id: 'a1', accountId: 'acc-1'),
      _budget(id: 'a2', accountId: 'acc-2'),
    ];

    test('scoped: the account plus global, never another account', () {
      final ids = budgetsInScope(all, const AccountScope.account('acc-1'))
          .map((b) => b.id);
      expect(ids, ['global', 'a1']);
    });

    test('all-accounts: everything', () {
      expect(budgetsInScope(all, const AccountScope.all()).length, 3);
    });

    test('the F-026 divergence is now impossible to reproduce', () {
      // The two historical predicates, applied to the same input, produced
      // different sets. Both surfaces now route through this one function, so
      // the only way to diverge again is to bypass it — which is why callers are
      // documented not to re-filter.
      const scope = AccountScope.account('acc-1');
      final viaPolicy = budgetsInScope(all, scope).map((b) => b.id).toSet();
      final oldDashboardPredicate =
          all.where((b) => b.accountId == 'acc-1').map((b) => b.id).toSet();
      expect(viaPolicy.difference(oldDashboardPredicate), {'global'},
          reason: 'the dashboard used to drop exactly the global budgets');
    });
  });
}
