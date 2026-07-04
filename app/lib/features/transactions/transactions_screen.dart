import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/account_entity.dart';
import '../../domain/entities/bill_entity.dart';
import '../../domain/entities/transaction_entity.dart';
import '../cards/brand_mark.dart';
import '../common/premium_loading.dart';
import '../common/transaction_direction.dart';
import '../common/app_pill_tab_bar.dart';
import '../common/app_empty_state.dart';
import '../common/app_transaction_row.dart';
import '../common/app_button.dart';
import '../common/app_sheet_scaffold.dart';
import '../common/category_catalog.dart';
import '../subscriptions/bill_details_sheet.dart';
import '../subscriptions/bill_form_sheet.dart';
import '../dashboard/dashboard_providers.dart';
import '../../domain/entities/suspected_duplicate_entity.dart';
import 'manual_transaction_sheet.dart';
import 'transaction_details_screen.dart';
import 'transactions_providers.dart';
import 'widgets/change_category_sheet.dart';

String _monthsLabel(int n) {
  if (n == 1) return 'شهر';
  if (n == 2) return 'شهرين';
  if (n <= 10) return '$n أشهر';
  return '$n شهراً';
}

class TransactionsScreen extends ConsumerWidget {
  const TransactionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(transactionsListProvider);
    final billsAsync = ref.watch(billsViewProvider);
    final tab = ref.watch(transactionsPageTabProvider);
    final pendingOnly = ref.watch(transactionsPendingFilterProvider);
    final currencyLabel = Currency.arabicLabel(
        ref.watch(baseCurrencyProvider).valueOrNull ?? 'SAR');
    final logos = ref.watch(merchantLogosProvider).valueOrNull ??
        const <String, String>{};

    return Scaffold(
      body: async.when(
        loading: () => const PremiumSkeletonPage(cardCount: 6),
        error: (e, _) => const Center(child: Text('حدث خطأ')),
        data: (view) {
          final groups = <String, List<TransactionEntity>>{};
          for (final tx in view.transactions) {
            final label = Formatters.dateGroupLabel(tx.occurredAt, context);
            groups.putIfAbsent(label, () => []).add(tx);
          }

          final bills = billsAsync.valueOrNull?.bills ?? [];
          final subs =
              bills.where((b) => b.type == BillType.subscription).toList();
          final insts =
              bills.where((b) => b.type == BillType.installment).toList();
          final activeSubs =
              subs.where((b) => b.status == BillStatus.active).toList();

          final monthlyTotal = activeSubs.fold<double>(
            0,
            (sum, bill) => sum + _monthlyAmount(bill),
          );

          return NestedScrollView(
            headerSliverBuilder: (context, innerBoxIsScrolled) {
              return [
                SliverToBoxAdapter(
                  child: Column(
                    children: [
                      _TransactionsHeader(
                        tab: tab,
                        expenseTotal: view.expenseTotal,
                        transactionsCount: view.transactions.length,
                        pendingCount: view.pendingCount,
                        subsCount: subs.length,
                        instsCount: insts.length,
                        monthlyTotal: monthlyTotal,
                        currencyLabel: currencyLabel,
                        onAdd: () {
                          if (tab == 0) {
                            ManualTransactionSheet.show(context);
                          } else {
                            BillFormSheet.show(context);
                          }
                        },
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.gutter),
                        child: Column(
                          children: [
                            const _ActiveAccountPicker(),
                            const SizedBox(height: AppSpacing.s3),
                            const _SuspectedDuplicatesBanner(),
                            if (tab == 0) ...[
                              if (pendingOnly) ...[
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 12, vertical: 8),
                                      decoration: BoxDecoration(
                                        color: context.colors.accent
                                            .withValues(alpha: 0.12),
                                        borderRadius: BorderRadius.circular(20),
                                        border: Border.all(
                                            color: context.colors.accent
                                                .withValues(alpha: 0.30)),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(AppLucideIcons.alertTriangle,
                                              size: 14,
                                              color: context.colors.accent),
                                          const SizedBox(width: 6),
                                          Text('تصفية: قيد المراجعة',
                                              style: AppTypography.caption(
                                                      context.colors.accent)
                                                  .copyWith(
                                                      fontWeight:
                                                          FontWeight.w700)),
                                          const SizedBox(width: 8),
                                          GestureDetector(
                                            onTap: () => ref
                                                .read(
                                                    transactionsPendingFilterProvider
                                                        .notifier)
                                                .state = false,
                                            child: Icon(Icons.close,
                                                size: 14,
                                                color: context.colors.accent),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const Spacer(),
                                    if (view.pendingCount > 0)
                                      TextButton.icon(
                                        onPressed: () => _confirmAllPending(
                                            context, ref, view.transactions),
                                        icon: Icon(Icons.done_all_rounded,
                                            size: 18,
                                            color: context.colors.success),
                                        label: Text(
                                          'تأكيد الكل',
                                          style: AppTypography.caption(
                                                  context.colors.success)
                                              .copyWith(
                                                  fontWeight: FontWeight.w800),
                                        ),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: AppSpacing.s3),
                              ],
                              if (!pendingOnly) ...[
                                _DateRangeChips(range: view.range),
                                const SizedBox(height: AppSpacing.s4),
                              ],
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _TabBarDelegate(
                    child: Container(
                      height: 64.0,
                      color: context.colors.bg,
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.gutter,
                      ),
                      alignment: Alignment.center,
                      child: AppPillTabBar(
                        tabs: const ['العمليات', 'الفواتير'],
                        selectedIndex: tab,
                        onSelected: (value) => ref
                            .read(transactionsPageTabProvider.notifier)
                            .state = value,
                      ),
                    ),
                  ),
                ),
              ];
            },
            body: ListView(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.gutter,
                AppSpacing.s3,
                AppSpacing.gutter,
                120,
              ),
              children: [
                if (tab == 0) ...[
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
                          final title =
                              tx.rawMerchant ?? category?.nameAr ?? 'عملية';
                          return AppTransactionRow(
                            title: title,
                            amount: tx.amount,
                            currency: Currency.arabicLabel(tx.currency),
                            subtitle: category?.nameAr,
                            categoryIcon: category?.icon,
                            categoryColor: category?.color,
                            brandLogoUrl: BrandMark.logoFor(title, logos),
                            isPending: tx.status == TransactionStatus.pending,
                            isAi: tx.source == TransactionSourceEntity.aiParsed,
                            isDebit: transactionIsDebit(tx),
                            onTap: () => TransactionDetailsScreen.showSheet(
                              context,
                              tx.id,
                            ),
                          );
                        }(),
                    ],
                ] else ...[
                  billsAsync.when(
                    loading: () => const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                    error: (error, _) => const Text('حدث خطأ'),
                    data: (bills) => _BillsTab(
                      view: bills,
                      currencyLabel: currencyLabel,
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _confirmAllPending(
    BuildContext context,
    WidgetRef ref,
    List<TransactionEntity> transactions,
  ) async {
    final pending = transactions
        .where((t) => t.status == TransactionStatus.pending)
        .toList();
    if (pending.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تأكيد كل العمليات المعلّقة؟'),
        content: Text('هيتم تأكيد ${pending.length} عملية بتصنيفاتها الحالية.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('تأكيد'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final repo = ref.read(transactionRepositoryProvider);
    for (final tx in pending) {
      await repo.confirm(tx.id);
    }
    refreshTransactions(ref);
    ref.invalidate(dashboardDataProvider);
    ref.read(transactionsPendingFilterProvider.notifier).state = false;
  }
}

class _ActiveAccountPicker extends ConsumerWidget {
  const _ActiveAccountPicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accountsAsync = ref.watch(accountsProvider);
    final selectedId = ref.watch(activeAccountIdProvider);
    return accountsAsync.maybeWhen(
      data: (accounts) {
        if (accounts.isEmpty) return const SizedBox.shrink();
        final defaultAccount = accounts.firstWhere(
          (account) => account.isDefault,
          orElse: () => accounts.first,
        );
        final account = accounts.firstWhere(
          (item) => item.id == selectedId,
          orElse: () => defaultAccount,
        );
        final c = context.colors;
        return Center(
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadius.pill),
              onTap: () => _showAccountSheet(context, ref, account.id),
              child: Container(
                padding: const EdgeInsetsDirectional.fromSTEB(14, 8, 12, 8),
                decoration: BoxDecoration(
                  color: c.surfaceCard,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  border: Border.all(color: c.border),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(AppLucideIcons.walletCards, size: 16, color: c.cta),
                    const SizedBox(width: 8),
                    Text(
                      '${account.name} · ${Currency.arabicLabel(account.currency)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.caption(c.textPrimary)
                          .copyWith(fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.keyboard_arrow_down_rounded,
                        size: 18, color: c.textMuted),
                  ],
                ),
              ),
            ),
          ),
        );
      },
      orElse: () => const SizedBox.shrink(),
    );
  }

  Future<void> _showAccountSheet(
    BuildContext context,
    WidgetRef ref,
    String currentId,
  ) {
    final c = context.colors;
    final container = ProviderScope.containerOf(context, listen: false);
    final accounts =
        ref.read(accountsProvider).valueOrNull ?? <AccountEntity>[];
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: c.surface,
      builder: (context) => Directionality(
        textDirection: TextDirection.rtl,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            0,
            AppSpacing.gutter,
            AppSpacing.gutter,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  'اختار الحساب',
                  style: AppTypography.title2(c.textPrimary),
                ),
              ),
              const SizedBox(height: AppSpacing.s3),
              for (final account in accounts)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    AppLucideIcons.walletCards,
                    color: account.id == currentId ? c.cta : c.textMuted,
                  ),
                  title: Text(account.name),
                  subtitle: Text(Currency.arabicLabel(account.currency)),
                  trailing: account.id == currentId
                      ? Icon(Icons.check_circle_rounded, color: c.cta)
                      : null,
                  onTap: () async {
                    HapticFeedback.selectionClick();
                    Navigator.of(context).pop();
                    container.read(activeAccountIdProvider.notifier).state =
                        account.id;
                    await container
                        .read(accountRepositoryProvider)
                        .setDefault(account.id);
                    container.invalidate(accountsProvider);
                    container.invalidate(baseCurrencyProvider);
                    container.invalidate(transactionsListProvider);
                    container.invalidate(billsViewProvider);
                  },
                ),
            ],
          ),
        ),
      ),
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
    return Align(
      alignment: Alignment.center,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          onTap: () {
            HapticFeedback.selectionClick();
            _showRangeSheet(context, ref, range);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: c.surfaceCard,
              borderRadius: BorderRadius.circular(AppRadius.pill),
              border: Border.all(color: c.border),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.03),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.calendar_month_rounded, color: c.cta, size: 16),
                const SizedBox(width: 8),
                Text(
                  range.label,
                  style: AppTypography.subhead(c.textPrimary)
                      .copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 6),
                Icon(Icons.keyboard_arrow_down_rounded,
                    color: c.textMuted, size: 18),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _presetLabel(TransactionsDatePreset preset) => switch (preset) {
        TransactionsDatePreset.today => 'اليوم',
        TransactionsDatePreset.thisWeek => 'هذا الأسبوع',
        TransactionsDatePreset.thisMonth => 'هذا الشهر',
        TransactionsDatePreset.previousMonth => 'الشهر السابق',
        TransactionsDatePreset.last7Days => 'آخر 7 أيام',
        TransactionsDatePreset.last30Days => 'آخر 30 يوم',
        TransactionsDatePreset.last90Days => 'آخر 90 يوم',
        TransactionsDatePreset.custom => 'مخصص',
      };

  TransactionsDateRange _rangeForPreset(TransactionsDatePreset preset) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final weekStart =
        today.subtract(Duration(days: (now.weekday - DateTime.saturday) % 7));
    return switch (preset) {
      TransactionsDatePreset.today => TransactionsDateRange(
          preset: preset,
          from: today,
          to: now,
        ),
      TransactionsDatePreset.thisWeek => TransactionsDateRange(
          preset: preset,
          from: weekStart,
          to: now,
        ),
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
      TransactionsDatePreset.last7Days => TransactionsDateRange(
          preset: preset,
          from: now.subtract(const Duration(days: 7)),
          to: now,
        ),
      TransactionsDatePreset.last30Days => TransactionsDateRange(
          preset: preset,
          from: now.subtract(const Duration(days: 30)),
          to: now,
        ),
      TransactionsDatePreset.last90Days => TransactionsDateRange(
          preset: preset,
          from: now.subtract(const Duration(days: 90)),
          to: now,
        ),
      TransactionsDatePreset.custom => range,
    };
  }

  Future<void> _showRangeSheet(
    BuildContext context,
    WidgetRef ref,
    TransactionsDateRange current,
  ) async {
    var from = current.from;
    var to = current.to;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          final c = context.colors;
          return AppSheetScaffold(
            title: 'اختار فترة العرض',
            scrollable: true,
            body: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final preset in TransactionsDatePreset.values)
                        ChoiceChip(
                          label: Text(_presetLabel(preset)),
                          selected: current.preset == preset,
                          selectedColor: c.primary.withValues(alpha: 0.16),
                          onSelected: (_) {
                            if (preset == TransactionsDatePreset.custom) {
                              setState(() {});
                              return;
                            }
                            ref
                                .read(transactionsDateRangeProvider.notifier)
                                .state = _rangeForPreset(preset);
                            Navigator.of(context).pop();
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.s4),
                  Container(
                    padding: const EdgeInsets.all(AppSpacing.s3),
                    decoration: BoxDecoration(
                      color: c.surfaceCard,
                      borderRadius: BorderRadius.circular(AppRadius.card),
                      border: Border.all(color: c.border),
                    ),
                    child: Material(
                      color: Colors.transparent,
                      child: Column(
                        children: [
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('من'),
                            subtitle: Text(Formatters.fullDate(from, context)),
                            trailing: const Icon(Icons.calendar_month_outlined),
                            onTap: () async {
                              final picked = await showDatePicker(
                                context: context,
                                initialDate: from,
                                firstDate: DateTime(2020),
                                lastDate: DateTime.now()
                                    .add(const Duration(days: 365)),
                              );
                              if (picked != null) setState(() => from = picked);
                            },
                          ),
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('إلى'),
                            subtitle: Text(Formatters.fullDate(to, context)),
                            trailing: const Icon(Icons.calendar_month_outlined),
                            onTap: () async {
                              final picked = await showDatePicker(
                                context: context,
                                initialDate: to,
                                firstDate: DateTime(2020),
                                lastDate: DateTime.now()
                                    .add(const Duration(days: 365)),
                              );
                              if (picked != null) setState(() => to = picked);
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.s4),
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
                    child: const Text('تطبيق الفترة المخصصة'),
                  ),
                  const SizedBox(height: AppSpacing.s5),
                ],
              ),
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
  const _BillsTab({
    required this.view,
    required this.currencyLabel,
  });

  final BillsView view;
  final String currencyLabel;

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
          currencyLabel: widget.currencyLabel,
        ),
        const SizedBox(height: AppSpacing.s5),
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
              currencyLabel: widget.currencyLabel,
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
                    ? 'إزاي قرش يتابع الاشتراكات؟'
                    : 'إزاي قرش يتابع الأقساط؟',
                style: AppTypography.title2(c.textMain),
              ),
              const SizedBox(height: AppSpacing.s3),
              Text(
                type == BillType.subscription
                    ? 'قرش يتابع الأنماط المتكررة تلقائياً، وتقدر كمان تضيف اشتراك يدويًا بالمبلغ وتاريخ التجديد والتنبيه.'
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
    required this.currencyLabel,
  });

  final BillType type;
  final double monthlyTotal;
  final int activeCount;
  final int nextThisWeek;
  final String currencyLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isSubscription = type == BillType.subscription;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s4),
      decoration: BoxDecoration(
        color: c.cta,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        boxShadow: [
          BoxShadow(
            color: c.cta.withValues(alpha: 0.20),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                isSubscription
                    ? 'إجمالي الاشتراكات الشهرية'
                    : 'إجمالي الأقساط الشهرية',
                style:
                    AppTypography.caption(Colors.white.withValues(alpha: 0.72)),
              ),
              const Spacer(),
              Icon(
                isSubscription
                    ? Icons.repeat_rounded
                    : Icons.receipt_long_rounded,
                color: Colors.white.withValues(alpha: 0.72),
                size: 18,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${Formatters.amount(monthlyTotal)} $currencyLabel',
            style: AppTypography.title1(Colors.white)
                .copyWith(fontWeight: FontWeight.bold, fontFamily: 'Outfit'),
          ),
          const SizedBox(height: AppSpacing.s4),
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.s3, vertical: 8),
            decoration: BoxDecoration(
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
                    value:
                        '${Formatters.integer(monthlyTotal * 12)} $currencyLabel',
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

class _BillCard extends StatelessWidget {
  const _BillCard({required this.bill});

  final BillEntity bill;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final daysLeft = bill.nextDueDate.difference(DateTime.now()).inDays;
    final currLabel = Currency.arabicLabel(bill.currency);

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

    if (bill.type == BillType.subscription) {
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

      return Container(
        margin: const EdgeInsets.only(bottom: AppSpacing.s2),
        child: Material(
          color: c.surfaceCard,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.card),
            side: BorderSide(color: c.border),
          ),
          child: InkWell(
            onTap: () => BillDetailsSheet.show(context, bill),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.s4),
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
                        style: AppTypography.bodyStrong(c.textMain)
                            .copyWith(fontFamily: 'Outfit'),
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
          ),
        ),
      );
    } else {
      // Installment style
      final hasProg =
          bill.totalInstallments != null && bill.totalInstallments! > 0;
      final progressVal = bill.installmentProgress;
      final remaining = bill.remainingInstallments;

      return Container(
        margin: const EdgeInsets.only(bottom: AppSpacing.s2),
        child: Material(
          color: c.surfaceCard,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.card),
            side: BorderSide(color: c.border),
          ),
          child: InkWell(
            onTap: () => BillDetailsSheet.show(context, bill),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.s4),
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
                            style: AppTypography.bodyStrong(c.primary)
                                .copyWith(fontFamily: 'Outfit'),
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
                          value: progressVal,
                          backgroundColor: c.surface2,
                          valueColor: AlwaysStoppedAnimation(
                            progressVal >= 1.0 ? c.success : c.primary,
                          ),
                        ),
                      ),
                    ),
                  ],
                  if (bill.totalPurchaseAmount != null) ...[
                    const SizedBox(height: AppSpacing.s3),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
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
                                fontFamily: 'Outfit'),
                          ),
                          if (bill.interestRate != null) ...[
                            const Spacer(),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: c.accent.withValues(alpha: 0.10),
                                borderRadius:
                                    BorderRadius.circular(AppRadius.pill),
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
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: c.success.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(AppRadius.md),
                        border: Border.all(
                          color: c.success.withValues(alpha: 0.28),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.payments_outlined,
                              size: 16, color: c.success),
                          const SizedBox(width: 6),
                          Text(
                            'مدفوع يدويًا: ',
                            style: AppTypography.caption(c.textLight),
                          ),
                          Text(
                            '${Formatters.amount(bill.safeManualPaidAmount)} $currLabel',
                            style: AppTypography.caption(c.success).copyWith(
                              fontWeight: FontWeight.bold,
                              fontFamily: 'Outfit',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.s3),
                  Row(
                    children: [
                      Icon(dueIcon, size: 14, color: dueColor),
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
          ),
        ),
      );
    }
  }
}

class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({
    required this.suggestion,
    required this.currencyLabel,
    required this.onAdd,
  });

  final BillSuggestion suggestion;
  final String currencyLabel;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.s2),
      child: Material(
        color: c.surfaceCard.withValues(alpha: 0.6),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
          side: BorderSide(
            color: c.border.withValues(alpha: 0.5),
          ),
        ),
        child: InkWell(
          onTap: onAdd,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.s4),
            child: Row(
              children: [
                BrandMark(name: suggestion.name, size: 48),
                const SizedBox(width: AppSpacing.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        suggestion.name,
                        style: AppTypography.bodyStrong(c.textMain),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'تكرر ${_monthsLabel(suggestion.monthsSeen)} · اضغط للتفعيل',
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
                      '${Formatters.amount(suggestion.averageAmount)} $currencyLabel/شهر',
                      style: AppTypography.caption(c.textMain).copyWith(
                          fontWeight: FontWeight.bold, fontFamily: 'Outfit'),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
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

double _monthlyAmount(BillEntity bill) => switch (bill.frequency) {
      BillFrequency.weekly => bill.amount * 4,
      BillFrequency.monthly => bill.amount,
      BillFrequency.yearly => bill.amount / 12,
      BillFrequency.custom => bill.customIntervalDays == null
          ? bill.amount
          : bill.amount * (30 / bill.customIntervalDays!),
    };

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

class _AddButton extends StatelessWidget {
  const _AddButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: c.surfaceCard,
          shape: BoxShape.circle,
          border: Border.all(color: c.border),
        ),
        child: Icon(Icons.add, color: c.cta, size: 22),
      ),
    );
  }
}

class _HeaderDivider extends StatelessWidget {
  const _HeaderDivider();
  @override
  Widget build(BuildContext context) => Container(
        width: 1,
        height: 32,
        color: context.colors.divider,
      );
}

class _HeaderMetric extends StatelessWidget {
  const _HeaderMetric({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            textAlign: TextAlign.center,
            style: AppTypography.bodyStrong(c.textMain)
                .copyWith(fontFamily: 'Outfit'),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: AppTypography.caption(c.textLight),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _TransactionsHeader extends StatelessWidget {
  const _TransactionsHeader({
    required this.tab,
    required this.expenseTotal,
    required this.transactionsCount,
    required this.pendingCount,
    required this.subsCount,
    required this.instsCount,
    required this.monthlyTotal,
    required this.currencyLabel,
    required this.onAdd,
  });

  final int tab;
  final double expenseTotal;
  final int transactionsCount;
  final int pendingCount;
  final int subsCount;
  final int instsCount;
  final double monthlyTotal;
  final String currencyLabel;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        64,
        AppSpacing.gutter,
        AppSpacing.s4,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            c.cta.withValues(alpha: 0.12),
            c.bg,
          ],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (Navigator.of(context).canPop()) ...[
                BackButton(color: c.textMain),
                const SizedBox(width: AppSpacing.s2),
              ],
              Expanded(
                child: Text(
                  tab == 0 ? 'العمليات' : 'الفواتير والاشتراكات',
                  style: AppTypography.title1(c.textMain)
                      .copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              _AddButton(onTap: onAdd),
            ],
          ),
          const SizedBox(height: AppSpacing.s5),
          Container(
            padding: const EdgeInsets.all(AppSpacing.s4),
            decoration: BoxDecoration(
              color: c.surfaceCard,
              borderRadius: BorderRadius.circular(AppRadius.card),
              border: Border.all(color: c.border),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.03),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: c.cta.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(
                        tab == 0
                            ? Icons.payments_outlined
                            : Icons.receipt_long_rounded,
                        color: c.cta,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.s3),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            tab == 0
                                ? 'إجمالي المصروفات للفترة'
                                : 'إجمالي الصرف الشهري النشط',
                            style: AppTypography.caption(c.textSecondary),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            tab == 0
                                ? '${Formatters.amount(expenseTotal)} $currencyLabel'
                                : '${Formatters.amount(monthlyTotal)} $currencyLabel',
                            style: AppTypography.title2(c.textMain).copyWith(
                                fontWeight: FontWeight.bold,
                                fontFamily: 'Outfit'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.s3),
                  child: Divider(color: c.border, height: 1),
                ),
                Row(
                  children: tab == 0
                      ? [
                          _HeaderMetric(
                              label: 'عملية للفترة',
                              value: '$transactionsCount'),
                          const _HeaderDivider(),
                          _HeaderMetric(
                              label: 'قيد المراجعة', value: '$pendingCount'),
                          const _HeaderDivider(),
                          _HeaderMetric(
                            label: 'إجمالي المصروف',
                            value:
                                '${Formatters.amount(expenseTotal)} $currencyLabel',
                          ),
                        ]
                      : [
                          _HeaderMetric(
                              label: 'اشتراك نشط', value: '$subsCount'),
                          const _HeaderDivider(),
                          _HeaderMetric(
                              label: 'قسط جاري', value: '$instsCount'),
                          const _HeaderDivider(),
                          _HeaderMetric(
                            label: 'المجموع سنوياً',
                            value:
                                '${Formatters.amount(monthlyTotal * 12)} $currencyLabel',
                          ),
                        ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Suspected Duplicates ────────────────────────────────────────────────────

class _SuspectedDuplicatesBanner extends ConsumerWidget {
  const _SuspectedDuplicatesBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dupes = ref.watch(suspectedDuplicatesProvider).valueOrNull ?? [];
    if (dupes.isEmpty) return const SizedBox.shrink();
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s3),
      child: GestureDetector(
        onTap: () => _SuspectedDuplicatesSheet.show(context),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: c.accent.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: c.accent.withValues(alpha: 0.28)),
          ),
          child: Row(
            children: [
              Icon(Icons.copy_rounded, size: 16, color: c.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${dupes.length} ${dupes.length == 1 ? 'عملية مشبوهة' : 'عمليات مشبوهة'} — اضغط للمراجعة',
                  style: AppTypography.caption(c.accent)
                      .copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              Icon(Icons.chevron_left, size: 16, color: c.accent),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> showSuspectedDuplicateReviewSheet(
    BuildContext context, SuspectedDuplicateEntity dupe) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    backgroundColor: context.colors.surface,
    builder: (_) => Directionality(
      textDirection: TextDirection.rtl,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        child: _SuspectedDuplicateCard(dupe: dupe),
      ),
    ),
  );
}

class _SuspectedDuplicatesSheet extends ConsumerWidget {
  const _SuspectedDuplicatesSheet();

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: context.colors.surface,
      builder: (_) => const Directionality(
        textDirection: TextDirection.rtl,
        child: _SuspectedDuplicatesSheet(),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final dupes = ref.watch(suspectedDuplicatesProvider).valueOrNull ?? [];

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.92,
      builder: (_, controller) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text('عمليات مشبوهة',
                      style: AppTypography.title2(c.textMain)),
                ),
                TextButton(
                  onPressed: () async {
                    final repo = ref.read(suspectedDuplicateRepositoryProvider);
                    for (final d in dupes) {
                      await repo.delete(d.id);
                    }
                    ref.invalidate(suspectedDuplicatesProvider);
                    if (context.mounted) Navigator.of(context).pop();
                  },
                  child: Text('تجاهل الكل',
                      style: AppTypography.caption(c.textMuted)),
                ),
              ],
            ),
          ),
          Expanded(
            child: dupes.isEmpty
                ? Center(
                    child: Text('لا توجد عمليات مشبوهة',
                        style: AppTypography.body(c.textMuted)),
                  )
                : ListView.separated(
                    controller: controller,
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                    itemCount: dupes.length,
                    separatorBuilder: (_, __) =>
                        const SizedBox(height: AppSpacing.s3),
                    itemBuilder: (_, i) =>
                        _SuspectedDuplicateCard(dupe: dupes[i]),
                  ),
          ),
        ],
      ),
    );
  }
}

class _SuspectedDuplicateCard extends ConsumerWidget {
  const _SuspectedDuplicateCard({required this.dupe});

  final SuspectedDuplicateEntity dupe;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final existingAsync = ref.watch(transactionByIdProvider(
      dupe.existingTransactionId,
    ));
    final existing = existingAsync.valueOrNull;
    final timestamp = dupe.comparisonTimestamp ?? dupe.occurredAt;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s4),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.content_copy_rounded, size: 18, color: c.warning),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'عملية مشابهة موجودة',
                  style: AppTypography.bodyStrong(c.textMain),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '${Formatters.amount(dupe.amount)} ${dupe.currency}',
                style: AppTypography.bodyStrong(c.textMain),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'العملية دي شبه عملية موجودة بنفس المبلغ والتاجر والوقت.',
            style: AppTypography.caption(c.textMuted),
          ),
          const SizedBox(height: AppSpacing.s3),
          _DuplicateInfoRow(
            label: 'الجديدة',
            merchant: dupe.rawMerchant ?? 'بدون تاجر واضح',
            amount: '${Formatters.amount(dupe.amount)} ${dupe.currency}',
            time:
                '${Formatters.dateWithWeekday(timestamp, context)} · ${Formatters.time(timestamp)}',
          ),
          if (existing != null) ...[
            const SizedBox(height: AppSpacing.s2),
            _DuplicateInfoRow(
              label: 'الموجودة',
              merchant: existing.rawMerchant ?? 'بدون تاجر واضح',
              amount:
                  '${Formatters.amount(existing.amount)} ${existing.currency}',
              time:
                  '${Formatters.dateWithWeekday(existing.comparisonTimestamp ?? existing.occurredAt, context)} · ${Formatters.time(existing.comparisonTimestamp ?? existing.occurredAt)}',
            ),
          ],
          const SizedBox(height: AppSpacing.s2),
          Text(
            'مصدر الوقت: ${_timestampSourceLabel(dupe.comparisonTimestampSource)}',
            style: AppTypography.caption(c.textMuted),
          ),
          const SizedBox(height: AppSpacing.s3),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _dismiss(ref),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: c.textMuted,
                    side: BorderSide(color: c.border.withValues(alpha: 0.5)),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  child: const Text('تجاهل التكرار'),
                ),
              ),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: FilledButton(
                  onPressed: () => _confirmAsReal(context, ref),
                  style: FilledButton.styleFrom(
                    backgroundColor: c.primary,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  child: const Text('احفظ كجديدة'),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s2),
          Row(
            children: [
              Expanded(
                child: TextButton.icon(
                  onPressed: existing == null
                      ? null
                      : () => _editExisting(context, ref, existing),
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  label: const Text('تعديل العملية'),
                ),
              ),
              const SizedBox(width: AppSpacing.s2),
              Expanded(
                child: TextButton.icon(
                  onPressed: existing == null
                      ? null
                      : () => _changeCategory(context, ref, existing),
                  icon: const Icon(Icons.category_outlined, size: 16),
                  label: const Text('تغيير التصنيف'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _timestampSourceLabel(ComparisonTimestampSource? source) {
    return source == ComparisonTimestampSource.smsBody
        ? 'وقت العملية داخل SMS'
        : 'وقت استلام الرسالة';
  }

  Future<void> _dismiss(WidgetRef ref) async {
    await ref.read(suspectedDuplicateRepositoryProvider).delete(dupe.id);
    ref.invalidate(suspectedDuplicatesProvider);
  }

  Future<void> _confirmAsReal(BuildContext context, WidgetRef ref) async {
    final addUseCase = ref.read(addTransactionUseCaseProvider);
    final result = await addUseCase(
      rawMessage: dupe.rawMessage,
      senderId: dupe.senderId,
      skipDedup: true,
      smsReceivedAt:
          dupe.comparisonTimestampSource == ComparisonTimestampSource.receivedAt
              ? dupe.comparisonTimestamp ?? dupe.occurredAt
              : null,
    );
    await ref.read(suspectedDuplicateRepositoryProvider).delete(dupe.id);
    ref.invalidate(suspectedDuplicatesProvider);
    refreshTransactions(ref);
    ref.invalidate(dashboardDataProvider);
    if (context.mounted && result.transaction != null) {
      await TransactionDetailsScreen.showSheet(context, result.transaction!.id);
    }
  }

  Future<void> _editExisting(
    BuildContext context,
    WidgetRef ref,
    TransactionEntity existing,
  ) async {
    await ManualTransactionSheet.show(context, transaction: existing);
    ref.invalidate(transactionByIdProvider(existing.id));
    refreshTransactions(ref);
    ref.invalidate(dashboardDataProvider);
  }

  Future<void> _changeCategory(
    BuildContext context,
    WidgetRef ref,
    TransactionEntity existing,
  ) async {
    final catalog = await ref.read(categoryCatalogProvider.future);
    if (!context.mounted) return;
    await showChangeCategorySheet(context, existing, catalog);
    ref.invalidate(transactionByIdProvider(existing.id));
    refreshTransactions(ref);
    ref.invalidate(dashboardDataProvider);
  }
}

class _DuplicateInfoRow extends StatelessWidget {
  const _DuplicateInfoRow({
    required this.label,
    required this.merchant,
    required this.amount,
    required this.time,
  });

  final String label;
  final String merchant;
  final String amount;
  final String time;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.s3),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppTypography.caption(c.textMuted)),
          const SizedBox(height: 2),
          Row(
            children: [
              Expanded(
                child: Text(
                  merchant,
                  style: AppTypography.bodyStrong(c.textMain),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: AppSpacing.s2),
              Text(amount, style: AppTypography.bodyStrong(c.textMain)),
            ],
          ),
          const SizedBox(height: 2),
          Text(time, style: AppTypography.caption(c.textMuted)),
        ],
      ),
    );
  }
}
