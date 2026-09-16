import 'package:flutter/material.dart';

import '../../../core/utils/l10n_ext.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/mali_tokens.dart';
import '../../../core/theme/widgets/mali_card.dart';
import '../../../core/theme/widgets/ring_progress.dart';
import '../../../core/utils/app_lucide_icons.dart';
import '../../../domain/finance/money.dart';
import '../../../domain/finance/money_format.dart';
import '../dashboard_providers.dart';

/// Home's «المصروفات الشهرية» card.
///
/// Three things the old ring did not say:
///   1. **where you should be** — a mark on the meter at the month's own
///      elapsed fraction, so 75% spent on day 20 of 31 reads as "ahead by 10",
///      not as a bare percentage;
///   2. **where this ends** — the month-end forecast, which already existed in
///      `DashboardData.projectedMonthSpend` and was never rendered;
///   3. **what changed** — each top category against the previous window.
///
/// Presentation only; every figure arrives computed.
class MonthlySpendCard extends StatelessWidget {
  const MonthlySpendCard({
    super.key,
    required this.spent,
    required this.limit,
    required this.ratio,
    required this.monthElapsedRatio,
    required this.projectedMonthSpend,
    required this.categories,
    required this.categoryCount,
    required this.currencyLabel,
    required this.privacyMode,
    this.onCategoryTap,
  });

  final Money spent;

  /// Zero when no monthly budget is set — the card then drops the meter and
  /// the forecast rather than dividing by nothing.
  final Money limit;
  final double ratio;

  /// 0..1 through the calendar month.
  final double monthElapsedRatio;

  /// Month-end spend at the current pace.
  final double projectedMonthSpend;

  final List<CategorySlice> categories;
  final int categoryCount;
  final String currencyLabel;
  final bool privacyMode;
  final VoidCallback? onCategoryTap;

  bool get _hasBudget => !limit.isZero && !limit.isNegative;

  /// The forecast is only worth stating when it changes the answer: a pace
  /// that lands inside the budget needs no warning, and without a budget there
  /// is nothing to land inside of.
  bool get _forecastOverruns =>
      _hasBudget && projectedMonthSpend > limit.toDouble();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = MaliTokens.of(context);
    final tone = _hasBudget
        ? c.budgetState(ratio)
        : t.textOnCanvasMuted;

    return MaliCard(
      style: MaliSurfaceStyle.floating,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _summary(context, t, tone),
          if (_hasBudget) ...[
            const SizedBox(height: AppSpacing.s4),
            _meter(context, t, tone),
          ],
          if (_forecastOverruns) ...[
            _divider(t),
            _forecast(context, t, c),
          ],
          if (categories.isNotEmpty) ...[
            _divider(t),
            _categories(context, t),
          ],
        ],
      ),
    );
  }

  Widget _divider(MaliTokens t) => Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.s3),
        child: Divider(height: 1, color: t.strokeSoft),
      );

  // ── الحلقة + الأرقام ────────────────────────────────────────────────────────

  Widget _summary(BuildContext context, MaliTokens t, Color tone) {
    return Row(
      children: [
        RingProgress(
          value: _hasBudget ? ratio.clamp(0.0, 1.0) : null,
          size: 72,
          strokeWidth: 7,
          color: tone,
          child: Text(
            _hasBudget ? '${(ratio * 100).round()}%' : '—',
            style: AppTypography.custom(
              size: 15,
              weight: FontWeight.w600,
              height: 1.1,
              color: t.textOnCanvasPrimary,
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.s4),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _line(t, context.l10n.bdgSpent, spent, t.textOnCanvasPrimary),
              const SizedBox(height: AppSpacing.s2),
              if (_hasBudget) ...[
                _line(t, context.l10n.homeBudget, limit, t.textOnCanvasSecondary),
                const SizedBox(height: AppSpacing.s2),
                _line(t, context.l10n.bdgRemaining, limit - spent,
                    (limit - spent).isNegative
                        ? context.colors.danger
                        : context.colors.income),
              ] else
                Text(
                  context.l10n.homeNoMonthlyBudget,
                  style: AppTypography.caption(t.textOnCanvasMuted),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _line(MaliTokens t, String label, Money value, Color valueColor) => Row(
        children: [
          Expanded(
            child: Text(label,
                style: AppTypography.caption(t.textOnCanvasMuted)),
          ),
          Text(
            privacyMode ? '••••' : formatMoney(value),
            style: AppTypography.custom(
              size: 14,
              weight: FontWeight.w600,
              height: 1.3,
              tabular: true,
              color: valueColor,
            ),
          ),
        ],
      );

  // ── الميتر + علامة «فين المتوقع تكون» ──────────────────────────────────────

  Widget _meter(BuildContext context, MaliTokens t, Color tone) {
    final ahead = ratio - monthElapsedRatio;
    final aheadPct = (ahead.abs() * 100).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(builder: (context, box) {
          final markLeft =
              (box.maxWidth * monthElapsedRatio.clamp(0.0, 1.0)) - 1;
          return SizedBox(
            height: 14,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Align(
                  alignment: Alignment.center,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    child: SizedBox(
                      height: 8,
                      child: LinearProgressIndicator(
                        value: ratio.clamp(0.0, 1.0),
                        // Same-hue track, not a neutral grey: the state then
                        // reads across the whole bar rather than only its fill.
                        backgroundColor:
                            tone.withValues(alpha: 0.18),
                        valueColor: AlwaysStoppedAnimation(tone),
                      ),
                    ),
                  ),
                ),
                // The month's own progress. Drawn in the surface colour so it
                // reads as a NOTCH in the bar, not as a third data value.
                PositionedDirectional(
                  start: markLeft.clamp(0.0, box.maxWidth - 2),
                  top: 0,
                  bottom: 0,
                  child: Container(
                    width: 2,
                    decoration: BoxDecoration(
                      color: t.surfaceFloating,
                      borderRadius: BorderRadius.circular(1),
                    ),
                  ),
                ),
              ],
            ),
          );
        }),
        const SizedBox(height: AppSpacing.s2),
        Row(
          children: [
            Expanded(
              child: Text(
                context.l10n.homeExpectedPctOfMonth((monthElapsedRatio * 100).round()),
                style: AppTypography.micro(t.textOnCanvasMuted),
              ),
            ),
            if (aheadPct >= 1)
              Text(
                ahead > 0
                    ? context.l10n.homeAheadPct(aheadPct)
                    : context.l10n.homeBehindPct(aheadPct),
                style: AppTypography.micro(
                  ahead > 0
                      ? context.colors.warning
                      : context.colors.income,
                ).copyWith(fontWeight: FontWeight.w700),
              ),
          ],
        ),
      ],
    );
  }

  // ── التوقّع ─────────────────────────────────────────────────────────────────

  Widget _forecast(BuildContext context, MaliTokens t, AppColors c) {
    final over = projectedMonthSpend - limit.toDouble();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(AppLucideIcons.trendingUp, size: 16, color: c.danger),
        const SizedBox(width: AppSpacing.s2),
        Expanded(
          child: Text.rich(
            TextSpan(
              style: AppTypography.caption(t.textOnCanvasSecondary)
                  .copyWith(height: 1.6),
              children: [
                TextSpan(text: context.l10n.homeAtThisRatePrefix),
                TextSpan(
                  text: privacyMode
                      ? '••••'
                      : formatMoneyAmount(projectedMonthSpend, limit.currency),
                  style: AppTypography.caption(c.danger)
                      .copyWith(fontWeight: FontWeight.w700, height: 1.6),
                ),
                TextSpan(
                  text: privacyMode
                      ? ' $currencyLabel.'
                      : ' $currencyLabel — '
                          '${context.l10n.homeOverBudgetBy(formatMoneyAmount(over, limit.currency))}',
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── التصنيفات ───────────────────────────────────────────────────────────────

  Widget _categories(BuildContext context, MaliTokens t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(context.l10n.homeTopCategories,
                  style: AppTypography.caption(t.textOnCanvasMuted)),
            ),
            Text(
              context.l10n.homeNofM(categories.length, categoryCount),
              style: AppTypography.micro(t.textOnCanvasMuted),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.s2),
        for (final slice in categories) _categoryRow(context, t, slice),
      ],
    );
  }

  Widget _categoryRow(BuildContext context, MaliTokens t, CategorySlice slice) {
    final c = context.colors;
    final change = slice.changeRatio;
    return Semantics(
      button: onCategoryTap != null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onCategoryTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: slice.category.color,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: AppSpacing.s2),
              Expanded(
                child: Text(
                  slice.category.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.subhead(t.textOnCanvasPrimary),
                ),
              ),
              const SizedBox(width: AppSpacing.s2),
              Text(
                privacyMode ? '••••' : formatMoney(slice.total),
                style: AppTypography.custom(
                  size: 13,
                  weight: FontWeight.w500,
                  height: 1.3,
                  tabular: true,
                  color: t.textOnCanvasPrimary,
                ),
              ),
              // A category that did not exist last period has no percentage
              // change; the slot stays empty rather than claiming «+100%».
              SizedBox(
                width: 54,
                child: change == null
                    ? const SizedBox.shrink()
                    : Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: _changePill(
                          change,
                          change > 0 ? c.danger : c.income,
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _changePill(double change, Color color) {
    final pct = (change.abs() * 100).round();
    final text = pct > 999 ? '999%+' : '${change > 0 ? '+' : '−'}$pct%';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        text,
        maxLines: 1,
        style: AppTypography.micro(color).copyWith(fontWeight: FontWeight.w700),
      ),
    );
  }
}
