import 'package:flutter/material.dart';

import '../../../core/utils/l10n_ext.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/mali_tokens.dart';
import '../../../core/theme/widgets/mali_card.dart';
import '../../../domain/entities/bill_entity.dart';
import '../../../domain/finance/bill_metrics.dart';
import '../../../domain/finance/money.dart';
import '../../../domain/finance/money_format.dart';
import '../../common/app_avatar.dart';

/// Home's «الاشتراكات والأقساط» card.
///
/// What it adds over the old horizontal rail:
///   * **the annual cost** beside each row — normalized through
///     [annualEquivalentMoney], never a blind ×12, because weekly is ×52,
///     yearly is ×1 and custom is ×(365/interval). The yearly figure is the
///     one that makes people cancel a subscription;
///   * **instalments**, which Home never showed at all, with how many payments
///     remain;
///   * **a month strip** of upcoming charge dates, so "when does money leave"
///     is answerable at a glance instead of by reading every row.
///
/// Presentation only. Subscriptions and instalments arrive as separate lists
/// because they are separate obligations that must never be summed together.
class ObligationsCard extends StatelessWidget {
  const ObligationsCard({
    super.key,
    required this.subscriptions,
    required this.installments,
    required this.displayCurrency,
    required this.currencyLabel,
    required this.privacyMode,
    required this.now,
    this.onTap,
  });

  final List<BillEntity> subscriptions;
  final List<BillEntity> installments;
  final String displayCurrency;
  final String currencyLabel;
  final bool privacyMode;
  final DateTime now;
  final void Function(BillEntity bill)? onTap;

  static const int _maxRows = 4;

  /// Monthly obligation of the ACTIVE subscriptions only, in the display
  /// currency — the codebase's single canonical metric for this number.
  Money get _monthlySubscriptions =>
      subscriptionMonthlyTotalMoney(subscriptions, displayCurrency);

  /// The instalments' own monthly commitment, kept as its own line rather than
  /// folded into the figure above: they are finite, and adding them would make
  /// «التزام شهري» mean something different from everywhere else in the app.
  Money get _monthlyInstallments =>
      monthlyEquivalentsTotalMoney(installments, displayCurrency);

  List<BillEntity> get _rows {
    final all = [...subscriptions, ...installments]
      ..sort((a, b) => a.nextDueDate.compareTo(b.nextDueDate));
    return all.take(_maxRows).toList(growable: false);
  }

  BillEntity? get _nearest {
    final all = _rows;
    return all.isEmpty ? null : all.first;
  }

  @override
  Widget build(BuildContext context) {
    final t = MaliTokens.of(context);
    final rows = _rows;

    return MaliCard(
      style: MaliSurfaceStyle.floating,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _metrics(context, t),
          const SizedBox(height: AppSpacing.s3),
          Divider(height: 1, color: t.strokeSoft),
          const SizedBox(height: AppSpacing.s3),
          _monthStrip(context, t),
          const SizedBox(height: AppSpacing.s3),
          for (final bill in rows) _row(context, t, bill),
        ],
      ),
    );
  }

  // ── المقاييس ───────────────────────────────────────────────────────────────

  Widget _metrics(BuildContext context, MaliTokens t) {
    final c = context.colors;
    final nearest = _nearest;
    final days = nearest == null ? null : _daysUntil(nearest.nextDueDate);
    final hasInstallments = _monthlyInstallments.minorUnits > 0;
    return Row(
      children: [
        _metric(
          t,
          privacyMode ? '••••' : formatMoney(_monthlySubscriptions),
          context.l10n.homeSubsPerMonth,
        ),
        _sep(t),
        if (hasInstallments) ...[
          _metric(
            t,
            privacyMode ? '••••' : formatMoney(_monthlyInstallments),
            context.l10n.homeInstalmentsPerMonth,
          ),
          _sep(t),
        ],
        _metric(
          t,
          days == null
              ? '—'
              : days <= 0
                  ? context.l10n.txnRangeToday
                  : context.l10n.homeInDaysShort(days),
          context.l10n.homeNextCharge,
          valueColor: days == null
              ? null
              : days <= 0
                  ? c.danger
                  : days <= 3
                      ? c.warning
                      : null,
        ),
      ],
    );
  }

  Widget _metric(MaliTokens t, String value, String label,
          {Color? valueColor}) =>
      Expanded(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
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

  // ── شريط مواعيد الشهر ──────────────────────────────────────────────────────

  /// A month-long rail with a dot per upcoming charge and a marker for today.
  /// It answers "when does money leave this month" without reading any row.
  Widget _monthStrip(BuildContext context, MaliTokens t) {
    final c = context.colors;
    final daysInMonth = DateTime(now.year, now.month + 1, 0).day;
    final dots = <Widget>[];
    for (final bill in [...subscriptions, ...installments]) {
      final due = bill.nextDueDate;
      if (due.year != now.year || due.month != now.month) continue;
      final days = _daysUntil(due);
      dots.add(Align(
        alignment: AlignmentDirectional((due.day - 1) / (daysInMonth - 1) * 2 - 1,
            0),
        child: Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: days <= 0
                ? c.danger
                : days <= 3
                    ? c.warning
                    : t.textOnCanvasMuted,
            border: Border.all(color: t.surfaceFloating, width: 2),
          ),
        ),
      ));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 10,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                height: 5,
                decoration: BoxDecoration(
                  color: t.ringTrackNeutral,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
              ),
              // Elapsed part of the month, so the dots read as "ahead" or
              // "behind" today rather than as free-floating marks.
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: FractionallySizedBox(
                  widthFactor: (now.day / daysInMonth).clamp(0.0, 1.0),
                  child: Container(
                    height: 5,
                    decoration: BoxDecoration(
                      color: c.cta.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                    ),
                  ),
                ),
              ),
              ...dots,
            ],
          ),
        ),
        const SizedBox(height: 6),
        Text(
          context.l10n.homeChargeDatesThisMonth,
          style: AppTypography.micro(t.textOnCanvasMuted),
        ),
      ],
    );
  }

  // ── الصفوف ─────────────────────────────────────────────────────────────────

  Widget _row(BuildContext context, MaliTokens t, BillEntity bill) {
    final c = context.colors;
    final days = _daysUntil(bill.nextDueDate);
    final isInstallment = bill.type == BillType.installment;
    final dueColor = days < 0
        ? c.danger
        : days == 0
            ? c.danger
            : days <= 3
                ? c.warning
                : t.textOnCanvasMuted;
    final dueLabel = days < 0
        ? context.l10n.txnOverdueDays(days.abs())
        : days == 0
            ? context.l10n.txnDueToday
            : context.l10n.txnInDays(days);
    final annual = annualEquivalentMoney(bill);

    return Semantics(
      button: onTap != null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap == null ? null : () => onTap!(bill),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 7),
            child: Row(
              children: [
                AppAvatar.brand(name: bill.name, size: AppSpacing.avatarSm),
                const SizedBox(width: AppSpacing.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(bill.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppTypography.subhead(
                                    t.textOnCanvasPrimary)),
                          ),
                          if (isInstallment) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: c.cta.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(context.l10n.homeInstalmentWord,
                                  style: AppTypography.micro(c.cta)
                                      .copyWith(fontWeight: FontWeight.w700)),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(dueLabel,
                          style: AppTypography.micro(dueColor)),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.s2),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      privacyMode ? '••••' : formatMoney(bill.amountMoney),
                      style: AppTypography.custom(
                        size: 14.5,
                        weight: FontWeight.w500,
                        height: 1.3,
                        tabular: true,
                        color: t.textOnCanvasPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      privacyMode
                          ? '••••'
                          : context.l10n.homePerYearAmount(formatMoney(annual), currencyLabel),
                      style: AppTypography.micro(t.textOnCanvasMuted),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Whole days from today to [due]; a due date is a DAY, so a charge later
  /// today is «مستحق اليوم», not "in 0.4 days".
  int _daysUntil(DateTime due) => DateTime(due.year, due.month, due.day)
      .difference(DateTime(now.year, now.month, now.day))
      .inDays;
}
