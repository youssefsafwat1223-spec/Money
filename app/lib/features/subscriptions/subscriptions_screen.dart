import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/di/app_providers.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/bill_entity.dart';
import '../cards/brand_mark.dart';
import '../common/premium_loading.dart';
import 'bill_form_sheet.dart';
import 'subscriptions_providers.dart';

class SubscriptionsScreen extends ConsumerWidget {
  const SubscriptionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final billsAsync = ref.watch(savedBillsProvider);
    final suggestionsAsync = ref.watch(subscriptionsProvider);
    final baseCur = ref.watch(baseCurrencyProvider).valueOrNull ?? 'SAR';

    return billsAsync.when(
      loading: () => Scaffold(
        appBar: Navigator.of(context).canPop()
            ? AppBar(title: const Text('الاشتراكات والفواتير'))
            : null,
        body: const PremiumSkeletonPage(cardCount: 4),
      ),
      error: (e, _) => Scaffold(
        appBar: Navigator.of(context).canPop()
            ? AppBar(title: const Text('الاشتراكات والفواتير'))
            : null,
        body: Center(child: Text('حدث خطأ: $e')),
      ),
      data: (bills) {
        final subs = bills.where((b) => b.type == BillType.subscription).toList();
        final insts = bills.where((b) => b.type == BillType.installment).toList();
        final suggestions = suggestionsAsync.valueOrNull ?? [];
        // active subscriptions monthly total
        final monthlyTotal = subs
            .where((b) => b.status == BillStatus.active)
            .fold<double>(0, (s, b) => s + b.amount);

        return DefaultTabController(
          length: 2,
          child: Scaffold(
            body: ListView(
              padding: EdgeInsets.zero,
              children: [
                _BillsHeader(
                  monthly: monthlyTotal,
                  subsCount: subs.length,
                  instsCount: insts.length,
                  currency: Currency.arabicLabel(baseCur),
                ),
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.gutter),
                  child: Column(
                    children: [
                      Container(
                        height: 48,
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: context.colors.surface2,
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                        ),
                        child: TabBar(
                          indicatorSize: TabBarIndicatorSize.tab,
                          dividerColor: Colors.transparent,
                          labelColor:
                              Theme.of(context).brightness == Brightness.dark
                                  ? context.colors.accent
                                  : Colors.white,
                          unselectedLabelColor: context.colors.textLight,
                          indicator: BoxDecoration(
                            color:
                                Theme.of(context).brightness == Brightness.dark
                                    ? context.colors.accent.withValues(alpha: 0.22)
                                    : context.colors.primary,
                            borderRadius: BorderRadius.circular(AppRadius.pill),
                          ),
                          tabs: [
                            Tab(text: 'الاشتراكات (${subs.length})'),
                            Tab(text: 'الأقساط (${insts.length})'),
                          ],
                        ),
                      ),
                      const SizedBox(height: AppSpacing.s4),
                      SizedBox(
                        height: _tabHeight(subs, insts, suggestions),
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
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  double _tabHeight(List<BillEntity> subs, List<BillEntity> insts, List<dynamic> suggestions) {
    final subsItems = subs.length + suggestions.length;
    final instsItems = insts.length;
    final maxItems = subsItems > instsItems ? subsItems : instsItems;
    if (maxItems == 0) return 340;
    return (maxItems * 90.0 + 120).clamp(340, 900);
  }
}

// ─── Header ──────────────────────────────────────────────────────────────────

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
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter, 56, AppSpacing.gutter, AppSpacing.s6,
      ),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF046E9B), Color(0xFF034E73), Color(0xFF012438)],
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
        ),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(32)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF034F73).withValues(alpha: 0.25),
            blurRadius: 26,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (Navigator.of(context).canPop()) ...[
                const BackButton(color: Colors.white),
                const SizedBox(width: AppSpacing.s2),
              ],
              Expanded(
                child: Text('الاشتراكات والفواتير',
                    style: AppTypography.title1(Colors.white)
                        .copyWith(fontWeight: FontWeight.bold)),
              ),
              _AddButton(
                onTap: () => BillFormSheet.show(context, initialType: BillType.subscription),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s5),
          Text('الصرف الشهري النشط', style: AppTypography.subhead(Colors.white70)),
          const SizedBox(height: AppSpacing.s2),
          Text('${Formatters.amount(monthly)} $currency',
              style: AppTypography.amountHero(Colors.white)),
          const SizedBox(height: AppSpacing.s4),
          Container(
            padding: const EdgeInsets.all(AppSpacing.s4),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(AppRadius.card),
              border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
            ),
            child: Row(
              children: [
                _HeaderMetric(label: 'اشتراكات', value: '$subsCount'),
                const _Divider(),
                _HeaderMetric(label: 'أقساط', value: '$instsCount'),
                const _Divider(),
                _HeaderMetric(
                  label: 'سنوياً',
                  value: '${Formatters.amount(monthly * 12)} $currency',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AddButton extends StatelessWidget {
  const _AddButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.18),
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.add, color: Colors.white, size: 22),
      ),
    );
  }
}

class _HeaderMetric extends StatelessWidget {
  const _HeaderMetric({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(value, textAlign: TextAlign.center, style: AppTypography.bodyStrong(Colors.white)),
          const SizedBox(height: 4),
          Text(label, style: AppTypography.caption(Colors.white70)),
        ],
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();
  @override
  Widget build(BuildContext context) => Container(
    width: 1, height: 42, color: Colors.white.withValues(alpha: 0.20),
  );
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
        onAction: () => BillFormSheet.show(context, initialType: BillType.subscription),
      );
    }
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        for (final bill in bills)
          _SubscriptionCard(bill: bill, baseCurrency: baseCurrency),
        if (suggestions.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.s4),
          Text(
            'مكتشفة تلقائياً',
            style: AppTypography.caption(c.textLight)
                .copyWith(letterSpacing: 1.4, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: AppSpacing.s3),
          for (final item in suggestions)
            _SuggestionCard(item: item, baseCurrency: baseCurrency),
        ],
        const SizedBox(height: AppSpacing.s4),
        OutlinedButton.icon(
          onPressed: () => BillFormSheet.show(context, initialType: BillType.subscription),
          icon: const Icon(Icons.add),
          label: const Text('إضافة اشتراك'),
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
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.card),
      onTap: () => BillFormSheet.show(context, bill: bill),
      child: Container(
        margin: const EdgeInsets.only(bottom: AppSpacing.s3),
        padding: const EdgeInsets.all(AppSpacing.s4),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: c.border),
        ),
        child: Row(
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
                        child: Text(bill.name, style: AppTypography.bodyStrong(c.textMain)),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: statusColor.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                        ),
                        child: Text(statusLabel,
                            style: AppTypography.caption(statusColor)
                                .copyWith(fontWeight: FontWeight.w800)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$freqLabel · ${daysLeft <= 0 ? 'مستحق اليوم' : 'بعد $daysLeft يوم'}',
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
                  Formatters.amount(bill.amount),
                  style: AppTypography.bodyStrong(c.textMain),
                ),
                Text(
                  Currency.arabicLabel(bill.currency),
                  style: AppTypography.caption(c.textLight),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({required this.item, required this.baseCurrency});
  final dynamic item;
  final String baseCurrency;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.card),
      onTap: () => BillFormSheet.show(
        context,
        initialType: BillType.subscription,
        initialName: item.name as String,
      ),
      child: Container(
        margin: const EdgeInsets.only(bottom: AppSpacing.s3),
        padding: const EdgeInsets.all(AppSpacing.s4),
        decoration: BoxDecoration(
          color: c.surface.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: c.border.withValues(alpha: 0.5), style: BorderStyle.solid),
        ),
        child: Row(
          children: [
            BrandMark(name: item.name as String, size: 48),
            const SizedBox(width: AppSpacing.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.name as String, style: AppTypography.bodyStrong(c.textMain)),
                  Text(
                    'تكرر ${item.monthsSeen} أشهر · اضغط للإضافة',
                    style: AppTypography.caption(c.textLight),
                  ),
                ],
              ),
            ),
            Text(
              '${Formatters.amount(item.averageAmount as double)} ${Currency.arabicLabel(baseCurrency)}/شهر',
              style: AppTypography.caption(c.textLight),
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
    if (bills.isEmpty) {
      return _EmptyState(
        icon: AppLucideIcons.repeat,
        title: 'أقساطك، واضحة قبل ميعادها',
        body: 'أضف القسط بالمبلغ والعدد وتاريخ الاستحقاق.',
        actionLabel: 'إضافة قسط',
        onAction: () => BillFormSheet.show(context, initialType: BillType.installment),
      );
    }
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        for (final bill in bills) _InstallmentCard(bill: bill),
        const SizedBox(height: AppSpacing.s4),
        OutlinedButton.icon(
          onPressed: () => BillFormSheet.show(context, initialType: BillType.installment),
          icon: const Icon(Icons.add),
          label: const Text('إضافة قسط'),
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
    final hasProg = bill.totalInstallments != null && bill.totalInstallments! > 0;
    final progress = bill.installmentProgress;
    final remaining = bill.remainingInstallments;
    final daysLeft = bill.nextDueDate.difference(DateTime.now()).inDays;
    final currLabel = Currency.arabicLabel(bill.currency);

    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.card),
      onTap: () => BillFormSheet.show(context, bill: bill),
      child: Container(
        margin: const EdgeInsets.only(bottom: AppSpacing.s3),
        padding: const EdgeInsets.all(AppSpacing.s4),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: c.border),
        ),
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
                      Text(bill.name, style: AppTypography.bodyStrong(c.textMain)),
                      if (bill.lenderName != null)
                        Text(bill.lenderName!, style: AppTypography.caption(c.textLight)),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(Formatters.amount(bill.amount),
                        style: AppTypography.bodyStrong(c.primary)),
                    Text('$currLabel / قسط', style: AppTypography.caption(c.textLight)),
                  ],
                ),
              ],
            ),
            if (hasProg) ...[
              const SizedBox(height: AppSpacing.s3),
              Row(
                children: [
                  Text(
                    '${bill.paidCount ?? 0} من ${bill.totalInstallments} قسط',
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
              const SizedBox(height: AppSpacing.s2),
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.pill),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 8,
                  backgroundColor: c.surface2,
                  valueColor: AlwaysStoppedAnimation(
                    progress >= 1.0 ? c.success : c.primary,
                  ),
                ),
              ),
            ],
            if (bill.totalPurchaseAmount != null) ...[
              const SizedBox(height: AppSpacing.s2),
              Row(
                children: [
                  Text('القيمة الكلية: ', style: AppTypography.caption(c.textLight)),
                  Text(
                    '${Formatters.amount(bill.totalPurchaseAmount!)} $currLabel',
                    style: AppTypography.caption(c.textMain)
                        .copyWith(fontWeight: FontWeight.bold),
                  ),
                  if (bill.interestRate != null) ...[
                    const SizedBox(width: 8),
                    Text(
                      '· فائدة ${(bill.interestRate! * 100).toStringAsFixed(1)}%',
                      style: AppTypography.caption(c.accent),
                    ),
                  ],
                ],
              ),
            ],
            const SizedBox(height: AppSpacing.s2),
            Row(
              children: [
                Icon(Icons.calendar_month_outlined, size: 14, color: c.textLight),
                const SizedBox(width: 4),
                Text(
                  'القسط القادم: ${daysLeft <= 0 ? 'مستحق اليوم' : 'بعد $daysLeft يوم'}',
                  style: AppTypography.caption(daysLeft <= 3 ? c.accent : c.textLight),
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              color: c.primary.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(26),
            ),
            child: Icon(icon, color: c.primary, size: 34),
          ),
          const SizedBox(height: AppSpacing.s4),
          Text(title,
              textAlign: TextAlign.center,
              style: AppTypography.title2(c.textMain).copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: AppSpacing.s2),
          Text(body, textAlign: TextAlign.center, style: AppTypography.callout(c.textLight)),
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
    );
  }
}
