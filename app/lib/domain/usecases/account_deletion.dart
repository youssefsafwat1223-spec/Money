import '../entities/account_entity.dart';

/// MALI-016 — dependency-aware account deletion.
///
/// Deleting an account must not orphan the rows that point at it. Each relation
/// has a different safe outcome (see [AccountDeletionService]); these models
/// carry the read-only impact plan the UI shows before confirming, the user's
/// resolved decisions, and the structured result explaining what happened.

/// A single goal/subscription that needs a user decision (reassign vs archive)
/// when its owning account is deleted.
class AccountDependent {
  const AccountDependent({
    required this.id,
    required this.name,
    required this.currency,
    this.amount,
  });

  final String id;
  final String name;

  /// Currency the entity's amounts are denominated in — used to gate
  /// reassignment to a currency-compatible successor account.
  final String currency;

  /// Goal `savedAmount` or subscription amount, for the summary UI.
  final double? amount;
}

/// Read-only plan of what deleting [accountId] will affect. Computed without
/// mutating anything so the confirmation UI can show a dependency summary.
class AccountDeletionImpact {
  const AccountDeletionImpact({
    required this.accountId,
    required this.accountCurrency,
    required this.transactionsToDetach,
    required this.cardsToArchive,
    required this.budgetsToArchive,
    required this.goals,
    required this.subscriptions,
    required this.successorCandidates,
  });

  final String accountId;
  final String accountCurrency;
  final int transactionsToDetach;
  final int cardsToArchive;
  final int budgetsToArchive;

  /// Active goals on the account — each needs a reassign-or-archive decision.
  final List<AccountDependent> goals;

  /// Active subscriptions on the account — each REQUIRES an explicit
  /// reassign-or-archive decision (an active recurring obligation is never
  /// tombstoned silently, nor left to currency-fallback).
  final List<AccountDependent> subscriptions;

  /// Other active accounts that can receive reassigned goals/subscriptions.
  final List<AccountEntity> successorCandidates;

  /// Compatible successors for a dependent of [currency].
  List<AccountEntity> compatibleSuccessors(String currency) =>
      successorCandidates
          .where((a) => a.currency == currency)
          .toList(growable: false);

  bool get requiresDecision => goals.isNotEmpty || subscriptions.isNotEmpty;
}

/// A per-dependent decision: reassign to [successorAccountId], or archive when
/// [successorAccountId] is null.
class AccountReassignmentChoice {
  const AccountReassignmentChoice.reassign(String this.successorAccountId);
  const AccountReassignmentChoice.archive() : successorAccountId = null;

  final String? successorAccountId;
  bool get isArchive => successorAccountId == null;
}

/// The user's resolved decisions for deleting [accountId]. Goals absent from
/// [goalChoices] default to archive; every active subscription MUST have a
/// choice or the deletion is blocked (conservative fallback).
class AccountDeletionRequest {
  const AccountDeletionRequest({
    required this.accountId,
    this.goalChoices = const {},
    this.subscriptionChoices = const {},
  });

  final String accountId;
  final Map<String, AccountReassignmentChoice> goalChoices;
  final Map<String, AccountReassignmentChoice> subscriptionChoices;
}

/// Structured outcome so the UI can explain exactly what happened.
class AccountDeletionResult {
  const AccountDeletionResult({
    required this.transactionsDetached,
    required this.cardsArchived,
    required this.budgetsArchived,
    required this.goalsReassigned,
    required this.goalsArchived,
    required this.subscriptionsReassigned,
    required this.subscriptionsArchived,
    required this.successorDefaultAccountId,
  });

  final int transactionsDetached;
  final int cardsArchived;
  final int budgetsArchived;
  final int goalsReassigned;
  final int goalsArchived;
  final int subscriptionsReassigned;
  final int subscriptionsArchived;
  final String? successorDefaultAccountId;
}

/// Thrown before any mutation when a deletion can't proceed safely: an active
/// subscription lacks a decision (conservative fallback), a chosen successor is
/// missing, or a requested reassignment is currency-incompatible. Deletion is
/// atomic, so nothing is changed when this is raised.
class AccountDeletionBlocked implements Exception {
  const AccountDeletionBlocked(
    this.reason, {
    this.unresolvedSubscriptionIds = const [],
    this.currencyIncompatibleIds = const [],
  });

  final String reason;
  final List<String> unresolvedSubscriptionIds;
  final List<String> currencyIncompatibleIds;

  @override
  String toString() => 'AccountDeletionBlocked: $reason';
}
