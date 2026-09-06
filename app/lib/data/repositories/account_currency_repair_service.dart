import '../capture/proof_correction_log.dart';
import 'package:flutter/foundation.dart';

import '../../domain/entities/account_entity.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../../domain/repositories/account_repository.dart';
import '../../domain/repositories/transaction_repository.dart';

/// C-9 — the legacy per-currency account repair, as an EXPLICIT startup command.
///
/// This logic used to live inside `dashboardDataProvider`, so merely opening
/// Home created accounts and reassigned transactions — and because both
/// repositories enqueue sync intent, a read could produce durable financial
/// state and cloud writes. A read path must never do that (it is the same
/// architectural fault as F-020, where browsing an account rewrote the default).
///
/// It is a MIGRATION, not a live invariant: the capture path already creates an
/// account for a newly-seen currency at WRITE time
/// (`add_transaction_usecase.dart`, `_accountForCurrency`). What remains is
/// historical rows that predate that behaviour, which is exactly the kind of
/// one-off repair the bootstrap owns.
///
/// ## Idempotence
/// Idempotent by construction, not by a flag: it only creates a currency that
/// has no account, and only touches transactions whose `account_id` IS NULL.
/// A second run therefore finds nothing to do, performs no write, and so
/// enqueues no sync intent — which is what keeps repeated boots from queueing
/// duplicate outbox rows. [AccountCurrencyRepairResult.madeChanges] reports
/// whether this run actually mutated anything.
class AccountCurrencyRepairService {
  const AccountCurrencyRepairService({
    required AccountRepository accounts,
    required TransactionRepository transactions,
  })  : _accounts = accounts,
        _transactions = transactions;

  final AccountRepository _accounts;
  final TransactionRepository _transactions;

  /// Rows drained per keyset page — the null-account set shrinks to empty, so
  /// this never walks the whole ledger.
  static const int _pageSize = 500;

  static String _normalizeCurrency(String currency) =>
      currency.trim().toUpperCase();

  /// Runs the repair. [fallbackCurrency] seeds the very first account when the
  /// user has none at all (fresh install).
  Future<AccountCurrencyRepairResult> run({
    required String fallbackCurrency,
  }) async {
    var accounts = await _accounts.getAll();
    final byCurrency = <String, AccountEntity>{
      for (final account in accounts)
        _normalizeCurrency(account.currency): account,
    };
    var accountsCreated = 0;
    var transactionsReassigned = 0;

    Future<AccountEntity> createAccount(String currency) async {
      final now = DateTime.now().toUtc();
      final account = await _accounts.create(
        AccountEntity(
          id: '',
          name: 'حساب $currency',
          currency: currency,
          type: AccountType.bank,
          isDefault: accounts.isEmpty,
          sortOrder: accounts.length,
          createdAt: now,
          updatedAt: now,
        ),
      );
      accounts = [...accounts, account];
      byCurrency[currency] = account;
      accountsCreated++;
      return account;
    }

    final baseCurrency = _normalizeCurrency(fallbackCurrency);
    if (accounts.isEmpty && baseCurrency.isNotEmpty) {
      await createAccount(baseCurrency);
    }

    // The bounded distinct-currency set (all-time), not the whole ledger.
    for (final raw in await _transactions.distinctCurrencies()) {
      final currency = _normalizeCurrency(raw);
      if (currency.isNotEmpty && !byCurrency.containsKey(currency)) {
        await createAccount(currency);
      }
    }

    // Backfill ONLY null-account transactions via a bounded keyset drain. A row
    // whose currency has no account (e.g. blank currency) is left as-is.
    // Advancing past a processed page never re-fetches or skips: updated rows
    // leave the null-account set, un-updated ones fall before the cursor and are
    // retried on a later boot (best-effort).
    DateTime? beforeOccurredAt;
    String? beforeId;
    while (true) {
      final page = await _transactions.transactionsWithoutAccount(
        beforeOccurredAt: beforeOccurredAt,
        beforeId: beforeId,
        limit: _pageSize,
      );
      if (page.isEmpty) break;
      for (final tx in page) {
        final account = byCurrency[_normalizeCurrency(tx.currency)];
        if (account == null) continue;
        try {
          // PHASE 11: this runs at EVERY BOOT and backfills orphaned rows with
          // no user involved. Declared as a system repair so it cannot append
          // false `corrected_financial` events to the Proof correctness log.
          await _transactions.updateAccount(
            origin: ProofEditOrigin.systemRepair,
            transactionId: tx.id,
            accountId: account.id,
          );
          transactionsReassigned++;
        } on RepoException catch (e) {
          // Background reconciliation with no UI: log and continue rather than
          // failing the whole repair because of one row.
          if (kDebugMode) {
            debugPrint(
              '[AccountCurrencyRepair] skipped a row: ${e.runtimeType}',
            );
          }
        }
      }
      if (page.length < _pageSize) break;
      final last = page.last;
      beforeOccurredAt = last.occurredAt;
      beforeId = last.id;
    }

    return AccountCurrencyRepairResult(
      accountsCreated: accountsCreated,
      transactionsReassigned: transactionsReassigned,
    );
  }
}

/// What a single [AccountCurrencyRepairService.run] actually changed.
@immutable
class AccountCurrencyRepairResult {
  const AccountCurrencyRepairResult({
    required this.accountsCreated,
    required this.transactionsReassigned,
  });

  final int accountsCreated;
  final int transactionsReassigned;

  /// False on every run after the data is already repaired — the signal that
  /// no write, and therefore no sync intent, was produced.
  bool get madeChanges => accountsCreated > 0 || transactionsReassigned > 0;

  @override
  String toString() => 'AccountCurrencyRepairResult('
      'accountsCreated: $accountsCreated, '
      'transactionsReassigned: $transactionsReassigned)';
}
