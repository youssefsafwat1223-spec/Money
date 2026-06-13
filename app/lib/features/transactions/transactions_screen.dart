import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/bill_entity.dart';
import '../../domain/entities/transaction_entity.dart';
import '../cards/brand_mark.dart';
import '../common/premium_loading.dart';
import '../common/section_hero_header.dart';
import '../common/widgets.dart';
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

    return async.when(
      loading: () => const PremiumSkeletonPage(cardCount: 6),
      error: (e, _) => Center(child: Text('حدث خطأ: $e')),
      data: (view) {
        final groups = <String, List<TransactionEntity>>{};
        for (final tx in view.transactions) {
          final label = Formatters.dateGroupLabel(tx.occurredAt, context);
          groups.putIfAbsent(label, () => []).add(tx);
        }

        return ListView(
          padding: EdgeInsets.zero,
          children: [
            SectionHeroHeader(
              title: tab == 0 ? 'العمليات' : 'الفواتير',
              subtitle:
                  '${view.range.label} · كل التفاصيل تفتح من أسفل الشاشة.',
              metrics: [
                SectionHeroMetric(
                  value: '${view.transactions.length}',
                  label: 'عمليات',
                ),
                SectionHeroMetric(
                  value: '${view.pendingCount}',
                  label: 'مراجعة',
                ),
                SectionHeroMetric(
                  value: '${Formatters.integer(view.expenseTotal)} ر',
                  label: 'مصروف',
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.gutter,
                AppSpacing.s4,
                AppSpacing.gutter,
                120,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _DateRangeChips(range: view.range),
                  const SizedBox(height: AppSpacing.s3),
                  _MainSegmented(
                    value: tab,
                    labels: const ['العمليات', 'الفواتير'],
                    onChanged: (value) => ref
                        .read(transactionsPageTabProvider.notifier)
                        .state = value,
                  ),
                  const SizedBox(height: AppSpacing.s3),
                  if (tab == 0) ...[
                    const _TransactionSearchField(),
                    const SizedBox(height: AppSpacing.s3),
                    const _KindFilterChips(),
                    const SizedBox(height: AppSpacing.s3),
                    if (view.transactions.isEmpty)
                      const _EmptyState(
                        icon: AppLucideIcons.inbox,
                        title: 'لا توجد عمليات في هذه الفترة',
                        body: 'غيّر الفترة أو أضف رسالة بنك جديدة من زر +.',
                      )
                    else
                      for (final entry in groups.entries) ...[
                        _DateHeader(label: entry.key),
                        for (final tx in entry.value)
                          TransactionRow(
                            transaction: tx,
                            category: view.catalog.byId(tx.categoryId),
                            onTap: () => TransactionDetailsScreen.showSheet(
                              context,
                              tx.id,
                            ),
                          ),
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
              ),
            ),
          ],
        );
      },
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
      return !bill.nextDueDate.isBefore(now) && bill.nextDueDate.isBefore(weekEnd);
    }).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BillsTypeSegmented(
          value: _type,
          onChanged: (value) => setState(() => _type = value),
        ),
        const SizedBox(height: AppSpacing.s3),
        _BillsHero(
          type: _type,
          monthlyTotal: monthlyTotal,
          activeCount: activeCount,
          nextThisWeek: nextThisWeek,
        ),
        const SizedBox(height: AppSpacing.s5),
        _BillExample(type: _type),
        const SizedBox(height: AppSpacing.s4),
        FilledButton.icon(
          onPressed: () => BillFormSheet.show(context, initialType: _type),
          icon: const Icon(Icons.add),
          label: Text(_type == BillType.subscription
              ? 'إضافة اشتراك'
              : 'إضافة قسط'),
        ),
        const SizedBox(height: AppSpacing.s3),
        TextButton.icon(
          onPressed: () => _showBillsHelp(context, _type),
          icon: const Icon(Icons.help_outline, size: 18),
          label: const Text('اعرف أكثر عن الفواتير'),
        ),
        const SizedBox(height: AppSpacing.s3),
        if (bills.isEmpty)
          _EmptyState(
            icon: _type == BillType.subscription
                ? AppLucideIcons.repeat
                : Icons.receipt_long_outlined,
            title: _type == BillType.subscription
                ? 'اشتراكاتك، متابعة تلقائية'
                : 'أقساطك، واضحة كل شهر',
            body: _type == BillType.subscription
                ? 'أضف Netflix أو Spotify أو أي خدمة، ومالي يذكرك قبل التجديد.'
                : 'أضف ValU أو Tamara أو أي قسط يدويًا، وتابع المتبقي بسهولة.',
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
            _SuggestionCard(suggestion: suggestion),
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
                    ? 'ضيف الخدمة والمبلغ وميعاد التجديد. لو مالي لاحظ عملية متكررة، هيقترحها عليك كاشتراك قابل للحفظ.'
                    : 'ضيف القسط وقيمة الدفعة والتكرار وميعاد الاستحقاق. كل التفاصيل تفضل في Bottom Sheet من غير تنقل مزعج.',
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

class _BillsTypeSegmented extends StatelessWidget {
  const _BillsTypeSegmented({required this.value, required this.onChanged});

  final BillType value;
  final ValueChanged<BillType> onChanged;

  @override
  Widget build(BuildContext context) {
    return _MainSegmented(
      value: value == BillType.subscription ? 0 : 1,
      labels: const ['اشتراكات', 'أقساط'],
      onChanged: (index) => onChanged(
        index == 0 ? BillType.subscription : BillType.installment,
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
    final isSubscription = type == BillType.subscription;
    final accent = isSubscription ? const Color(0xFF0EA5B8) : const Color(0xFF6D5DFB);
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s5),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [
            accent,
            isSubscription ? const Color(0xFF12C6D4) : const Color(0xFF7C6DFF),
          ],
        ),
        borderRadius: BorderRadius.circular(AppRadius.cardLg),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.24),
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
                style: AppTypography.callout(Colors.white.withValues(alpha: 0.78)),
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
                    child: _HeroMetric(value: '$nextThisWeek', label: 'هذا الأسبوع'),
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
            isSubscription ? AppLucideIcons.repeat : Icons.receipt_long_outlined,
            color: isSubscription ? const Color(0xFF0EA5B8) : const Color(0xFF6D5DFB),
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
            style: AppTypography.caption(
              isSubscription ? const Color(0xFF0EA5B8) : const Color(0xFF6D5DFB),
            ).copyWith(letterSpacing: 1.8, fontWeight: FontWeight.w900),
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
                          Text('Netflix', style: AppTypography.bodyStrong(c.textMain)),
                          Text('يتجدد بعد 3 أيام', style: AppTypography.caption(c.textLight)),
                        ],
                      ),
                    ),
                    Text('49 ر / شهر', style: AppTypography.bodyStrong(c.textMain)),
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
                          Text('ValU', style: AppTypography.bodyStrong(c.textMain)),
                          const SizedBox(height: AppSpacing.s2),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(AppRadius.pill),
                            child: LinearProgressIndicator(
                              value: 3 / 12,
                              minHeight: 6,
                              backgroundColor: c.surface2,
                              valueColor: const AlwaysStoppedAnimation(
                                Color(0xFF6D5DFB),
                              ),
                            ),
                          ),
                          const SizedBox(height: AppSpacing.s1),
                          Text('3 من 12 مدفوعة', style: AppTypography.caption(c.textLight)),
                        ],
                      ),
                    ),
                    Text('1,500 ر / شهر', style: AppTypography.bodyStrong(c.textMain)),
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

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.card),
      onTap: () => BillFormSheet.show(context, bill: bill),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.s4),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: c.border),
        ),
        child: Row(
          children: [
            BrandMark(name: bill.name, size: 46),
            const SizedBox(width: AppSpacing.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(bill.name, style: AppTypography.bodyStrong(c.textMain)),
                  Text(
                    '${bill.type == BillType.subscription ? 'اشتراك' : 'قسط'} · ${_frequencyLabel(bill.frequency)} · ${Formatters.fullDate(bill.nextDueDate, context)}',
                    style: AppTypography.caption(c.textLight),
                  ),
                ],
              ),
            ),
            Text(
              '${Formatters.amount(bill.amount)} ${bill.currency}',
              style: AppTypography.bodyStrong(c.primary),
            ),
          ],
        ),
      ),
    );
  }
}

class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({required this.suggestion});

  final BillSuggestion suggestion;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
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
                  'تكرر ${suggestion.monthsSeen} أشهر',
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
    );
  }
}

class _MainSegmented extends StatelessWidget {
  const _MainSegmented({
    required this.value,
    required this.labels,
    required this.onChanged,
  });

  final int value;
  final List<String> labels;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(AppRadius.pill),
                onTap: () => onChanged(i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  decoration: BoxDecoration(
                    color: value == i ? c.primary : Colors.transparent,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Text(
                    labels[i],
                    textAlign: TextAlign.center,
                    style: AppTypography.caption(
                      value == i ? Colors.white : c.textLight,
                    ).copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
              ),
            ),
        ],
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

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s6),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: c.border),
      ),
      child: Column(
        children: [
          Icon(icon, size: 44, color: c.textLight),
          const SizedBox(height: AppSpacing.s3),
          Text(title, style: AppTypography.headline(c.textMain)),
          const SizedBox(height: AppSpacing.s2),
          Text(
            body,
            textAlign: TextAlign.center,
            style: AppTypography.callout(c.textLight),
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
