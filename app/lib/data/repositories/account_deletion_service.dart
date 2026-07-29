import 'package:drift/drift.dart';

import '../../domain/entities/bill_entity.dart';
import '../../domain/repositories/account_repository.dart';
import '../../domain/repositories/bill_repository.dart';
import '../../domain/repositories/budget_repository.dart';
import '../../domain/repositories/card_repository.dart';
import '../../domain/repositories/goal_repository.dart';
import '../../domain/usecases/account_deletion.dart';
import '../db/app_database.dart';

/// MALI-016 — the single authoritative, dependency-aware account-deletion path.
///
/// Deleting an account has no DB-level cascade (the child tables reference the
/// account by a plain nullable `account_id`, not an FK), and a NULL account_id
/// means something different for each: budgets NULL = all-accounts, goals NULL =
/// hidden, subscriptions NULL = currency-fallback, cards NULL = unassigned. So a
/// blanket detach silently corrupts data. This service applies a per-relation
/// policy atomically and returns a structured result:
///
/// - transactions  → detach to NULL (history preserved; unchanged behavior)
/// - cards         → archive (soft-delete; a physical card is never silently
///                    reassigned)
/// - budgets       → archive (a scoped budget is meaningless without its
///                    account; never NULL-ed into an all-accounts budget)
/// - goals         → reassign to a user-chosen currency-compatible successor,
///                    else archive (progress preserved either way; never NULL)
/// - subscriptions → reassign to a user-chosen currency-compatible successor,
///                    else archive. An active subscription is NEVER handled
///                    without an explicit decision (conservative fallback:
///                    deletion is blocked until the user chooses).
///
/// All child mutations reuse the child repositories, so their existing
/// soft-delete + outbox-enqueue behavior mirrors every change to the server.
class FinancialAccountDeletionService {
  FinancialAccountDeletionService({
    required AppDatabase db,
    required AccountRepository accounts,
    required CardRepository cards,
    required BudgetRepository budgets,
    required GoalRepository goals,
    required BillRepository bills,
  })  : _db = db,
        _accounts = accounts,
        _cards = cards,
        _budgets = budgets,
        _goals = goals,
        _bills = bills;

  final AppDatabase _db;
  final AccountRepository _accounts;
  final CardRepository _cards;
  final BudgetRepository _budgets;
  final GoalRepository _goals;
  final BillRepository _bills;

  Future<int> _transactionCount(String accountId) async {
    final row = await _db.customSelect(
      'SELECT COUNT(*) AS n FROM transactions WHERE account_id = ?;',
      variables: [Variable.withString(accountId)],
    ).getSingle();
    return row.read<int>('n');
  }

  /// Read-only impact plan for the confirmation UI — mutates nothing.
  Future<AccountDeletionImpact> plan(String accountId) async {
    final account = await _accounts.getById(accountId);
    if (account == null) {
      return AccountDeletionImpact(
        accountId: accountId,
        accountCurrency: '',
        transactionsToDetach: 0,
        cardsToArchive: 0,
        budgetsToArchive: 0,
        goals: const [],
        subscriptions: const [],
        successorCandidates: const [],
      );
    }
    final cards = await _cards.getByAccount(accountId);
    final budgets = (await _budgets.getAll())
        .where((b) => b.accountId == accountId)
        .toList(growable: false);
    final goals = (await _goals.getAll())
        .where((g) => g.accountId == accountId && g.status == 'active')
        .toList(growable: false);
    final subs = (await _bills.getAll())
        .where((s) => s.accountId == accountId && s.status == BillStatus.active)
        .toList(growable: false);
    final successors = (await _accounts.getAll())
        .where((a) => a.id != accountId)
        .toList(growable: false);
    return AccountDeletionImpact(
      accountId: accountId,
      accountCurrency: account.currency,
      transactionsToDetach: await _transactionCount(accountId),
      cardsToArchive: cards.length,
      budgetsToArchive: budgets.length,
      goals: [
        for (final g in goals)
          AccountDependent(
            id: g.id,
            name: g.name,
            currency: account.currency, // goals inherit their account currency
            amount: g.savedAmount,
          ),
      ],
      subscriptions: [
        for (final s in subs)
          AccountDependent(
            id: s.id,
            name: s.name,
            currency: s.currency,
            amount: s.amount,
          ),
      ],
      successorCandidates: successors,
    );
  }

  /// Executes the resolved deletion atomically. Validates every decision BEFORE
  /// mutating, so a bad request throws [AccountDeletionBlocked] and changes
  /// nothing. Throws [StateError] when trying to delete the last account.
  Future<AccountDeletionResult> execute(AccountDeletionRequest request) async {
    final account = await _accounts.getById(request.accountId);
    if (account == null) {
      throw const AccountDeletionBlocked('account not found');
    }
    final allAccounts = await _accounts.getAll();
    if (allAccounts.length <= 1) {
      throw StateError('Cannot delete the last account.');
    }
    final successorsById = {
      for (final a in allAccounts)
        if (a.id != request.accountId) a.id: a,
    };

    final cards = await _cards.getByAccount(request.accountId);
    final budgets = (await _budgets.getAll())
        .where((b) => b.accountId == request.accountId)
        .toList(growable: false);
    final goals = (await _goals.getAll())
        .where((g) => g.accountId == request.accountId && g.status == 'active')
        .toList(growable: false);
    final subs = (await _bills.getAll())
        .where((s) =>
            s.accountId == request.accountId && s.status == BillStatus.active)
        .toList(growable: false);

    // ── Validate all decisions up front (fail closed, before any mutation) ──
    final unresolvedSubs = <String>[];
    final incompatible = <String>[];
    for (final s in subs) {
      final choice = request.subscriptionChoices[s.id];
      if (choice == null) {
        unresolvedSubs.add(s.id); // conservative fallback: must decide
        continue;
      }
      if (!choice.isArchive) {
        final target = successorsById[choice.successorAccountId];
        if (target == null || target.currency != s.currency) {
          incompatible.add(s.id);
        }
      }
    }
    for (final g in goals) {
      final choice = request.goalChoices[g.id];
      if (choice != null && !choice.isArchive) {
        final target = successorsById[choice.successorAccountId];
        if (target == null || target.currency != account.currency) {
          incompatible.add(g.id);
        }
      }
    }
    if (unresolvedSubs.isNotEmpty) {
      throw AccountDeletionBlocked(
        'active subscriptions require a reassign-or-archive decision',
        unresolvedSubscriptionIds: unresolvedSubs,
      );
    }
    if (incompatible.isNotEmpty) {
      throw AccountDeletionBlocked(
        'a reassignment target is missing or currency-incompatible',
        currencyIncompatibleIds: incompatible,
      );
    }

    final txCount = await _transactionCount(request.accountId);
    var goalsReassigned = 0, goalsArchived = 0;
    var subsReassigned = 0, subsArchived = 0;

    await _db.transaction(() async {
      for (final c in cards) {
        await _cards.delete(c.id); // archive; enqueues while account_id set
      }
      for (final b in budgets) {
        await _budgets.delete(b.id); // archive
      }
      for (final g in goals) {
        final choice = request.goalChoices[g.id];
        if (choice != null && !choice.isArchive) {
          await _goals.save(g.copyWith(accountId: choice.successorAccountId));
          goalsReassigned++;
        } else {
          await _goals.delete(g.id); // archive (deleted_at + status='archived')
          goalsArchived++;
        }
      }
      for (final s in subs) {
        final choice = request.subscriptionChoices[s.id]!; // validated present
        if (!choice.isArchive) {
          await _bills.save(s.copyWith(accountId: choice.successorAccountId));
          subsReassigned++;
        } else {
          await _bills
              .delete(s.id); // archive (deleted_at + status='cancelled')
          subsArchived++;
        }
      }
      // Detach transactions + tombstone the account + promote successor default
      // (reuses MALI-015 logic). Runs last so a child failure rolls back all.
      await _accounts.delete(request.accountId);
    });

    final successorDefault = await _accounts.getDefault();
    return AccountDeletionResult(
      transactionsDetached: txCount,
      cardsArchived: cards.length,
      budgetsArchived: budgets.length,
      goalsReassigned: goalsReassigned,
      goalsArchived: goalsArchived,
      subscriptionsReassigned: subsReassigned,
      subscriptionsArchived: subsArchived,
      successorDefaultAccountId: successorDefault?.id,
    );
  }
}
