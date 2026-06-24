import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/bill_entity.dart';
import '../../domain/entities/transaction_entity.dart';
import '../cards/brand_mark.dart';
import '../common/premium_loading.dart';
import '../common/app_header.dart';
import '../common/app_screen_scaffold.dart';
import '../common/app_pill_tab_bar.dart';
import '../common/app_empty_state.dart';
import '../common/app_transaction_row.dart';
import '../common/app_button.dart';
import '../subscriptions/bill_form_sheet.dart';
import 'transaction_details_screen.dart';
import 'transactions_providers.dart';

class TransactionsScreen extends ConsumerWidget {
  const TransactionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(transactionsListProvider);
    final billsAsync = ref.watch(billsViewProvider);
    final tab = ref.watch(transactionsPageTabProvider);
    final pendingOnly = ref.watch(transactionsPendingFilterProvider);

    return AppScreenScaffold(
      header: AppHeader(
        title: tab == 0 ? 'العمليات' : 'الفواتير',
        showBack: false,
      ),
      body: async.when(
        loading: () => const PremiumSkeletonPage(cardCount: 6),
        error: (e, _) => Center(child: Text('حدث خطأ: $e')),
        data: (view) {
          final groups = <String, List<TransactionEntity>>{};
          for (final tx in view.transactions) {
            final label = Formatters.dateGroupLabel(tx.occurredAt, context);
            groups.putIfAbsent(label, () => []).add(tx);
          }

          return ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter,
              AppSpacing.s2,
              AppSpacing.gutter,
              120,
            ),
            children: [
              if (tab == 0)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.s4),
                  child: Text(
                    '${view.range.label} · كل التفاصيل تفتح من أسفل الشاشة.',
                    style: AppTypography.callout(context.colors.textLight),
                  ),
                ),
              if (pendingOnly)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.s3),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: context.colors.accent.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                              color: context.colors.accent
                                  .withValues(alpha: 0.30)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(AppLucideIcons.alertTriangle,
                                size: 14, color: context.colors.accent),
                            const SizedBox(width: 6),
                            Text('تصفية: قيد المراجعة',
                                style:
                                    AppTypography.caption(context.colors.accent)
                                        .copyWith(fontWeight: FontWeight.w700)),
                            const SizedBox(width: 8),
                            GestureDetector(
                              onTap: () => ref
                                  .read(transactionsPendingFilterProvider
                                      .notifier)
                                  .state = false,
                              child: Icon(Icons.close,
                                  size: 14, color: context.colors.accent),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              if (!pendingOnly) _DateRangeChips(range: view.range),
              if (!pendingOnly) const SizedBox(height: AppSpacing.s4),
              AppPillTabBar(
                tabs: const ['العمليات', 'الفواتير'],
                selectedIndex: tab,
                onSelected: (value) => ref
                    .read(transactionsPageTabProvider.notifier)
                    .state = value,
              ),
              const SizedBox(height: AppSpacing.s4),
              if (tab == 0) ...[
                // Metrics for transactions
                Container(
                  padding: const EdgeInsets.all(AppSpacing.s4),
                  decoration: BoxDecoration(
                    color: context.colors.surface2,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: _MetricItem(
                          label: 'عمليات',
                          value: '${view.transactions.length}',
                        ),
                      ),
                      Container(
                          width: 1, height: 32, color: context.colors.border),
                      Expanded(
                        child: _MetricItem(
                          label: 'مراجعة',
                          value: '${view.pendingCount}',
                        ),
                      ),
                      Container(
                          width: 1, height: 32, color: context.colors.border),
                      Expanded(
                        child: _MetricItem(
                          label: 'مصروف',
                          value: '${Formatters.integer(view.expenseTotal)} ر',
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.s4),

                const _TransactionSearchField(),
                const SizedBox(height: AppSpacing.s3),
                const _KindFilterChips(),
                const SizedBox(height: AppSpacing.s4),
                if (view.transactions.isEmpty)
                  const AppEmptyState(
                    icon: AppLucideIcons.inbox,
                    title: 'لا توجد عمليات في هذه الفترة',
                    subtitle: 'غيّر الفترة أو أضف رسالة بنك جديدة من زر +.',
                  )
                else
                  for (final entry in groups.entries) ...[
                    _DateHeader(label: entry.key),
                    for (final tx in entry.value)
                      () {
                        final category = view.catalog.byId(tx.categoryId);
                        return AppTransactionRow(
                          title: tx.rawMerchant ?? category?.nameAr ?? 'عملية',
                          amount: tx.amount,
                          currency: Currency.arabicLabel(tx.currency),
                          subtitle: category?.nameAr,
                          categoryIcon: category?.icon,
                          categoryColor: category?.color,
                          isPending: tx.status == TransactionStatus.pending,
                          isAi: tx.source == TransactionSourceEntity.aiParsed,
                          isDebit: tx.type != TransactionTypeEntity.income &&
                              tx.type != TransactionTypeEntity.refund,
                          onTap: () => TransactionDetailsScreen.showSheet(
                            context,
                            tx.id,
                          ),
                        );
                      }(),
                  ],
              ] else
                billsAsync.when(
                  loading: () => const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                  error: (error, _) => Text('حدث خطأ: $error'),
                  data: (bills) => _BillsTab(view: bills),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _MetricItem extends StatelessWidget {
  const _MetricItem({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value,
            style: AppTypography.title2(context.colors.textMain)
                .copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 2),
        Text(label, style: AppTypography.caption(context.colors.textLight)),
      ],
    );
  }
}

class _TransactionSearchField extends ConsumerStatefulWidget {
  const _TransactionSearchField();

  @override
  ConsumerState<_TransactionSearchField> createState() =>
      _TransactionSearchFieldState();
}

class _TransactionSearchFieldState
    extends ConsumerState<_TransactionSearchField> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: ref.read(transactionSearchQueryProvider),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final query = ref.watch(transactionSearchQueryProvider);
    return TextField(
      controller: _controller,
      textInputAction: TextInputAction.search,
      onChanged: (value) =>
          ref.read(transactionSearchQueryProvider.notifier).state = value,
      decoration: InputDecoration(
        hintText: 'ابحث باسم متجر، تصنيف، مبلغ أو عملة',
        prefixIcon: const Icon(Icons.search_rounded),
        suffixIcon: query.isEmpty
            ? null
            : IconButton(
                onPressed: () {
                  _controller.clear();
                  ref.read(transactionSearchQueryProvider.notifier).state = '';
                },
                icon: const Icon(Icons.close_rounded),
              ),
        filled: true,
        fillColor: c.surface2.withValues(alpha: 0.45),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: c.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: c.border.withValues(alpha: 0.6)),
        ),
      ),
    );
  }
}

class _DateRangeChips extends ConsumerWidget {
  const _DateRangeChips({required this.range});

  final TransactionsDateRange range;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final presets = [
      TransactionsDatePreset.thisMonth,
      TransactionsDatePreset.previousMonth,
      TransactionsDatePreset.last30Days,
      TransactionsDatePreset.custom,
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final preset in presets) ...[
            ChoiceChip(
              label: Text(_presetLabel(preset)),
              selected: range.preset == preset,
              selectedColor: c.primary.withValues(alpha: 0.16),
              onSelected: (_) async {
                if (preset == TransactionsDatePreset.custom) {
                  await _showCustomRangeSheet(context, ref, range);
                } else {
                  ref.read(transactionsDateRangeProvider.notifier).state =
                      _rangeForPreset(preset);
                }
              },
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  String _presetLabel(TransactionsDatePreset preset) => switch (preset) {
        TransactionsDatePreset.thisMonth => 'هذا الشهر',
        TransactionsDatePreset.previousMonth => 'الشهر السابق',
        TransactionsDatePreset.last30Days => 'آخر 30 يوم',
        TransactionsDatePreset.custom => 'مخصص',
      };

  TransactionsDateRange _rangeForPreset(TransactionsDatePreset preset) {
    final now = DateTime.now();
    return switch (preset) {
      TransactionsDatePreset.thisMonth => TransactionsDateRange(
          preset: preset,
          from: DateTime(now.year, now.month),
          to: now,
        ),
      TransactionsDatePreset.previousMonth => TransactionsDateRange(
          preset: preset,
          from: DateTime(now.year, now.month - 1),
          to: DateTime(now.year, now.month)
              .subtract(const Duration(seconds: 1)),
        ),
      TransactionsDatePreset.last30Days => TransactionsDateRange(
          preset: preset,
          from: now.subtract(const Duration(days: 30)),
          to: now,
        ),
      TransactionsDatePreset.custom => range,
    };
  }

  Future<void> _showCustomRangeSheet(
    BuildContext context,
    WidgetRef ref,
    TransactionsDateRange current,
  ) async {
    var from = current.from;
    var to = current.to;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          return Padding(
            padding: const EdgeInsets.all(AppSpacing.gutter),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'فترة مخصصة',
                  style: AppTypography.title2(context.colors.textMain),
                ),
                ListTile(
                  title: const Text('من'),
                  subtitle: Text(Formatters.fullDate(from, context)),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: from,
                      firstDate: DateTime(2020),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                    );
                    if (picked != null) setState(() => from = picked);
                  },
                ),
                ListTile(
                  title: const Text('إلى'),
                  subtitle: Text(Formatters.fullDate(to, context)),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: to,
                      firstDate: DateTime(2020),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                    );
                    if (picked != null) setState(() => to = picked);
                  },
                ),
                FilledButton(
                  onPressed: to.isBefore(from)
                      ? null
                      : () {
                          ref
                              .read(transactionsDateRangeProvider.notifier)
                              .state = TransactionsDateRange(
                            preset: TransactionsDatePreset.custom,
                            from: from,
                            to: DateTime(
                              to.year,
                              to.month,
                              to.day,
                              23,
                              59,
                              59,
                            ),
                          );
                          Navigator.of(context).pop();
                        },
                  child: const Text('تطبيق'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _KindFilterChips extends ConsumerWidget {
  const _KindFilterChips();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(transactionKindFilterProvider);
    final items = {
      TransactionKindFilter.all: 'الكل',
      TransactionKindFilter.expenses: 'مصروفات',
      TransactionKindFilter.income: 'دخل',
      TransactionKindFilter.transfers: 'تحويلات',
    };
    return Wrap(
      spacing: 8,
      children: [
        for (final entry in items.entries)
          ChoiceChip(
            label: Text(entry.value),
            selected: filter == entry.key,
            onSelected: (_) => ref
                .read(transactionKindFilterProvider.notifier)
                .state = entry.key,
          ),
      ],
    );
  }
}

class _BillsTab extends StatefulWidget {
  const _BillsTab({required this.view});

  final BillsView view;

  @override
  State<_BillsTab> createState() => _BillsTabState();
}

class _BillsTabState extends State<_BillsTab> {
  BillType _type = BillType.subscription;

  @override
  Widget build(BuildContext context) {
    final bills = widget.view.bills
        .where((bill) => bill.type == _type)
        .toList(growable: false);
    final activeCount = bills.where((bill) => bill.isConfirmed).length;
    final monthlyTotal = bills.fold<double>(
      0,
      (sum, bill) => sum + _monthlyAmount(bill),
    );
    final nextThisWeek = bills.where((bill) {
      final now = DateTime.now();
      final weekEnd = now.add(const Duration(days: 7));
      return !bill.nextDueDate.isBefore(now) &&
          bill.nextDueDate.isBefore(weekEnd);
    }).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppPillTabBar(
          tabs: const ['اشتراكات', 'أقساط'],
          selectedIndex: _type == BillType.subscription ? 0 : 1,
          onSelected: (index) => setState(() {
            _type = index == 0 ? BillType.subscription : BillType.installment;
          }),
        ),
        const SizedBox(height: AppSpacing.s3),
        AppButton(
          onPressed: () => BillFormSheet.show(
            context,
            initialType: _type,
          ),
          icon: Icons.add,
          label: _type == BillType.subscription ? 'إضافة اشتراك' : 'إضافة قسط',
          isPrimary: true,
        ),
        const SizedBox(height: AppSpacing.s4),
        _BillsHero(
          type: _type,
          monthlyTotal: monthlyTotal,
          activeCount: activeCount,
          nextThisWeek: nextThisWeek,
        ),
        const SizedBox(height: AppSpacing.s5),
        _BillExample(type: _type),
        const SizedBox(height: AppSpacing.s4),
        TextButton.icon(
          onPressed: () => _showBillsHelp(context, _type),
          icon: const Icon(Icons.help_outline, size: 18),
          label: const Text('اعرف أكثر عن الفواتير'),
        ),
        const SizedBox(height: AppSpacing.s3),
        if (bills.isEmpty)
          AppEmptyState(
            icon: _type == BillType.subscription
                ? AppLucideIcons.repeat
                : Icons.receipt_long_outlined,
            title: _type == BillType.subscription
                ? 'اشتراكاتك، متابعة تلقائية'
                : 'أقساطك، واضحة كل شهر',
            subtitle: _type == BillType.subscription
                ? 'أضف اشتراكك يدويًا أو خليه يتكشف تلقائيًا من العمليات المتكررة.'
                : 'أضف القسط بتاريخه وتنبيهه عشان يظهر في الفواتير قبل الاستحقاق.',
            primaryLabel:
                _type == BillType.subscription ? 'إضافة اشتراك' : 'إضافة قسط',
            onPrimary: () => BillFormSheet.show(
              context,
              initialType: _type,
            ),
          )
        else
          for (final bill in bills) ...[
            _BillCard(bill: bill),
            const SizedBox(height: AppSpacing.s3),
          ],
        if (_type == BillType.subscription &&
            widget.view.suggestions.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.s4),
          const _DateHeader(label: 'اقتراحات من العمليات المتكررة'),
          for (final suggestion in widget.view.suggestions.take(3)) ...[
            _SuggestionCard(
              suggestion: suggestion,
              onAdd: () => BillFormSheet.show(
                context,
                initialType: BillType.subscription,
                initialName: suggestion.name,
              ),
            ),
            const SizedBox(height: AppSpacing.s3),
          ],
        ],
      ],
    );
  }

  double _monthlyAmount(BillEntity bill) => switch (bill.frequency) {
        BillFrequency.weekly => bill.amount * 4,
        BillFrequency.monthly => bill.amount,
        BillFrequency.yearly => bill.amount / 12,
        BillFrequency.custom => bill.customIntervalDays == null
            ? bill.amount
            : bill.amount * (30 / bill.customIntervalDays!),
      };

  void _showBillsHelp(BuildContext context, BillType type) {
    final c = context.colors;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => Directionality(
        textDirection: TextDirection.rtl,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.gutter),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                type == BillType.subscription
                    ? 'إزاي مالي يتابع الاشتراكات؟'
                    : 'إزاي مالي يتابع الأقساط؟',
                style: AppTypography.title2(c.textMain),
              ),
              const SizedBox(height: AppSpacing.s3),
              Text(
                type == BillType.subscription
                    ? 'مالي يتابع الأنماط المتكررة تلقائياً، وتقدر كمان تضيف اشتراك يدويًا بالمبلغ وتاريخ التجديد والتنبيه.'
                    : 'أضف القسط يدويًا بالمبلغ وتاريخ الاستحقاق والتنبيه. لاحقًا نضيف المتبقي وعدد الأقساط.',
                style: AppTypography.callout(c.textLight),
              ),
              const SizedBox(height: AppSpacing.s4),
            ],
          ),
        ),
      ),
    );
  }
}

class _BillsHero extends StatelessWidget {
  const _BillsHero({
    required this.type,
    required this.monthlyTotal,
    required this.activeCount,
    required this.nextThisWeek,
  });

  final BillType type;
  final double monthlyTotal;
  final int activeCount;
  final int nextThisWeek;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isSubscription = type == BillType.subscription;
    final accent = c.accent;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s5),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [
            Color(0xFF046E9B),
            Color(0xFF034E73),
            Color(0xFF012438),
          ],
        ),
        borderRadius: BorderRadius.circular(AppRadius.cardLg),
        border: Border.all(color: c.accent.withValues(alpha: 0.24)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF034F73).withValues(alpha: 0.22),
            blurRadius: 28,
            offset: const Offset(0, 16),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                isSubscription ? 'الصرف الشهري' : 'الأقساط الشهرية',
                style:
                    AppTypography.callout(Colors.white.withValues(alpha: 0.78)),
              ),
              const Spacer(),
              _HeroCircle(icon: Icons.calendar_month_outlined, color: accent),
              const SizedBox(width: AppSpacing.s2),
              _HeroCircle(icon: Icons.add, color: accent),
            ],
          ),
          const SizedBox(height: AppSpacing.s2),
          Text(
            '${Formatters.integer(monthlyTotal)} ر',
            style: AppTypography.display(Colors.white),
          ),
          const SizedBox(height: AppSpacing.s4),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.s4,
              vertical: AppSpacing.s3,
            ),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(AppRadius.card),
              border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: _HeroMetric(value: '$activeCount', label: 'نشط'),
                ),
                _Divider(color: Colors.white.withValues(alpha: 0.25)),
                Expanded(
                  child: _HeroMetric(
                    value: '${Formatters.integer(monthlyTotal * 12)} ر',
                    label: 'سنويًا',
                  ),
                ),
                if (isSubscription) ...[
                  _Divider(color: Colors.white.withValues(alpha: 0.25)),
                  Expanded(
                    child: _HeroMetric(
                        value: '$nextThisWeek', label: 'هذا الأسبوع'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroCircle extends StatelessWidget {
  const _HeroCircle({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.18),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, color: Colors.white, size: 20),
    );
  }
}

class _HeroMetric extends StatelessWidget {
  const _HeroMetric({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value, style: AppTypography.bodyStrong(Colors.white)),
        const SizedBox(height: 2),
        Text(
          label,
          style: AppTypography.caption(Colors.white.withValues(alpha: 0.72)),
        ),
      ],
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(width: 1, height: 34, color: color);
  }
}

class _BillExample extends StatelessWidget {
  const _BillExample({required this.type});

  final BillType type;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isSubscription = type == BillType.subscription;
    return Column(
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: c.surface2,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Icon(
            isSubscription
                ? AppLucideIcons.repeat
                : Icons.receipt_long_outlined,
            color: c.accent,
            size: 34,
          ),
        ),
        const SizedBox(height: AppSpacing.s3),
        Text(
          isSubscription ? 'اشتراكاتك، متابعة تلقائية' : 'أقساطك، متابعة واضحة',
          textAlign: TextAlign.center,
          style: AppTypography.headline(c.textMain),
        ),
        const SizedBox(height: AppSpacing.s1),
        Text(
          'مثال سريع للشكل بعد الإضافة',
          style: AppTypography.callout(c.textLight),
        ),
        const SizedBox(height: AppSpacing.s4),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Text(
            'مثال',
            style: AppTypography.caption(c.accent)
                .copyWith(letterSpacing: 1.8, fontWeight: FontWeight.w900),
          ),
        ),
        const SizedBox(height: AppSpacing.s2),
        Container(
          padding: const EdgeInsets.all(AppSpacing.s4),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(AppRadius.card),
            boxShadow: [
              BoxShadow(
                color: c.primary.withValues(alpha: 0.08),
                blurRadius: 24,
                offset: const Offset(0, 14),
              ),
            ],
          ),
          child: isSubscription
              ? Row(
                  children: [
                    const BrandMark(name: 'Netflix', size: 50),
                    const SizedBox(width: AppSpacing.s3),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Netflix',
                              style: AppTypography.bodyStrong(c.textMain)),
                          Text('يتجدد بعد 3 أيام',
                              style: AppTypography.caption(c.textLight)),
                        ],
                      ),
                    ),
                    Text('49 ر / شهر',
                        style: AppTypography.bodyStrong(c.textMain)),
                  ],
                )
              : Row(
                  children: [
                    const BrandMark(name: 'ValU', size: 50),
                    const SizedBox(width: AppSpacing.s3),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('ValU',
                              style: AppTypography.bodyStrong(c.textMain)),
                          const SizedBox(height: AppSpacing.s2),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(AppRadius.pill),
                            child: LinearProgressIndicator(
                              value: 3 / 12,
                              minHeight: 6,
                              backgroundColor: c.surface2,
                              valueColor: AlwaysStoppedAnimation(c.accent),
                            ),
                          ),
                          const SizedBox(height: AppSpacing.s1),
                          Text('3 من 12 مدفوعة',
                              style: AppTypography.caption(c.textLight)),
                        ],
                      ),
                    ),
                    Text('1,500 ر / شهر',
                        style: AppTypography.bodyStrong(c.textMain)),
                  ],
                ),
        ),
      ],
    );
  }
}

class _BillCard extends StatelessWidget {
  const _BillCard({required this.bill});

  final BillEntity bill;

  int get _cycleDays => switch (bill.frequency) {
        BillFrequency.weekly => 7,
        BillFrequency.monthly => 30,
        BillFrequency.yearly => 365,
        BillFrequency.custom => bill.customIntervalDays ?? 30,
      };

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final daysLeft = bill.nextDueDate.difference(DateTime.now()).inDays;
    final cycle = _cycleDays;
    final progress = ((cycle - daysLeft) / cycle).clamp(0.0, 1.0);
    final isSoon = daysLeft <= 3;
    final dueColor = isSoon ? c.accent : c.success;
    final typeLabel = bill.type == BillType.subscription ? 'اشتراك' : 'قسط';

    String dueLabel() {
      if (daysLeft < 0) return 'مستحق الآن';
      if (daysLeft == 0) return 'يُجدّد اليوم';
      if (daysLeft == 1) return 'يُجدّد غدًا';
      return 'باقي $daysLeft يوم';
    }

    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.cardLg),
      onTap: null,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.s5),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topRight,
            end: Alignment.bottomLeft,
            colors: [
              c.surface,
              c.primary.withValues(alpha: isDark ? 0.10 : 0.05),
            ],
          ),
          borderRadius: BorderRadius.circular(AppRadius.cardLg),
          border: Border.all(color: c.border),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.22 : 0.05),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: c.surface2.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: c.border),
                  ),
                  child: BrandMark(name: bill.name, size: 44),
                ),
                const SizedBox(width: AppSpacing.s4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        bill.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.title2(c.textMain)
                            .copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          _Tag(text: typeLabel, color: c.primary),
                          const SizedBox(width: 6),
                          _Tag(
                            text: _frequencyLabel(bill.frequency),
                            color: c.textLight,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (bill.reminderOn)
                  Icon(Icons.notifications_active_rounded,
                      size: 18, color: c.accent),
              ],
            ),
            const SizedBox(height: AppSpacing.s4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  Formatters.amount(bill.amount),
                  style: AppTypography.amountHero(c.textMain),
                ),
                const SizedBox(width: 6),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    Currency.arabicLabel(bill.currency),
                    style: AppTypography.subhead(c.textLight),
                  ),
                ),
                const Spacer(),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: dueColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    border: Border.all(color: dueColor.withValues(alpha: 0.28)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.schedule_rounded, size: 13, color: dueColor),
                      const SizedBox(width: 4),
                      Text(
                        dueLabel(),
                        style: AppTypography.caption(dueColor)
                            .copyWith(fontWeight: FontWeight.w800),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.s4),
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.pill),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 7,
                backgroundColor: c.surface2,
                valueColor: AlwaysStoppedAnimation(dueColor),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'التجديد القادم · ${Formatters.fullDate(bill.nextDueDate, context)}',
              style: AppTypography.caption(c.textLight),
            ),
          ],
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Text(
        text,
        style:
            AppTypography.caption(color).copyWith(fontWeight: FontWeight.w800),
      ),
    );
  }
}

class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({
    required this.suggestion,
    required this.onAdd,
  });

  final BillSuggestion suggestion;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.card),
      onTap: onAdd,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.s4),
        decoration: BoxDecoration(
          color: c.accent.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: c.accent.withValues(alpha: 0.24)),
        ),
        child: Row(
          children: [
            BrandMark(name: suggestion.name, size: 42),
            const SizedBox(width: AppSpacing.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    suggestion.name,
                    style: AppTypography.bodyStrong(c.textMain),
                  ),
                  Text(
                    'تكرر ${suggestion.monthsSeen} أشهر · اضغط للإضافة',
                    style: AppTypography.caption(c.textLight),
                  ),
                ],
              ),
            ),
            Text(
              '${Formatters.amount(suggestion.averageAmount)} ر/شهر',
              style: AppTypography.caption(c.accent),
            ),
          ],
        ),
      ),
    );
  }
}

class _DateHeader extends StatelessWidget {
  const _DateHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.s4, bottom: AppSpacing.s2),
      child: Row(
        children: [
          Text(
            label,
            style: AppTypography.subhead(c.primary)
                .copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Container(
              height: 1,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    c.primary.withValues(alpha: 0.25),
                    c.primary.withValues(alpha: 0.0),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _frequencyLabel(BillFrequency frequency) => switch (frequency) {
      BillFrequency.weekly => 'أسبوعي',
      BillFrequency.monthly => 'شهري',
      BillFrequency.yearly => 'سنوي',
      BillFrequency.custom => 'مخصص',
    };
