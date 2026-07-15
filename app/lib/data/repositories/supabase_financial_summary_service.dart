import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/backend/supabase_config.dart';
import '../../domain/entities/category_spend.dart';
import '../../domain/errors/repo_exceptions.dart';

class PeriodFinancialSummary {
  const PeriodFinancialSummary({
    required this.expense,
    required this.income,
    required this.refund,
    required this.transfer,
  });

  final double expense;
  final double income;
  final double refund;
  final double transfer;
}

class AccountBalanceSummary {
  const AccountBalanceSummary({
    required this.accountId,
    required this.currency,
    required this.currentBalance,
    required this.latestBalanceAfter,
  });

  final String accountId;
  final String currency;
  final double? currentBalance;
  final double? latestBalanceAfter;

  double? get effectiveBalance => latestBalanceAfter ?? currentBalance;
}

class BudgetSpentSummary {
  const BudgetSpentSummary({required this.budgetId, required this.spent});

  final String budgetId;
  final double spent;
}

/// Thin authenticated client for Phase 3 summary RPCs. Widgets never use this
/// directly; providers choose it only behind dashboard_supabase_summary.
class SupabaseFinancialSummaryService {
  SupabaseFinancialSummaryService({
    SupabaseClient Function()? getClient,
    Future<String?> Function()? getAuthUserId,
  })  : _getClient = getClient ?? (() => Supabase.instance.client),
        _getAuthUserId = getAuthUserId ?? _defaultUserId;

  final SupabaseClient Function() _getClient;
  final Future<String?> Function() _getAuthUserId;

  static Future<String?> _defaultUserId() async {
    if (!SupabaseConfig.isConfigured) return null;
    return Supabase.instance.client.auth.currentUser?.id;
  }

  Future<void> _requireAuth() async {
    if (await _getAuthUserId() == null) throw const AuthRepoException();
  }

  Future<PeriodFinancialSummary> periodSummary({
    required DateTime from,
    required DateTime to,
    String? accountId,
  }) async {
    await _requireAuth();
    try {
      final response = await _getClient().rpc(
        'monthly_financial_summary',
        params: {
          'p_from_inclusive': from.toUtc().toIso8601String(),
          'p_to_exclusive': to.toUtc().toIso8601String(),
          'p_account_id': accountId,
        },
      );
      final row = Map<String, dynamic>.from(response as Map);
      return PeriodFinancialSummary(
        expense: (row['expense'] as num?)?.toDouble() ?? 0,
        income: (row['income'] as num?)?.toDouble() ?? 0,
        refund: (row['refund'] as num?)?.toDouble() ?? 0,
        transfer: (row['transfer'] as num?)?.toDouble() ?? 0,
      );
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }

  Future<AccountBalanceSummary?> accountBalance(String accountId) async {
    await _requireAuth();
    try {
      final response = await _getClient().rpc(
        'account_balance_summary',
        params: {'p_account_id': accountId},
      );
      if (response == null) return null;
      final row = Map<String, dynamic>.from(response as Map);
      final id = row['account_id'] as String?;
      final currency = row['currency'] as String?;
      if (id == null || currency == null) return null;
      return AccountBalanceSummary(
        accountId: id,
        currency: currency,
        currentBalance: (row['current_balance'] as num?)?.toDouble(),
        latestBalanceAfter: (row['latest_balance_after'] as num?)?.toDouble(),
      );
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }

  Future<List<CategorySpend>> categorySummary({
    required DateTime from,
    required DateTime to,
    String? accountId,
  }) async {
    await _requireAuth();
    try {
      final response = await _getClient().rpc(
        'category_spending_summary',
        params: {
          'p_from_inclusive': from.toUtc().toIso8601String(),
          'p_to_exclusive': to.toUtc().toIso8601String(),
          'p_account_id': accountId,
        },
      );
      return (response as List)
          .map((raw) => Map<String, dynamic>.from(raw as Map))
          .map(
            (row) => CategorySpend(
              categoryId: row['category_id'] as String,
              total: (row['total'] as num).toDouble(),
              count: (row['transaction_count'] as num).toInt(),
            ),
          )
          .toList(growable: false);
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }

  Future<Map<String, double>> budgetProgressSummary({
    required DateTime from,
    required DateTime to,
  }) async {
    await _requireAuth();
    try {
      final response = await _getClient().rpc(
        'budget_progress_summary',
        params: {
          'p_from_inclusive': from.toUtc().toIso8601String(),
          'p_to_exclusive': to.toUtc().toIso8601String(),
        },
      );
      return {
        for (final raw in response as List)
          (raw as Map)['budget_id'] as String:
              ((raw)['spent'] as num?)?.toDouble() ?? 0,
      };
    } catch (error) {
      throw mapSupabaseError(error);
    }
  }
}
