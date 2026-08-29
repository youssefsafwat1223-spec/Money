import 'package:flutter/material.dart';
import '../../domain/finance/money_format.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/di/app_providers.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/calm_page_header.dart';
import '../../core/theme/widgets/mali_card.dart';
import '../../core/theme/widgets/mali_glass.dart';
import '../common/app_pill_tab_bar.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/formatters.dart';
import '../../domain/finance/money.dart';
import '../../domain/entities/bill_entity.dart';
import '../../domain/finance/bill_metrics.dart';
import '../common/app_avatar.dart';
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
    // UX-024 — the same account the list was filtered by, not a second guess.
    final scopeAccount = ref.watch(billsScopeAccountProvider).valueOrNull;

    return billsAsync.when(
      skipLoadingOnReload: true,
      loading: () => Scaffold(
        appBar: Navigator.of(context).canPop()
            ? AppBar(title: const Text('الاشتراكات والفواتير'))
            : null,
        body: const SkeletonList(rows: 4),
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
        final monthlyTotal = subscriptionMonthlyTotalMoney(subs, baseCur);
        // UX-023 — the installment obligation as its OWN line, so the header's
        // metric and the counters beneath it describe the same world.
        //
        // `monthlyEquivalentsTotalMoney` is deliberately filter-free ("the
        // caller decides"), which is precisely the footgun that produced F-027
        // when a caller forgot. The active filter is therefore explicit here
        // rather than assumed.
        final installmentMonthly = monthlyEquivalentsTotalMoney(
          insts.where((b) => b.status == BillStatus.active),
          baseCur,
        );

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
                            installmentMonthly: installmentMonthly,
                            subsCount: subs.length,
                            instsCount: insts.length,
                            currency: Currency.arabicLabel(baseCur),
                            scopeAccountName: scopeAccount?.name,
                          ),
                        ],
                      ),
                    ),
                    SliverPersistentHeader(
                      pinned: true,
                      delegate: _TabBarDelegate(
                        // iOS 26 style: floating glass capsules, no bar box.
                        child: MeltSlice(
                          height: 64.0,
                          child: Container(
                            height: 64.0,
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.gutter,
                            ),
                            alignment: Alignment.center,
                            child: Builder(
                              builder: (context) {
                                final controller =
                                    DefaultTabController.of(context);
                                return AnimatedBuilder(
                                  animation: controller,
                                  builder: (context, _) => AppPillTabBar(
                                    tabs: [
                                      'الاشتراكات (${subs.length})',
                                      'الأقساط (${insts.length})',
                                    ],
                                    selectedIndex: controller.index,
                                    onSelected: controller.animateTo,
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
                  ];
                },
                // من غير padding هنا: الذوبان جوّه كل تبويب لازم يبقى كامل
                // العرض، والمسافات الجانبية جوّه القوايم نفسها.
                body: TabBarView(
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
    required this.installmentMonthly,
    required this.scopeAccountName,
  });

  /// R-8 — exact Money. The yearly metric is `monthly × 12`, and multiplying a
  /// double by twelve compounds whatever the conversion already lost.
  final Money monthly;
  final int subsCount;
  final int instsCount;
  final String currency;
  final Money installmentMonthly;

  /// UX-024 — the account the list is filtered to, or null when nothing scopes
  /// it (no accounts yet), in which case there is nothing honest to claim.
  final String? scopeAccountName;

  @override
  Widget build(BuildContext context) {
    return CalmPageHeader(
      // شرائح متعددة: الأزرق ميمتدّش تحت (هيغطّي المحتوى) — الذوبان جوّه.
      meltOverflow: 0,
      title: 'الاشتراكات والفواتير',
      // UX-023 — name the metric for what it measures.
      //
      // It read «إجمالي الصرف الشهري» — "total monthly spend" — while the
      // calculation is `subscriptionMonthlyTotalMoney(subs, …)`: ACTIVE
      // SUBSCRIPTIONS ONLY. With الراجحي selected it showed 399.00 while the
      // counters directly beneath it read «1 اشتراكات نشطة · 1 أقساط جارية»,
      // so the real monthly commitment was 399.00 + 458.25 = 857.25.
      //
      // The exclusion is deliberate and documented (MALI-064n) — a finite
      // installment is genuinely not an open-ended subscription. The defect was
      // the LABEL claiming to be a total, which the QA classed as the same shape
      // as UX-022: correct mathematics, a label that does not describe them.
      // The calculation is untouched.
      // UX-024 — the screen is correctly scoped to one account and said so
      // nowhere, so «الاشتراكات (1)» read as "you have one subscription"
      // rather than "one on this account". Same family as UX-007.
      subtitle: scopeAccountName == null
          ? 'الاشتراكات الشهرية'
          : 'الاشتراكات الشهرية · $scopeAccountName',
      leading: Navigator.of(context).canPop()
          ? const BackButton(color: Colors.white)
          : null,
      trailing: _AddButton(
        onTap: () => BillFormSheet.show(
          context,
          initialType: BillType.subscription,
        ),
      ),
      amount: formatMoney(monthly),
      currency: currency,
      metrics: [
        CalmMetric(label: 'اشتراكات نشطة', value: '$subsCount'),
        CalmMetric(label: 'أقساط جارية', value: '$instsCount'),
        // The figure the header used to omit: what the installments actually
        // commit per month. Shown only when there is one, so the strip does not
        // carry a permanent «0.00».
        if (installmentMonthly.minorUnits > 0)
          CalmMetric(
            label: 'التزام الأقساط شهرياً',
            value: formatMoney(installmentMonthly),
          ),
        CalmMetric(
          label: 'سنوياً المجموع',
          value: formatMoney(
            Money(monthly.minorUnits * 12, monthly.currency),
          ),
        ),
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
          child: Icon(AppLucideIcons.plus, color: Colors.white, size: 24),
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
    return MeltTail(
        startAt: 64,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter, AppSpacing.s3, AppSpacing.gutter, 120),
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
              onPressed: () => BillFormSheet.show(context,
                  initialType: BillType.subscription),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.card),
                ),
                side: BorderSide(color: c.border),
              ),
              icon: Icon(AppLucideIcons.plus, color: c.cta),
              label: Text(
                'إضافة اشتراك جديد',
                style: AppTypography.bodyStrong(c.cta),
              ),
            ),
          ],
        ));
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
      dueIcon = AppLucideIcons.alertTriangle;
    } else if (daysLeft == 0) {
      dueColor = c.danger;
      dueLabel = 'مستحق اليوم';
      dueIcon = AppLucideIcons.alertCircle;
    } else if (daysLeft <= 3) {
      dueColor = c.accent;
      dueLabel = 'بعد $daysLeft يوم';
      dueIcon = AppLucideIcons.calendarClock;
    } else {
      dueColor = c.textLight;
      dueLabel = 'بعد $daysLeft يوم';
      dueIcon = AppLucideIcons.calendarDays;
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
                AppAvatar.brand(name: bill.name),
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
                            Icon(AppLucideIcons.info,
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
                    Icon(AppLucideIcons.banknote, size: 16, color: c.success),
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
            AppAvatar.brand(name: item.name as String),
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
                      Icon(AppLucideIcons.plus, size: 12, color: c.cta),
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

    return MeltTail(
        startAt: 64,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter, AppSpacing.s3, AppSpacing.gutter, 120),
          children: [
            if (!totalRemainingMoney.isZero) ...[
              // كارت معلومات هادي (كان تدرّج أزرق قديم) — الرقم بالخط الأسود
              // على سطح عائم، زي باقي كروت النظام.
              MaliCard(
                style: MaliSurfaceStyle.floating,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('إجمالي مديونية الأقساط',
                        style: AppTypography.caption(c.textLight)),
                    const SizedBox(height: 4),
                    Text(
                      '${Formatters.amount(totalRemainingMoney.toDouble())} $currency',
                      style: AppTypography.amountMedium(c.textMain),
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
              onPressed: () => BillFormSheet.show(context,
                  initialType: BillType.installment),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.card),
                ),
                side: BorderSide(color: c.border),
              ),
              icon: Icon(AppLucideIcons.plus, color: c.cta),
              label: Text(
                'إضافة قسط جديد',
                style: AppTypography.bodyStrong(c.cta),
              ),
            ),
          ],
        ));
  }
}

class _DebtStat extends StatelessWidget {
  const _DebtStat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: AppTypography.bodyStrong(c.textMain)
              .copyWith(fontWeight: FontWeight.w700),
        ),
        Text(
          label,
          style: AppTypography.caption(c.textLight),
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
                AppAvatar.brand(name: bill.lenderName ?? bill.name),
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
                    Icon(AppLucideIcons.banknote, size: 16, color: c.success),
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
                Icon(AppLucideIcons.calendarDays, size: 14, color: dueColor),
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
                    icon: const Icon(AppLucideIcons.plus),
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
