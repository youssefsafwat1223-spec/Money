import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/di/app_providers.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/calm_page_header.dart';
import '../../core/theme/widgets/mali_card.dart';
import '../../core/theme/widgets/mali_glass.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/formatters.dart';
import '../../domain/finance/money.dart';
import '../../domain/entities/bill_entity.dart';
import '../../domain/finance/bill_metrics.dart';
import '../cards/brand_mark.dart';
import '../common/premium_loading.dart';
import 'bill_details_sheet.dart';
import 'bill_form_sheet.dart';
import 'subscriptions_providers.dart';

String _dueInLabel(DateTime due) {
  final days = due.difference(DateTime.now()).inDays;
  if (days < 0) return 'متأخر';
  if (days == 0) return 'اليوم';
  return 'بعد $days يوم';
}

class SubscriptionsScreen extends ConsumerWidget {
  const SubscriptionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final billsAsync = ref.watch(savedBillsProvider);
    final suggestionsAsync = ref.watch(subscriptionsProvider);
    final baseCur = ref.watch(baseCurrencyProvider).valueOrNull ?? 'SAR';

    return billsAsync.when(
      skipLoadingOnReload: true,
      loading: () => Scaffold(
        appBar: Navigator.of(context).canPop()
            ? AppBar(title: const Text('الاشتراكات والفواتير'))
            : null,
        body: const FirstLoadPlaceholder(cardCount: 4),
      ),
      error: (e, _) => Scaffold(
        appBar: Navigator.of(context).canPop()
            ? AppBar(title: const Text('الاشتراكات والفواتير'))
            : null,
        body: const Center(child: Text('حدث خطأ')),
      ),
      data: (bills) {
        final subs =
            bills.where((b) => b.type == BillType.subscription).toList();
        final insts =
            bills.where((b) => b.type == BillType.installment).toList();
        final suggestions = suggestionsAsync.valueOrNull ?? [];
        // MALI-064n: projected monthly recurring obligation (frequency-
        // normalized, active subscriptions only) — the ONE canonical metric.
        // Summed EXACTLY as Money in the base display currency (currency-
        // isolated); converted to double only here at the display leaf.
        final monthlyTotal =
            subscriptionMonthlyTotalMoney(subs, baseCur).toDouble();

        return DefaultTabController(
          length: 2,
          child: Scaffold(
            body: SafeArea(
              top: false,
              bottom: false,
              child: NestedScrollView(
                headerSliverBuilder: (context, innerBoxIsScrolled) {
                  return [
                    SliverToBoxAdapter(
                      child: Column(
                        children: [
                          _BillsHeader(
                            monthly: monthlyTotal,
                            subsCount: subs.length,
                            instsCount: insts.length,
                            currency: Currency.arabicLabel(baseCur),
                          ),
                          const SizedBox(height: AppSpacing.s2),
                        ],
                      ),
                    ),
                    SliverPersistentHeader(
                      pinned: true,
                      delegate: _TabBarDelegate(
                        child: MaliGlass(
                          variant: MaliGlassVariant.card,
                          radius: 0,
                          padding: EdgeInsets.zero,
                          child: Container(
                            height: 64.0,
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.gutter,
                            ),
                            alignment: Alignment.center,
                            child: Container(
                              height: 48,
                              padding: const EdgeInsets.all(4),
                              decoration: BoxDecoration(
                                color: context.colors.surface2,
                                borderRadius:
                                    BorderRadius.circular(AppRadius.pill),
                              ),
                              child: TabBar(
                                indicatorSize: TabBarIndicatorSize.tab,
                                dividerColor: Colors.transparent,
                                labelColor: Theme.of(context).brightness ==
                                        Brightness.dark
                                    ? context.colors.accent
                                    : Colors.white,
                                unselectedLabelColor: context.colors.textLight,
                                indicator: BoxDecoration(
                                  color: Theme.of(context).brightness ==
                                          Brightness.dark
                                      ? context.colors.accent
                                          .withValues(alpha: 0.22)
                                      : context.colors.primary,
                                  borderRadius:
                                      BorderRadius.circular(AppRadius.pill),
                                ),
                                tabs: [
                                  Tab(text: 'الاشتراكات (${subs.length})'),
                                  Tab(text: 'الأقساط (${insts.length})'),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ];
                },
                body: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
                  child: TabBarView(
                    children: [
                      _SubscriptionsTab(
                        bills: subs,
                        suggestions: suggestions,
                        baseCurrency: baseCur,
                      ),
                      _InstallmentsTab(bills: insts),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TabBarDelegate extends SliverPersistentHeaderDelegate {
  _TabBarDelegate({required this.child});
  final Widget child;

  @override
  double get minExtent => 64.0;
  @override
  double get maxExtent => 64.0;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return child;
  }

  @override
  bool shouldRebuild(covariant _TabBarDelegate oldDelegate) {
    return oldDelegate.child != child;
  }
}

// ─── Header
class _BillsHeader extends StatelessWidget {
  const _BillsHeader({
    required this.monthly,
    required this.subsCount,
    required this.instsCount,
    required this.currency,
  });

  final double monthly;
  final int subsCount;
  final int instsCount;
  final String currency;

  @override
  Widget build(BuildContext context) {
    return CalmPageHeader(
      title: 'الاشتراكات والفواتير',
      subtitle: 'إجمالي الصرف الشهري',
      leading: Navigator.of(context).canPop()
          ? const BackButton(color: Colors.white)
          : null,
      trailing: _AddButton(
        onTap: () => BillFormSheet.show(
          context,
          initialType: BillType.subscription,
        ),
      ),
      amount: Formatters.amount(monthly),
      currency: currency,
      metrics: [
        CalmMetric(label: 'اشتراكات نشطة', value: '$subsCount'),
        CalmMetric(label: 'أقساط جارية', value: '$instsCount'),
        CalmMetric(
            label: 'سنوياً المجموع', value: Formatters.amount(monthly * 12)),
      ],
    );
  }
}

class _AddButton extends StatelessWidget {
  const _AddButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MaliGlass(
      variant: MaliGlassVariant.headerAction,
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: const SizedBox(
        width: 44,
        height: 44,
        child: Center(
          child: Icon(Icons.add_rounded, color: Colors.white, size: 24),
        ),
      ),
    );
  }
}

// ─── Subscriptions Tab ───────────────────────────────────────────────────────

class _SubscriptionsTab extends StatelessWidget {
  const _SubscriptionsTab({
    required this.bills,
    required this.suggestions,
    required this.baseCurrency,
  });

  final List<BillEntity> bills;
  final List<dynamic> suggestions;
  final String baseCurrency;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (bills.isEmpty && suggestions.isEmpty) {
      return _EmptyState(
        icon: AppLucideIcons.repeat,
        title: 'اشتراكاتك في مكان واحد',
        body: 'أضف اشتراكك يدويًا أو خليه يتكشف تلقائيًا لما يتكرر نفس الدفع.',
        actionLabel: 'إضافة اشتراك',
        onAction: () =>
            BillFormSheet.show(context, initialType: BillType.subscription),
      );
    }
    return ListView(
      padding: const EdgeInsets.only(top: AppSpacing.s3, bottom: 120),
      children: [
        for (final bill in bills)
          _SubscriptionCard(bill: bill, baseCurrency: baseCurrency),
        if (suggestions.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.s4),
          Text(
            'مكتشفة تلقائياً',
            style: AppTypography.caption(c.textLight)
                .copyWith(letterSpacing: 1.4, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: AppSpacing.s3),
          for (final item in suggestions)
            _SuggestionCard(item: item, baseCurrency: baseCurrency),
        ],
        const SizedBox(height: AppSpacing.s4),
        OutlinedButton.icon(
          onPressed: () =>
              BillFormSheet.show(context, initialType: BillType.subscription),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.card),
            ),
            side: BorderSide(color: c.border),
          ),
          icon: Icon(Icons.add, color: c.cta),
          label: Text(
            'إضافة اشتراك جديد',
            style: AppTypography.bodyStrong(c.cta),
          ),
        ),
      ],
    );
  }
}

class _SubscriptionCard extends StatelessWidget {
  const _SubscriptionCard({required this.bill, required this.baseCurrency});
  final BillEntity bill;
  final String baseCurrency;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final statusColor = switch (bill.status) {
      BillStatus.active => c.success,
      BillStatus.paused => c.accent,
      BillStatus.cancelled => c.textLight,
    };
    final statusLabel = switch (bill.status) {
      BillStatus.active => 'نشط',
      BillStatus.paused => 'متوقف',
      BillStatus.cancelled => 'ملغي',
    };
    final freqLabel = switch (bill.frequency) {
      BillFrequency.weekly => 'أسبوعي',
      BillFrequency.monthly => 'شهري',
      BillFrequency.yearly => 'سنوي',
      BillFrequency.custom => 'مخصص',
    };
    final daysLeft = bill.nextDueDate.difference(DateTime.now()).inDays;

    final Color dueColor;
    final String dueLabel;
    final IconData dueIcon;

    if (daysLeft < 0) {
      dueColor = c.danger;
      dueLabel = 'متأخر ${daysLeft.abs()} يوم';
      dueIcon = Icons.warning_amber_rounded;
    } else if (daysLeft == 0) {
      dueColor = c.danger;
      dueLabel = 'مستحق اليوم';
      dueIcon = Icons.error_outline_rounded;
    } else if (daysLeft <= 3) {
      dueColor = c.accent;
      dueLabel = 'بعد $daysLeft يوم';
      dueIcon = Icons.event_rounded;
    } else {
      dueColor = c.textLight;
      dueLabel = 'بعد $daysLeft يوم';
      dueIcon = Icons.calendar_month_outlined;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s3),
      child: MaliCard(
        style: MaliSurfaceStyle.floating,
        padding: const EdgeInsets.all(AppSpacing.s4),
        onTap: () => BillDetailsSheet.show(context, bill),
        child: Column(
          children: [
            Row(
              children: [
                BrandMark(name: bill.name, size: 48),
                const SizedBox(width: AppSpacing.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              bill.name,
                              style: AppTypography.bodyStrong(c.textMain),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: statusColor.withValues(alpha: 0.10),
                              borderRadius:
                                  BorderRadius.circular(AppRadius.pill),
                              border: Border.all(
                                  color: statusColor.withValues(alpha: 0.20)),
                            ),
                            child: Text(
                              statusLabel,
                              style: AppTypography.caption(statusColor)
                                  .copyWith(fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                      if (bill.mightBeUnused) ...[
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(Icons.info_outline_rounded,
                                size: 12, color: c.warning),
                            const SizedBox(width: 3),
                            Text(
                              'قد لا تستخدم هذا الاشتراك',
                              style: AppTypography.caption(c.warning),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Icon(dueIcon, size: 13, color: dueColor),
                          const SizedBox(width: 4),
                          Text(
                            '$freqLabel · $dueLabel',
                            style: AppTypography.caption(dueColor),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.s3),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      Formatters.amount(bill.amount),
                      style: AppTypography.bodyStrong(c.textMain),
                    ),
                    Text(
                      Currency.arabicLabel(bill.currency),
                      style: AppTypography.caption(c.textLight),
                    ),
                    if (bill.type == BillType.subscription)
                      Text(
                        '≈ ${Formatters.amount(annualEquivalent(bill))}/سنة',
                        style: AppTypography.caption(c.textLight),
                      ),
                  ],
                ),
              ],
            ),
            if (bill.safeManualPaidAmount > 0) ...[
              const SizedBox(height: AppSpacing.s3),
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: c.success.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  border: Border.all(
                    color: c.success.withValues(alpha: 0.28),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(Icons.payments_outlined, size: 16, color: c.success),
                    const SizedBox(width: 6),
                    Text(
                      'مدفوع يدويًا: ',
                      style: AppTypography.caption(c.textLight),
                    ),
                    Text(
                      '${Formatters.amount(bill.safeManualPaidAmount)} ${Currency.arabicLabel(bill.currency)}',
                      style: AppTypography.caption(c.success).copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _monthsLabel(int n) {
  if (n == 1) return 'شهر';
  if (n == 2) return 'شهرين';
  if (n <= 10) return '$n أشهر';
  return '$n شهراً';
}

class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({required this.item, required this.baseCurrency});
  final dynamic item;
  final String baseCurrency;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s3),
      child: MaliCard(
        style: MaliSurfaceStyle.floating,
        padding: const EdgeInsets.all(AppSpacing.s4),
        onTap: () => BillFormSheet.show(
          context,
          initialType: BillType.subscription,
          initialName: item.name as String,
        ),
        child: Row(
          children: [
            BrandMark(name: item.name as String, size: 48),
            const SizedBox(width: AppSpacing.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name as String,
                    style: AppTypography.bodyStrong(c.textMain),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'تكرر ${_monthsLabel((item.monthsSeen as num).toInt())} · اضغط للتفعيل',
                    style: AppTypography.caption(c.textLight),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.s3),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${Formatters.amount((item.estimatedAmountMoney as Money).toDouble())} ${Currency.arabicLabel(baseCurrency)}/شهر',
                  style: AppTypography.caption(c.textMain).copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: c.cta.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.add, size: 12, color: c.cta),
                      const SizedBox(width: 2),
                      Text(
                        'إضافة',
                        style: AppTypography.caption(c.cta)
                            .copyWith(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Installments Tab ────────────────────────────────────────────────────────

class _InstallmentsTab extends StatelessWidget {
  const _InstallmentsTab({required this.bills});
  final List<BillEntity> bills;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (bills.isEmpty) {
      return _EmptyState(
        icon: AppLucideIcons.repeat,
        title: 'أقساطك، واضحة قبل ميعادها',
        body: 'أضف القسط بالمبلغ والعدد وتاريخ الاستحقاق.',
        actionLabel: 'إضافة قسط',
        onAction: () =>
            BillFormSheet.show(context, initialType: BillType.installment),
      );
    }
    // One cross-bill display total, computed EXACTLY as Money and currency-
    // isolated: an installment in another currency is NEVER folded into this
    // total (no implicit FX). The double conversion happens only at the leaf
    // Text below.
    final displayCode = bills.first.amountMoney.currency;
    final totalRemainingMoney =
        installmentsRemainingTotalMoney(bills, displayCode);
    final activeCount = bills.where((b) => b.remainingInstallments > 0).length;
    final dueSoon = bills.where((b) => b.remainingInstallments > 0).toList()
      ..sort((a, b) => a.nextDueDate.compareTo(b.nextDueDate));
    final nearest = dueSoon.isEmpty ? null : dueSoon.first;
    final currency =
        bills.isEmpty ? 'SAR' : Currency.arabicLabel(bills.first.currency);

    return ListView(
      padding: const EdgeInsets.only(top: AppSpacing.s3, bottom: 120),
      children: [
        if (!totalRemainingMoney.isZero) ...[
          Container(
            padding: const EdgeInsets.all(AppSpacing.s4),
            decoration: BoxDecoration(
              gradient: c.primaryGradient,
              borderRadius: BorderRadius.circular(AppRadius.card),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('إجمالي مديونية الأقساط',
                    style: AppTypography.caption(
                        Colors.white.withValues(alpha: 0.75))),
                const SizedBox(height: 4),
                Text(
                  '${Formatters.amount(totalRemainingMoney.toDouble())} $currency',
                  style: AppTypography.title1(Colors.white)
                      .copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: AppSpacing.s3),
                Row(
                  children: [
                    _DebtStat(label: 'أقساط جارية', value: '$activeCount'),
                    if (nearest != null) ...[
                      const SizedBox(width: AppSpacing.s4),
                      _DebtStat(
                        label: 'أقرب قسط',
                        value:
                            '${Formatters.amount(nearest.amount)} · ${_dueInLabel(nearest.nextDueDate)}',
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.s4),
        ],
        for (final bill in bills) _InstallmentCard(bill: bill),
        const SizedBox(height: AppSpacing.s4),
        OutlinedButton.icon(
          onPressed: () =>
              BillFormSheet.show(context, initialType: BillType.installment),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.card),
            ),
            side: BorderSide(color: c.border),
          ),
          icon: Icon(Icons.add, color: c.cta),
          label: Text(
            'إضافة قسط جديد',
            style: AppTypography.bodyStrong(c.cta),
          ),
        ),
      ],
    );
  }
}

class _DebtStat extends StatelessWidget {
  const _DebtStat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: AppTypography.bodyStrong(Colors.white)
              .copyWith(fontWeight: FontWeight.w700),
        ),
        Text(
          label,
          style: AppTypography.caption(Colors.white.withValues(alpha: 0.75)),
        ),
      ],
    );
  }
}

class _InstallmentCard extends StatelessWidget {
  const _InstallmentCard({required this.bill});
  final BillEntity bill;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final hasProg =
        bill.totalInstallments != null && bill.totalInstallments! > 0;
    final progress = bill.installmentProgress;
    final remaining = bill.remainingInstallments;
    final daysLeft = bill.nextDueDate.difference(DateTime.now()).inDays;
    final currLabel = Currency.arabicLabel(bill.currency);

    final Color dueColor;
    final String dueLabel;
    if (daysLeft < 0) {
      dueColor = c.danger;
      dueLabel = 'متأخر ${daysLeft.abs()} يوم';
    } else if (daysLeft == 0) {
      dueColor = c.danger;
      dueLabel = 'مستحق اليوم';
    } else if (daysLeft <= 3) {
      dueColor = c.accent;
      dueLabel = 'بعد $daysLeft يوم';
    } else {
      dueColor = c.textLight;
      dueLabel = 'بعد $daysLeft يوم';
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s3),
      child: MaliCard(
        style: MaliSurfaceStyle.floating,
        padding: const EdgeInsets.all(AppSpacing.s4),
        onTap: () => BillDetailsSheet.show(context, bill),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                BrandMark(name: bill.lenderName ?? bill.name, size: 44),
                const SizedBox(width: AppSpacing.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        bill.name,
                        style: AppTypography.bodyStrong(c.textMain),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (bill.lenderName != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          bill.lenderName!,
                          style: AppTypography.caption(c.textLight),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.s2),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      Formatters.amount(bill.amount),
                      style: AppTypography.bodyStrong(c.primary),
                    ),
                    Text(
                      '$currLabel / قسط',
                      style: AppTypography.caption(c.textLight),
                    ),
                  ],
                ),
              ],
            ),
            if (hasProg) ...[
              const SizedBox(height: AppSpacing.s4),
              Row(
                children: [
                  Text(
                    '${bill.paidCount ?? 0} من ${bill.totalInstallments} قسط مدفوع',
                    style: AppTypography.caption(c.textLight),
                  ),
                  const Spacer(),
                  Text(
                    'متبقي $remaining قسط',
                    style: AppTypography.caption(c.primary)
                        .copyWith(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.pill),
                child: SizedBox(
                  height: 6,
                  child: LinearProgressIndicator(
                    value: progress,
                    backgroundColor: c.surface2,
                    valueColor: AlwaysStoppedAnimation(
                      progress >= 1.0 ? c.success : c.primary,
                    ),
                  ),
                ),
              ),
            ],
            if (bill.totalPurchaseAmount != null) ...[
              const SizedBox(height: AppSpacing.s3),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: c.bg,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  border: Border.all(color: c.border),
                ),
                child: Row(
                  children: [
                    Text(
                      'القيمة الكلية: ',
                      style: AppTypography.caption(c.textLight),
                    ),
                    Text(
                      '${Formatters.amount(bill.totalPurchaseAmount!)} $currLabel',
                      style: AppTypography.caption(c.textMain).copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (bill.interestRate != null) ...[
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: c.accent.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                        ),
                        child: Text(
                          'فائدة ${(bill.interestRate! * 100).toStringAsFixed(1)}%',
                          style: AppTypography.caption(c.accent)
                              .copyWith(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
            if (bill.safeManualPaidAmount > 0) ...[
              const SizedBox(height: AppSpacing.s3),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: c.success.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  border: Border.all(
                    color: c.success.withValues(alpha: 0.28),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(Icons.payments_outlined, size: 16, color: c.success),
                    const SizedBox(width: 6),
                    Text(
                      'مدفوع يدويًا: ',
                      style: AppTypography.caption(c.textLight),
                    ),
                    Text(
                      '${Formatters.amount(bill.safeManualPaidAmount)} $currLabel',
                      style: AppTypography.caption(c.success).copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.s3),
            Row(
              children: [
                Icon(Icons.calendar_month_outlined, size: 14, color: dueColor),
                const SizedBox(width: 4),
                Text(
                  'القسط القادم: $dueLabel',
                  style: AppTypography.caption(dueColor).copyWith(
                      fontWeight:
                          dueColor == c.danger ? FontWeight.bold : null),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Empty State ─────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.body,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.gutter,
            vertical: AppSpacing.s4,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: c.primary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(26),
                ),
                child: Icon(icon, color: c.primary, size: 34),
              ),
              const SizedBox(height: AppSpacing.s4),
              Text(title,
                  textAlign: TextAlign.center,
                  style: AppTypography.cardTitle(c.textMain)),
              const SizedBox(height: AppSpacing.s2),
              Text(body,
                  textAlign: TextAlign.center,
                  style: AppTypography.callout(c.textLight)),
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: AppSpacing.s4),
                SizedBox(
                  height: 48,
                  child: FilledButton.icon(
                    onPressed: onAction,
                    icon: const Icon(Icons.add),
                    label: Text(actionLabel!),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
