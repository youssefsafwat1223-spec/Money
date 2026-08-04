import '../../../domain/entities/report_models.dart';
import '../../../domain/entities/transaction_entity.dart';
import '../../../domain/reporting/metrics/category_aggregator.dart';
import '../../../domain/reporting/metrics/comparison_calculator.dart';
import '../../../domain/reporting/metrics/report_metrics_calculator.dart';
import '../../../domain/reporting/insights/insight_engine.dart';
import '../../../domain/reporting/report_data_snapshot.dart';
import '../../../domain/reporting/report_metrics.dart';
import '../../../domain/reporting/report_request.dart';
import 'report_l10n.dart';
import 'report_money_formatter.dart';
import 'report_view_model.dart';

/// Turns an immutable [ReportDataSnapshot] into a render-ready [ReportViewModel]
/// using the pure calculators. Runs on the main isolate (it may format via
/// `Currency`/`intl`); the output is plain data handed to the pure renderer.
class ReportComposer {
  const ReportComposer();

  static const int _otherColor = 0xFF9E9E9E; // database_seed default grey.
  static const int _incomeColor = 0xFF16A34A;
  static const int _expenseColor = 0xFFDC2626;

  ReportViewModel compose(ReportDataSnapshot snapshot) {
    final request = snapshot.request;
    final lang = request.languageCode;
    final str = ReportStrings.of(lang);
    final fmt = ReportMoneyFormatter(lang, masked: request.privacyMode);

    const metrics = ReportMetricsCalculator();
    const comparisonCalc = ComparisonCalculator();
    const aggregator = CategoryAggregator();

    final primary = _primaryCurrency(snapshot);
    // MALI-063n: the donut/slices are scoped to the primary currency's own
    // category breakdown + total, never the cross-currency sum.
    final primaryExpense = _expense(snapshot.currencyTotals, primary);
    final current = metrics.computeCashFlow(
      income: _income(snapshot.currencyTotals, primary),
      expense: primaryExpense,
    );
    final previous = metrics.computeCashFlow(
      income: _income(snapshot.previousCurrencyTotals, primary),
      expense: _expense(snapshot.previousCurrencyTotals, primary),
    );
    final comparison = comparisonCalc.compare(current, previous);

    final periodLabel = _periodLabel(snapshot, str);

    final slices = aggregator.aggregate(
      breakdown: snapshot.categoryBreakdownByCurrency[primary] ?? const [],
      labelFor: (id) => _categoryLabel(snapshot, lang, id),
      totalExpense: primaryExpense,
      otherLabel: str.other,
    );
    final trend = _trend(snapshot, fmt, str, primary);

    return ReportViewModel(
      rtl: request.isRtl,
      strings: str,
      periodLabel: periodLabel,
      cover: ReportCoverVM(
        title: str.reportTitle,
        periodLabel: periodLabel,
        scopeLabel: _scopeLabel(snapshot, str),
        currencyLabel: primary,
        languageLabel: str.languageName,
        generatedLabel: _dateLabel(snapshot.capturedAt, str),
      ),
      summary: ReportSummaryVM(
        tiles: <TileVM>[
          TileVM(str.income, fmt.money(current.income, primary),
              colorArgb: _incomeColor),
          TileVM(str.expense, fmt.money(current.expense, primary),
              colorArgb: _expenseColor),
          TileVM(str.net,
              fmt.signedMoney(current.net, primary, isExpense: current.net < 0)),
        ],
        verdict: _verdict(str, fmt, comparison),
      ),
      cashFlow: <CashFlowRowVM>[
        for (final total in snapshot.currencyTotals)
          _cashRow(fmt, str, metrics, total),
      ],
      comparison: <ComparisonRowVM>[
        _cmpRow(str.income, fmt, primary, comparison.income),
        _cmpRow(str.expense, fmt, primary, comparison.expense, invertGood: true),
        _cmpRow(str.net, fmt, primary, comparison.net, signed: true),
        _savingsRow(str, fmt, current, previous, comparison),
      ],
      category: _categoryVM(snapshot, fmt, str, primary, primaryExpense, slices),
      trend: trend,
      largest: <AmountRowVM>[
        for (final txn in snapshot.largestTransactions)
          _largestRow(snapshot, str, fmt, txn),
      ],
      budgets: _budgets(snapshot, fmt, str, primary, lang),
      bills: _bills(snapshot, fmt, str),
      goals: _goals(snapshot, fmt, str, primary),
      insights:
          _insights(snapshot, fmt, str, comparison, slices, trend, primary, lang),
      appendix: _appendix(snapshot, fmt, str, lang),
    );
  }

  List<AppendixRowVM> _appendix(ReportDataSnapshot s, ReportMoneyFormatter fmt,
      ReportStrings str, String lang) {
    final showMerchant = s.request.content.includeMerchantNames &&
        !s.request.privacyMode;
    return <AppendixRowVM>[
      for (final t in s.appendixTransactions)
        () {
          final isIncome = t.type == TransactionTypeEntity.income ||
              t.type == TransactionTypeEntity.refund;
          final merchant = (showMerchant ? t.rawMerchant : null)?.trim();
          final category =
              t.categoryId == null ? '' : (_categoryLabel(s, lang, t.categoryId!) ?? '');
          return AppendixRowVM(
            date: _dateLabel(t.occurredAt.toLocal(), str),
            merchant: (merchant != null && merchant.isNotEmpty)
                ? merchant
                : (category.isNotEmpty ? category : str.transaction),
            category: category,
            amount: fmt.signedMoney(t.amount, t.currency, isExpense: !isIncome),
            isDebit: !isIncome,
          );
        }(),
    ];
  }

  // ── currency helpers ──

  String _primaryCurrency(ReportDataSnapshot s) {
    final totals = s.currencyTotals;
    final base = s.baseCurrency;
    // Prefer the user's base currency when the period actually has data in it.
    if (base != null && base.isNotEmpty && totals.any((t) => t.currency == base)) {
      return base;
    }
    if (totals.isEmpty) return (base != null && base.isNotEmpty) ? base : 'SAR';
    var best = totals.first;
    for (final t in totals) {
      if (t.expense + t.income > best.expense + best.income) best = t;
    }
    return best.currency;
  }

  double _income(List<CurrencyTotal> totals, String currency) {
    for (final t in totals) {
      if (t.currency == currency) return t.income;
    }
    return 0;
  }

  double _expense(List<CurrencyTotal> totals, String currency) {
    for (final t in totals) {
      if (t.currency == currency) return t.expense;
    }
    return 0;
  }

  CashFlowRowVM _cashRow(ReportMoneyFormatter fmt, ReportStrings str,
      ReportMetricsCalculator metrics, CurrencyTotal total) {
    final cf =
        metrics.computeCashFlow(income: total.income, expense: total.expense);
    return CashFlowRowVM(
      currency: total.currency,
      income: fmt.money(cf.income, total.currency),
      expense: fmt.money(cf.expense, total.currency),
      net: fmt.signedMoney(cf.net, total.currency, isExpense: cf.net < 0),
      savingsRate: cf.savingsRate == null ? '—' : fmt.percent(cf.savingsRate!),
    );
  }

  ComparisonRowVM _cmpRow(
    String metric,
    ReportMoneyFormatter fmt,
    String currency,
    MetricDelta delta, {
    bool signed = false,
    bool invertGood = false,
  }) {
    // For expense, a decrease is "good" (green); for income/net an increase is.
    final kind = delta.absolute == 0
        ? DeltaKind.neutral
        : (delta.isIncrease ^ invertGood)
            ? DeltaKind.up
            : DeltaKind.down;
    final pct = delta.percent;
    final deltaText = (pct == null || delta.absolute == 0)
        ? '—'
        : '${delta.isIncrease ? '+' : '−'}${fmt.percent1(pct)}';
    return ComparisonRowVM(
      metric: metric,
      thisValue: signed
          ? fmt.signedMoney(delta.current, currency, isExpense: delta.current < 0)
          : fmt.money(delta.current, currency),
      previousValue: signed
          ? fmt.signedMoney(delta.previous, currency,
              isExpense: delta.previous < 0)
          : fmt.money(delta.previous, currency),
      delta: deltaText,
      kind: kind,
    );
  }

  ComparisonRowVM _savingsRow(
    ReportStrings str,
    ReportMoneyFormatter fmt,
    CashFlowMetrics current,
    CashFlowMetrics previous,
    ComparisonMetrics comparison,
  ) {
    final points = comparison.savingsRatePoints;
    return ComparisonRowVM(
      metric: str.savingsRate,
      thisValue: current.savingsRate == null ? '—' : fmt.percent(current.savingsRate!),
      previousValue:
          previous.savingsRate == null ? '—' : fmt.percent(previous.savingsRate!),
      delta: (points == null || points == 0) ? '—' : fmt.points(points),
      kind: points == null || points == 0
          ? DeltaKind.neutral
          : (points > 0 ? DeltaKind.up : DeltaKind.down),
    );
  }

  // ── category ──

  String? _categoryLabel(ReportDataSnapshot s, String lang, String id) {
    final meta = s.categoryMeta[id];
    if (meta == null) return null; // deleted → folds into "Other"
    return lang == 'ar' ? meta.name : _titleCase(meta.key);
  }

  ReportCategoryVM _categoryVM(
    ReportDataSnapshot snapshot,
    ReportMoneyFormatter fmt,
    ReportStrings str,
    String primary,
    double primaryExpense,
    List<CategoryReportSlice> slices,
  ) {
    final rows = <CategoryRowVM>[];
    final donut = <DonutSliceVM>[];
    for (final slice in slices) {
      final color = slice.isOther
          ? _otherColor
          : _hexToArgb(snapshot.categoryMeta[slice.categoryId]?.colorHex);
      rows.add(CategoryRowVM(
        label: slice.label,
        value: fmt.money(slice.total, primary),
        percent: fmt.percent(slice.percent),
        colorArgb: color,
      ));
      donut.add(DonutSliceVM(slice.total, color));
    }
    return ReportCategoryVM(
      slices: donut,
      rows: rows,
      centerLabel: str.totalSpend,
      centerValue: fmt.money(primaryExpense, primary),
    );
  }

  // ── trend ──

  ReportTrendVM _trend(ReportDataSnapshot snapshot, ReportMoneyFormatter fmt,
      ReportStrings str, String primary) {
    final from = DateTime(
        snapshot.range.from.year, snapshot.range.from.month, snapshot.range.from.day);
    final days = snapshot.range.length.inDays.clamp(1, 366);
    final byIndex = <int, double>{};
    for (final d in snapshot.dailyExpense) {
      final day = DateTime(d.day.year, d.day.month, d.day.day);
      final idx = day.difference(from).inDays;
      if (idx >= 0 && idx < days) byIndex[idx] = d.total;
    }
    final bars = <double>[for (var i = 0; i < days; i++) byIndex[i] ?? 0.0];
    var maxValue = 0.0;
    var hotIndex = -1;
    var sum = 0.0;
    for (var i = 0; i < bars.length; i++) {
      sum += bars[i];
      if (bars[i] > maxValue) {
        maxValue = bars[i];
        hotIndex = i;
      }
    }
    final avg = sum / days;
    // A few evenly-spaced day-of-month x labels.
    final xLabels = <String>[
      '${from.day}',
      if (days > 8) '${from.add(Duration(days: days ~/ 2)).day}',
      '${from.add(Duration(days: days - 1)).day}',
    ];
    return ReportTrendVM(
      bars: bars,
      maxValue: maxValue,
      avg: avg,
      avgLabel: '${str.avg} ${fmt.money(avg, primary)}',
      hotIndex: hotIndex,
      xLabels: xLabels,
    );
  }

  // ── largest ──

  AmountRowVM _largestRow(ReportDataSnapshot snapshot, ReportStrings str,
      ReportMoneyFormatter fmt, TransactionEntity txn) {
    final showMerchant = snapshot.request.content.includeMerchantNames &&
        !snapshot.request.privacyMode;
    final merchant = (showMerchant ? txn.rawMerchant : null)?.trim();
    final categoryName = txn.categoryId == null
        ? null
        : snapshot.categoryMeta[txn.categoryId]?.name;
    final date = _dateLabel(txn.occurredAt.toLocal(), str);
    final subtitle =
        <String?>[categoryName, date].where((s) => s != null && s.isNotEmpty).join(' · ');
    final title = (merchant != null && merchant.isNotEmpty)
        ? merchant
        : (categoryName ?? str.transaction);
    return AmountRowVM(
      title: title,
      subtitle: subtitle,
      value: fmt.signedMoney(txn.amount, txn.currency, isExpense: true),
      colorArgb: _expenseColor,
    );
  }

  // ── budgets / bills / goals / insights ──

  List<BudgetBarVM> _budgets(ReportDataSnapshot s, ReportMoneyFormatter fmt,
      ReportStrings str, String primary, String lang) {
    return <BudgetBarVM>[
      for (final b in s.budgets)
        BudgetBarVM(
          label: _budgetLabel(s, lang, str, b.categoryId),
          amounts:
              '${fmt.money(b.spent, primary)} / ${fmt.money(b.limit, primary)}',
          ratio: b.ratio.clamp(0.0, 1.0).toDouble(),
          status: b.health == 'over'
              ? '${str.over} ${((b.ratio - 1) * 100).round()}%'
              : '${(b.ratio * 100).round()}% ${str.ofLimit}',
          colorArgb: _healthColor(b.health),
        ),
    ];
  }

  List<BillRowVM> _bills(
      ReportDataSnapshot s, ReportMoneyFormatter fmt, ReportStrings str) {
    return <BillRowVM>[
      for (final b in s.bills.take(8))
        BillRowVM(
          name: b.name,
          amount: fmt.money(b.amount, b.currency),
          due: b.dueDate == null ? '' : _dateLabel(b.dueDate!, str),
          isSubscription: b.isSubscription,
        ),
    ];
  }

  List<GoalBarVM> _goals(ReportDataSnapshot s, ReportMoneyFormatter fmt,
      ReportStrings str, String primary) {
    return <GoalBarVM>[
      for (final g in s.goals)
        GoalBarVM(
          name: g.name,
          amounts:
              '${fmt.money(g.saved, primary)} / ${fmt.money(g.target, primary)}',
          progress: g.progress,
          percent: fmt.percent(g.progress),
          meta: g.deadline == null ? '' : _dateLabel(g.deadline!, str),
        ),
    ];
  }

  List<InsightRowVM> _insights(
    ReportDataSnapshot s,
    ReportMoneyFormatter fmt,
    ReportStrings str,
    ComparisonMetrics comparison,
    List<CategoryReportSlice> slices,
    ReportTrendVM trend,
    String primary,
    String lang,
  ) {
    if (!s.request.content.includeInsights) return const <InsightRowVM>[];
    const engine = InsightEngine();
    final resolved = slices.where((sl) => !sl.isOther).toList();
    final top = resolved.isEmpty ? null : resolved.first;
    final overCount = s.budgets.where((b) => b.health == 'over').length;

    ReportBillLite? dueBill;
    int? dueDays;
    for (final b in s.bills) {
      final d = b.dueDate;
      if (d == null) continue;
      final days = d.difference(s.capturedAt).inDays;
      if (days >= 0) {
        dueBill = b;
        dueDays = days;
        break;
      }
    }

    final hasUnusual = trend.avg > 0 && trend.maxValue >= 1.8 * trend.avg;
    final input = InsightInput(
      expenseDeltaPct: comparison.expense.percent,
      savingsPointsDelta: comparison.savingsRatePoints,
      overBudgetCount: overCount,
      dominantCategoryLabel: top?.label,
      dominantCategoryShare: top?.percent ?? 0,
      dueBillName: dueBill?.name,
      dueBillAmount: dueBill?.amount,
      dueBillCurrency: dueBill?.currency,
      dueBillInDays: dueDays,
      hasUnusualDay: hasUnusual,
      unusualDayAmount: trend.maxValue,
      unusualDayFactor: trend.avg > 0 ? trend.maxValue / trend.avg : 0,
      currency: primary,
    );

    return <InsightRowVM>[
      for (final insight in engine.evaluate(input))
        InsightRowVM(_localizeInsight(str, fmt, insight),
            _severityColor(insight.severity)),
    ];
  }

  String _localizeInsight(
      ReportStrings str, ReportMoneyFormatter fmt, Insight insight) {
    final a = insight.args;
    String money() => fmt.money(
        (a['amount'] as double?) ?? 0, (a['currency'] as String?) ?? 'SAR');
    switch (insight.code) {
      case InsightCode.spendingDecreased:
        return str.insightSpendingDecreased
            .replaceAll('{pct}', fmt.percent1((a['pct'] as double?) ?? 0));
      case InsightCode.spendingIncreased:
        return str.insightSpendingIncreased
            .replaceAll('{pct}', fmt.percent1((a['pct'] as double?) ?? 0));
      case InsightCode.savingsImproved:
        return str.insightSavingsImproved
            .replaceAll('{pp}', fmt.percent1((a['pp'] as double?) ?? 0));
      case InsightCode.savingsDeclined:
        return str.insightSavingsDeclined
            .replaceAll('{pp}', fmt.percent1((a['pp'] as double?) ?? 0));
      case InsightCode.budgetsOver:
        return str.insightBudgetsOver.replaceAll('{count}', '${a['count'] ?? 0}');
      case InsightCode.dominantCategory:
        return str.insightDominantCategory
            .replaceAll('{category}', '${a['category'] ?? ''}')
            .replaceAll('{share}', fmt.percent((a['share'] as double?) ?? 0));
      case InsightCode.billDueSoon:
        return str.insightBillDueSoon
            .replaceAll('{bill}', '${a['bill'] ?? ''}')
            .replaceAll('{amount}', money())
            .replaceAll('{days}', '${a['days'] ?? 0}');
      case InsightCode.unusualDay:
        return str.insightUnusualDay
            .replaceAll('{amount}', money())
            .replaceAll('{factor}',
                ((a['factor'] as double?) ?? 0).toStringAsFixed(1));
    }
  }

  String _budgetLabel(ReportDataSnapshot s, String lang, ReportStrings str,
      String? categoryId) {
    if (categoryId == null || categoryId == '__all_expenses__') {
      return lang == 'ar' ? 'كل المصروفات' : 'All expenses';
    }
    return _categoryLabel(s, lang, categoryId) ?? str.other;
  }

  int _healthColor(String health) => switch (health) {
        'over' => _expenseColor,
        'warning' => 0xFFD97706,
        _ => _incomeColor,
      };

  int _severityColor(InsightSeverity severity) => switch (severity) {
        InsightSeverity.danger => _expenseColor,
        InsightSeverity.warning => 0xFFD97706,
        InsightSeverity.success => _incomeColor,
        InsightSeverity.info => 0xFF2E6BFF,
      };

  // ── labels / dates ──

  String _scopeLabel(ReportDataSnapshot snapshot, ReportStrings str) {
    final scope = snapshot.request.scope;
    if (scope is SingleAccountScope) {
      final ref = snapshot.accountsInScope.isEmpty
          ? null
          : snapshot.accountsInScope.first;
      if (ref == null || !ref.isAvailable || ref.name.isEmpty) {
        return str.allAccounts; // fallback; unavailable handled by composer caller
      }
      return ref.name;
    }
    return '${str.allAccounts} (${snapshot.accountsInScope.length})';
  }

  String _periodLabel(ReportDataSnapshot snapshot, ReportStrings str) {
    final from = snapshot.range.from;
    // Range is half-open; the displayed end is the last included day.
    final lastDay = snapshot.range.to.subtract(const Duration(days: 1));
    final fromMonth = str.months[from.month - 1];
    final toMonth = str.months[lastDay.month - 1];
    if (from.year == lastDay.year && from.month == lastDay.month) {
      return '${from.day} – ${lastDay.day} $fromMonth ${from.year}';
    }
    if (from.year == lastDay.year) {
      return '${from.day} $fromMonth – ${lastDay.day} $toMonth ${from.year}';
    }
    return '${from.day} $fromMonth ${from.year} – '
        '${lastDay.day} $toMonth ${lastDay.year}';
  }

  String _dateLabel(DateTime date, ReportStrings str) =>
      '${date.day} ${str.months[date.month - 1]} ${date.year}';

  String _verdict(
      ReportStrings str, ReportMoneyFormatter fmt, ComparisonMetrics comparison) {
    final pct = comparison.expense.percent;
    if (pct == null || pct.abs() < 0.005) return str.verdictFlat;
    final template = pct < 0 ? str.verdictLess : str.verdictMore;
    return template.replaceAll('{p}', fmt.percent1(pct));
  }

  static String _titleCase(String value) =>
      value.isEmpty ? value : value[0].toUpperCase() + value.substring(1);

  static int _hexToArgb(String? hex) {
    if (hex == null || hex.isEmpty) return _otherColor;
    var h = hex.replaceAll('#', '').trim();
    if (h.length == 6) h = 'FF$h';
    return int.tryParse(h, radix: 16) ?? _otherColor;
  }
}
