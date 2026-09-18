import 'package:flutter/material.dart';

import '../../../core/utils/l10n_ext.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/mali_tokens.dart';
import '../../../core/theme/widgets/mali_card.dart';
import '../../../core/theme/widgets/ring_progress.dart';
import '../../../domain/entities/budget_entity.dart';
import '../../../domain/finance/money_format.dart';
import '../dashboard_providers.dart';

/// Home's «الميزانيات» section: one row per budget, with the state ring, the
/// spent/limit pair, and what is left — or what was exceeded.
///
/// The list scrolls inside a fixed box (~3 rows) rather than growing the page,
/// matching the pattern Home already uses for its budget box today, so a user
/// with twelve budgets does not get a twelve-screen dashboard.
///
/// All-expenses roll-up budgets are shown separately from category budgets by
/// their own label — they are the total, not another category, and stacking
/// them in one list invites reading the sum as double what it is.
class BudgetsCard extends StatelessWidget {
  const BudgetsCard({
    super.key,
    required this.entries,
    required this.privacyMode,
    this.maxHeight = 204,
    this.onTap,
  });

  final List<DashboardBudgetEntry> entries;
  final bool privacyMode;
  final double maxHeight;
  final VoidCallback? onTap;

  int get _overCount => entries.where((e) => e.ratio >= 1.0).length;

  /// Consumption across the listed budgets. Only meaningful when they share a
  /// currency, which they do here: the dashboard is single-currency by
  /// construction (the selected account decides).
  int get _usedRatioPercent {
    var spent = 0;
    var limit = 0;
    for (final e in entries) {
      spent += e.spent.minorUnits;
      limit += e.limit.minorUnits;
    }
    if (limit <= 0) return 0;
    return (spent / limit * 100).round();
  }

  @override
  Widget build(BuildContext context) {
    final t = MaliTokens.of(context);
    if (entries.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, AppSpacing.s2),
        child: Text(context.l10n.homeNoBudgetsOnAccount,
            style: AppTypography.caption(t.textOnCanvasSecondary)),
      );
    }

    return MaliCard(
      style: MaliSurfaceStyle.floating,
      padding: EdgeInsets.zero,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _metrics(context, t),
          Divider(height: 1, color: t.strokeSoft),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: entries.length,
              itemBuilder: (context, i) => _row(context, t, entries[i]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _metrics(BuildContext context, MaliTokens t) {
    final c = context.colors;
    final over = _overCount;
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s2, vertical: AppSpacing.s3),
      child: Row(
        children: [
          _metric(t, '${entries.length}', context.l10n.homeActiveBudget),
          _sep(t),
          _metric(t, '$_usedRatioPercent%', context.l10n.bdgUsageRate),
          _sep(t),
          _metric(t, '$over', context.l10n.bdgStateOverF,
              valueColor: over > 0 ? c.danger : null),
        ],
      ),
    );
  }

  Widget _metric(MaliTokens t, String value, String label,
          {Color? valueColor}) =>
      Expanded(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              value,
              maxLines: 1,
              style: AppTypography.custom(
                size: 15,
                weight: FontWeight.w600,
                height: 1.2,
                tabular: true,
                color: valueColor ?? t.textOnCanvasPrimary,
              ),
            ),
            const SizedBox(height: 3),
            Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.micro(t.textOnCanvasMuted)),
          ],
        ),
      );

  Widget _sep(MaliTokens t) =>
      Container(width: 1, height: 28, color: t.cardBorder);

  Widget _row(BuildContext context, MaliTokens t, DashboardBudgetEntry entry) {
    final c = context.colors;
    final hasLimit = !entry.limit.isZero && !entry.limit.isNegative;
    final ratio = hasLimit ? entry.ratio : null;
    final tone = hasLimit
        ? c.budgetState(entry.ratio,
            warnAtPercent: entry.alertThresholdPercent)
        : t.textOnCanvasMuted;
    final over = entry.spent.minorUnits > entry.limit.minorUnits;
    final left = over ? entry.spent - entry.limit : entry.limit - entry.spent;
    final periodLabel = switch (entry.period) {
      BudgetPeriod.daily => context.l10n.bdgFilterDaily,
      BudgetPeriod.weekly => context.l10n.txnCycleWeekly,
      BudgetPeriod.monthly => context.l10n.txnCycleMonthly,
      BudgetPeriod.yearly => context.l10n.txnCycleYearly,
    };

    return Semantics(
      button: onTap != null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            child: Row(
              children: [
                RingProgress(
                  value: ratio?.clamp(0.0, 1.0),
                  size: 44,
                  strokeWidth: 5,
                  color: tone,
                  child: Text(
                    ratio == null ? '—' : '${(ratio * 100).round()}%',
                    style: AppTypography.caption(t.textOnCanvasPrimary),
                  ),
                ),
                const SizedBox(width: AppSpacing.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(entry.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.bodyStrong(
                              t.textOnCanvasPrimary)),
                      const SizedBox(height: 3),
                      Text(
                        privacyMode
                            ? '•••• / ••••'
                            : '${formatMoney(entry.spent)} / '
                                '${formatMoney(entry.limit)} · $periodLabel',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.custom(
                          size: 11.5,
                          weight: FontWeight.w500,
                          height: 1.3,
                          tabular: true,
                          color: t.textOnCanvasMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.s2),
                if (hasLimit)
                  Text(
                    privacyMode
                        ? '••••'
                        : '${over ? 'تجاوز' : context.l10n.bdgRemaining} ${formatMoney(left)}',
                    style: AppTypography.custom(
                      size: 12,
                      weight: FontWeight.w600,
                      height: 1.3,
                      tabular: true,
                      color: over ? c.danger : c.income,
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
