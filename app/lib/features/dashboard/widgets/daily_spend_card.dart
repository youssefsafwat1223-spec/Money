import 'package:flutter/material.dart';

import '../../../core/utils/l10n_ext.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/mali_tokens.dart';
import '../../../core/theme/widgets/mali_card.dart';
import '../../../domain/entities/report_models.dart';
import '../../../domain/entities/transaction_entity.dart';
import '../../../domain/finance/daily_allowance.dart';
import '../../../domain/finance/money.dart';
import '../../../domain/finance/money_format.dart';
import '../../cards/brand_mark.dart';
import '../../common/app_avatar.dart';
import '../../common/category_catalog.dart';
import '../../common/transaction_direction.dart';
import '../../../core/utils/formatters.dart';

/// Home's «المصروفات اليومية» card.
///
/// Answers three questions in one surface: what did I spend today, how does
/// that sit against my own week, and **how much can I still spend today**.
/// The last one is the number the user acts on and did not exist anywhere in
/// the app before.
///
/// Presentation only — every figure arrives pre-computed from
/// `dashboardDataProvider`; nothing here aggregates transactions.
///
/// On the seven bars and the Home/Reports split: these are seven fixed slots
/// with no axis, legend, tooltip or gesture — context for one number, not
/// analytics. Reports keeps the chart library and every interactive chart; see
/// `test/features/dashboard/no_charts_on_home_test.dart`, which encodes exactly
/// that boundary.
class DailySpendCard extends StatelessWidget {
  const DailySpendCard({
    super.key,
    required this.todaySpend,
    required this.lastSevenDays,
    required this.averageSevenDays,
    required this.availableToday,
    required this.todayVsYesterday,
    required this.todayTransactions,
    required this.todayIsTruncated,
    required this.catalog,
    required this.currencyLabel,
    required this.privacyMode,
    this.merchantLogos = const <String, String>{},
    this.onTransactionTap,
  });

  final Money todaySpend;

  /// Exactly seven slots, oldest → today (see [normalizeLastSevenDays]).
  final List<DailySpend> lastSevenDays;
  final Money averageSevenDays;

  /// Null when no monthly budget is set — rendered as «—» plus a prompt, never
  /// as a zero that would read as "nothing left".
  final Money? availableToday;

  /// Null when yesterday had no spend: a percentage against zero is not a
  /// comparison, so the chip is omitted rather than showing «+100%».
  final double? todayVsYesterday;

  final List<TransactionEntity> todayTransactions;

  /// True when today's rows came off a truncated read — the count is then
  /// rendered as «+N», never as an exact number.
  final bool todayIsTruncated;

  final CategoryCatalog catalog;
  final String currencyLabel;
  final bool privacyMode;
  final Map<String, String> merchantLogos;
  final void Function(TransactionEntity tx)? onTransactionTap;

  static const int _topCount = 3;

  /// The [_topCount] largest **debits** today, biggest first.
  ///
  /// Direction comes from [transactionIsDebit], not from the sign of `amount`:
  /// `amount` is a magnitude and is positive for income too, so filtering on it
  /// would list the salary as one of the day's biggest expenses.
  List<TransactionEntity> get _top {
    final debits = todayTransactions.where(transactionIsDebit).toList()
      ..sort((a, b) => b.amount.compareTo(a.amount));
    return debits.take(_topCount).toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final t = MaliTokens.of(context);
    final top = _top;

    return MaliCard(
      style: MaliSurfaceStyle.floating,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _headline(context, t),
          const SizedBox(height: AppSpacing.s4),
          _SevenDayBars(days: lastSevenDays),
          const SizedBox(height: AppSpacing.s4),
          _metrics(context, t),
          if (top.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.s4),
            Divider(height: 1, color: t.strokeSoft),
            const SizedBox(height: AppSpacing.s3),
            _topHeader(context, t),
            for (final tx in top) _topRow(context, t, tx),
          ],
        ],
      ),
    );
  }

  // ── «صرفت اليوم» + مقارنة بأمس ──────────────────────────────────────────

  Widget _headline(BuildContext context, MaliTokens t) {
    final c = context.colors;
    final ratio = todayVsYesterday;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(context.l10n.homeSpentToday,
                  style: AppTypography.caption(t.textOnCanvasMuted)),
              const SizedBox(height: 3),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(
                        privacyMode ? '••••' : formatMoney(todaySpend),
                        maxLines: 1,
                        style: AppTypography.custom(
                          size: 26,
                          weight: FontWeight.w700,
                          height: 1.15,
                          tabular: true,
                          color: t.textOnCanvasPrimary,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(currencyLabel,
                      style: AppTypography.caption(t.textOnCanvasMuted)),
                ],
              ),
            ],
          ),
        ),
        if (ratio != null) ...[
          const SizedBox(width: AppSpacing.s2),
          _DeltaChip(ratio: ratio, color: ratio > 0 ? c.danger : c.income),
        ],
      ],
    );
  }

  // ── المقاييس الثلاثة ────────────────────────────────────────────────────────

  Widget _metrics(BuildContext context, MaliTokens t) {
    final allowance = availableToday;
    // The count is exact only when the read was not truncated.
    final countLabel = todayIsTruncated
        ? '+${todayTransactions.length}'
        : '${todayTransactions.length}';
    return Container(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.s3),
      decoration: BoxDecoration(
        color: t.surfaceRaised,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: t.cardBorder),
      ),
      child: Row(
        children: [
          _metric(
            context,
            t,
            value: privacyMode ? '••••' : formatMoney(averageSevenDays),
            label: context.l10n.homeSevenDayAverage,
          ),
          _divider(t),
          _metric(
            context,
            t,
            value: allowance == null
                ? '—'
                : (privacyMode ? '••••' : formatMoney(allowance)),
            label: allowance == null ? context.l10n.homeSetMonthlyBudgetShort : context.l10n.homeAvailableToday,
            muted: allowance == null,
          ),
          _divider(t),
          _metric(context, t, value: countLabel, label: context.l10n.homeTodayTransactions),
        ],
      ),
    );
  }

  Widget _metric(
    BuildContext context,
    MaliTokens t, {
    required String value,
    required String label,
    bool muted = false,
  }) =>
      Expanded(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  value,
                  maxLines: 1,
                  style: AppTypography.custom(
                    size: 15,
                    weight: FontWeight.w600,
                    height: 1.2,
                    tabular: true,
                    color: muted
                        ? t.textOnCanvasMuted
                        : t.textOnCanvasPrimary,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: AppTypography.micro(t.textOnCanvasMuted),
              ),
            ),
          ],
        ),
      );

  Widget _divider(MaliTokens t) =>
      Container(width: 1, height: 30, color: t.cardBorder);

  // ── أعلى ٣ اليوم ─────────────────────────────────────────────────────────

  Widget _topHeader(BuildContext context, MaliTokens t) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.s2),
        child: Row(
          children: [
            Expanded(
              child: Text(context.l10n.homeTopThreeToday,
                  style: AppTypography.caption(t.textOnCanvasMuted)),
            ),
            Text(
              privacyMode
                  ? '•••• $currencyLabel'
                  : '${formatMoney(todaySpend)} $currencyLabel',
              style: AppTypography.caption(t.textOnCanvasMuted),
            ),
          ],
        ),
      );

  Widget _topRow(BuildContext context, MaliTokens t, TransactionEntity tx) {
    final category = catalog.byId(tx.categoryId);
    final title = tx.rawMerchant ?? category?.name ?? context.l10n.txnTransactionWord;
    final logo = BrandMark.logoFor(title, merchantLogos);
    return Semantics(
      button: onTransactionTap != null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTransactionTap == null ? null : () => onTransactionTap!(tx),
        child: ConstrainedBox(
          // Accessible touch target even though the row's own content is short.
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                (logo != null || BrandMark.hasBrand(title))
                    ? AppAvatar.brand(
                        name: title,
                        logoUrl: logo,
                        size: AppSpacing.avatarSm)
                    : AppAvatar.category(
                        iconName: category?.iconName,
                        merchantName: title,
                        color: category?.color,
                        size: AppSpacing.avatarSm),
                const SizedBox(width: AppSpacing.s3),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.subhead(t.textOnCanvasPrimary),
                  ),
                ),
                const SizedBox(width: AppSpacing.s2),
                Text(
                  category?.name ?? context.l10n.homeUncategorised,
                  style: AppTypography.micro(t.textOnCanvasMuted),
                ),
                const SizedBox(width: AppSpacing.s3),
                Text(
                  privacyMode
                      ? '••••'
                      : formatMoney(Money(tx.amountMoney.minorUnits.abs(),
                          tx.amountMoney.currency)),
                  style: AppTypography.custom(
                    size: 14,
                    weight: FontWeight.w500,
                    height: 1.3,
                    tabular: true,
                    color: t.textOnCanvasPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Seven fixed slots. One de-emphasised colour for the week, the accent for
/// today — the days are ONE series, so colouring each of them separately would
/// burn the only free channel on information the bar heights already carry.
class _SevenDayBars extends StatelessWidget {
  const _SevenDayBars({required this.days});

  final List<DailySpend> days;

  static const double _maxHeight = 56;
  static const double _minHeight = 3;

  @override
  Widget build(BuildContext context) {
    final t = MaliTokens.of(context);
    final c = context.colors;
    // Scale on the largest MAGNITUDE so a refund day (negative) still renders
    // a proportional bar instead of collapsing the whole chart.
    var peak = 0;
    for (final d in days) {
      final v = d.total.minorUnits.abs();
      if (v > peak) peak = v;
    }
    // No fixed total height: the plot area is fixed at [_maxHeight] but the
    // label below it grows with the text scaler, so the row must size to its
    // content. A `SizedBox(height: _maxHeight + 18)` here overflowed at 1.6×.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < days.length; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          Expanded(
            child: _bar(
              context,
              t,
              day: days[i],
              isToday: i == days.length - 1,
              peak: peak,
              accent: c.cta,
            ),
          ),
        ],
      ],
    );
  }

  Widget _bar(
    BuildContext context,
    MaliTokens t, {
    required DailySpend day,
    required bool isToday,
    required int peak,
    required Color accent,
  }) {
    final magnitude = day.total.minorUnits.abs();
    final height = peak <= 0
        ? _minHeight
        : (_minHeight + (_maxHeight - _minHeight) * (magnitude / peak))
            .clamp(_minHeight, _maxHeight)
            .toDouble();
    final label = isToday
        ? context.l10n.txnRangeToday
        : Formatters.weekdayInitial(context, day.day);
    return Semantics(
      label: context.l10n.homeDayAmountSemantics(label, formatMoney(day.total)),
      excludeSemantics: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          // Fixed plot area; the bar grows from its baseline inside it.
          SizedBox(
            height: _maxHeight,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                height: height,
                constraints: const BoxConstraints(maxWidth: 22),
                decoration: BoxDecoration(
                  color: isToday ? accent : t.ringTrackNeutral,
                  // Rounded at the data end, square on the baseline: a fully
                  // rounded cap lifts the bar off the axis and misstates its
                  // length.
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(4)),
                ),
              ),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            label,
            maxLines: 1,
            style: AppTypography.micro(
              isToday ? t.textOnCanvasPrimary : t.textOnCanvasMuted,
            ).copyWith(fontSize: 10),
          ),
        ],
      ),
    );
  }
}

class _DeltaChip extends StatelessWidget {
  const _DeltaChip({required this.ratio, required this.color});

  final double ratio;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final pct = (ratio.abs() * 100).round();
    // Cap the label so an unusual spike cannot break the row's layout.
    final text = pct > 999 ? '+999%' : '${ratio > 0 ? '+' : '−'}$pct%';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        context.l10n.homeVsYesterdayValue(text),
        maxLines: 1,
        style: AppTypography.micro(color).copyWith(fontWeight: FontWeight.w700),
      ),
    );
  }
}
