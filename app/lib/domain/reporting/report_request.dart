// Immutable configuration for one generated report. Pure Dart — no Flutter,
// Riverpod, database, or `pdf` imports. This is the single input the report
// engine is driven by; a snapshot is later collected for exactly one request.

/// The period a report covers.
///
/// Weekly / Monthly / Yearly resolve to the **complete calendar period**
/// containing the reference instant (see [ReportPeriodResolver]); [CustomPeriod]
/// carries explicit bounds. For a "period so far" report (e.g. this month up to
/// today), pass a [CustomPeriod] of `[periodStart, now]`.
sealed class ReportPeriod {
  const ReportPeriod();
}

class WeeklyPeriod extends ReportPeriod {
  const WeeklyPeriod();
}

class MonthlyPeriod extends ReportPeriod {
  const MonthlyPeriod();
}

class YearlyPeriod extends ReportPeriod {
  const YearlyPeriod();
}

class CustomPeriod extends ReportPeriod {
  const CustomPeriod({required this.from, required this.to});

  final DateTime from;
  final DateTime to;
}

/// Which accounts a report includes.
///
/// MVP supports **all accounts** or a **single account** only — the current
/// repository API (`_accountClause`, a single `String? accountId`) does not
/// support an arbitrary subset cleanly. A multi-account scope is deliberately
/// omitted until read-only `account_id IN (...)` query methods are added.
sealed class ReportScope {
  const ReportScope();
}

class AllAccountsScope extends ReportScope {
  const AllAccountsScope();
}

class SingleAccountScope extends ReportScope {
  const SingleAccountScope(this.accountId);

  final String accountId;
}

/// Include/exclude toggles for report content.
class ReportContentOptions {
  const ReportContentOptions({
    this.includeTransactionDetails = false,
    this.includeMerchantNames = true,
    this.includeAccountNames = true,
    this.includeBalances = true,
    this.includeInsights = true,
  });

  /// The full transaction appendix (off by default — it's the largest section).
  final bool includeTransactionDetails;
  final bool includeMerchantNames;
  final bool includeAccountNames;
  final bool includeBalances;
  final bool includeInsights;
}

/// A complete, hashable report configuration.
class ReportRequest {
  const ReportRequest({
    required this.period,
    this.scope = const AllAccountsScope(),
    this.languageCode = 'ar',
    this.content = const ReportContentOptions(),
    this.privacyMode = false,
  });

  final ReportPeriod period;
  final ReportScope scope;

  /// `'ar'` or `'en'`. Direction is derived from this ([isRtl]); a headless PDF
  /// renderer has no `BuildContext`, so text direction never comes from
  /// `Directionality.of(context)`.
  final String languageCode;
  final ReportContentOptions content;
  final bool privacyMode;

  bool get isRtl => languageCode == 'ar';

  /// The single account id when scoped to one account, else `null` (all
  /// accounts) — the exact shape the repository date-ranged methods expect.
  String? get accountId =>
      scope is SingleAccountScope ? (scope as SingleAccountScope).accountId : null;
}
