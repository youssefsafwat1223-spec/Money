import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/utils/async_reload_safe.dart';
import 'package:flutter/services.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/calm_chip.dart';
import '../../core/theme/widgets/calm_page_header.dart';
import '../../core/theme/widgets/glass_selector.dart';
import '../../core/theme/widgets/mali_card.dart';
import '../../core/theme/widgets/mali_glass.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/category_glyph.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/account_entity.dart';
import '../../domain/entities/bill_entity.dart';
import '../../domain/finance/bill_metrics.dart';
import '../../domain/entities/transaction_entity.dart';
import '../cards/brand_mark.dart';
import '../common/app_avatar.dart';
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
import '../../domain/entities/smart_inbox_item_entity.dart';
import '../capture/capture_entry_sheet.dart';
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
    // MALI-047n: canonical period expense over the full dataset (not a fold of
    // loaded pages), single-currency for the active-account scope.
    final periodTotal = ref.watch(transactionsPeriodTotalProvider).valueOrNull;
    final periodExpense = periodTotal?.netExpense.toDouble() ?? 0.0;
    final txHeaderCurrencyLabel = Currency.arabicLabel((periodTotal?.currency ??
            ref.watch(baseCurrencyProvider).valueOrNull ??
            'SAR')
        .toUpperCase());
    final logos = ref.watch(merchantLogosProvider).valueOrNull ??
        const <String, String>{};

    return Scaffold(
      // مفيش FAB: زرار الإضافة في الهيدر هو المنفذ الوحيد للإضافة.
      body: async.when(
        skipLoadingOnReload: true,
        loading: () => const SkeletonList(rows: 6),
        error: (e, _) => const Center(child: Text('حدث خطأ')),
        data: (view) {
          // B2-C — date-section grouping is precomputed once in the provider
          // (view.sections), not re-grouped over every row on every build here.
          final sections = view.sections;
          Widget txRow(TransactionEntity tx) {
            final category = view.catalog.byId(tx.categoryId);
            final title = tx.rawMerchant ?? category?.nameAr ?? 'عملية';
            return AppTransactionRow(
              title: title,
              amount: tx.amount,
              currency: Currency.arabicLabel(tx.currency),
              subtitle:
                  '${Formatters.time(tx.occurredAt)} · ${category?.nameAr ?? 'غير مصنّفة'}',
              categoryIconName: category?.iconName,
              categoryColor: category?.color,
              brandLogoUrl: BrandMark.logoFor(title, logos),
              isPending: tx.status == TransactionStatus.pending,
              isAi: tx.source == TransactionSourceEntity.aiParsed,
              isDebit: transactionIsDebit(tx),
              horizontalPadding: 14,
              onTap: () => TransactionDetailsScreen.showSheet(context, tx.id),
            );
          }

          final bills = billsAsync.valueOrNull?.bills ?? [];
          final subs =
              bills.where((b) => b.type == BillType.subscription).toList();
          final insts =
              bills.where((b) => b.type == BillType.installment).toList();
          // Active-subscription monthly obligation, summed EXACTLY as Money in
          // the base display currency (currency-isolated); converted to double
          // only here at the display leaf.
          final baseCur = ref.watch(baseCurrencyProvider).valueOrNull ?? 'SAR';
          final monthlyTotal =
              subscriptionMonthlyTotalMoney(subs, baseCur).toDouble();

          return SafeArea(
              top: false,
              bottom: false,
              child: NestedScrollView(
                headerSliverBuilder: (context, innerBoxIsScrolled) {
                  return [
                    SliverToBoxAdapter(
                      child: Column(
                        children: [
                          _TransactionsHeader(
                            tab: tab,
                            expenseTotal: periodExpense,
                            transactionsCount: view.transactions.length,
                            pendingCount: view.pendingCount,
                            subsCount: subs.length,
                            instsCount: insts.length,
                            monthlyTotal: monthlyTotal,
                            currencyLabel: tab == 0
                                ? txHeaderCurrencyLabel
                                : currencyLabel,
                            onAdd: () {
                              if (tab == 0) {
                                showCaptureEntrySheet(context);
                              } else {
                                BillFormSheet.show(context);
                              }
                            },
                          ),
                          // صفّ الفلاتر واقع بين الهيدر وشريط التبويبات —
                          // من غير خلفية كانت بتبان شريحة بيضا وسط الأزرق.
                          // الذوبان لسه ما بدأش هنا، فاللون هو نفس حافة
                          // الهيدر بالظبط والشريط اللي بعده بيكمّل منه.
                          ColoredBox(
                            color: CalmPageHeader.meltEdgeColor(
                                Theme.of(context).brightness ==
                                    Brightness.dark),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: AppSpacing.gutter),
                              child: Column(
                                children: [
                                  if (tab == 0 && !pendingOnly)
                                    Row(
                                      children: [
                                        const Expanded(
                                            child: _ActiveAccountPicker()),
                                        const SizedBox(width: AppSpacing.s3),
                                        Expanded(
                                            child: _DateRangeChips(
                                                range: view.range)),
                                      ],
                                    )
                                  else
                                    const _ActiveAccountPicker(),
                                  const SizedBox(height: AppSpacing.s3),
                                  const _SuspectedDuplicatesBanner(),
                                  const _SmartInboxBanner(),
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
                                              borderRadius:
                                                  BorderRadius.circular(20),
                                              border: Border.all(
                                                  color: context.colors.accent
                                                      .withValues(alpha: 0.30)),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(
                                                    AppLucideIcons
                                                        .alertTriangle,
                                                    size: 14,
                                                    color:
                                                        context.colors.accent),
                                                const SizedBox(width: 6),
                                                Text('تصفية: قيد المراجعة',
                                                    style:
                                                        AppTypography.caption(
                                                                context.colors
                                                                    .accent)
                                                            .copyWith(
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w700)),
                                                const SizedBox(width: 8),
                                                GestureDetector(
                                                  onTap: () => ref
                                                      .read(
                                                          transactionsPendingFilterProvider
                                                              .notifier)
                                                      .state = false,
                                                  child: Icon(AppLucideIcons.x,
                                                      size: 14,
                                                      color: context
                                                          .colors.accent),
                                                ),
                                              ],
                                            ),
                                          ),
                                          const Spacer(),
                                          if (view.pendingCount > 0)
                                            TextButton.icon(
                                              onPressed: () =>
                                                  _confirmAllPending(context,
                                                      ref, view.transactions),
                                              icon: Icon(
                                                  AppLucideIcons.checkCheck,
                                                  size: 18,
                                                  color:
                                                      context.colors.success),
                                              label: Text(
                                                'تأكيد الكل',
                                                style: AppTypography.caption(
                                                        context.colors.success)
                                                    .copyWith(
                                                        fontWeight:
                                                            FontWeight.w700),
                                              ),
                                            ),
                                        ],
                                      ),
                                      const SizedBox(height: AppSpacing.s3),
                                    ],
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    SliverPersistentHeader(
                      pinned: true,
                      delegate: _TabBarDelegate(
                        // كبسولات عايمة من غير صندوق — ومن غير زجاج.
                        child: MeltSlice(
                          height: 64.0,
                          child: Container(
                            height: 64.0,
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
                    ),
                  ];
                },
                body: MeltTail(
                  startAt: 64,
                  child: tab == 0
                      ? NotificationListener<ScrollNotification>(
                          onNotification: (notification) {
                            if (notification.metrics.extentAfter < 900 &&
                                view.hasMore &&
                                !view.isLoadingMore) {
                              ref
                                  .read(transactionsListProvider.notifier)
                                  .loadMore();
                            }
                            return false;
                          },
                          child: ListView.builder(
                            padding: const EdgeInsets.fromLTRB(
                              AppSpacing.gutter,
                              AppSpacing.s3,
                              AppSpacing.gutter,
                              120,
                            ),
                            itemCount: 4 +
                                (view.transactions.isEmpty
                                    ? 1
                                    : sections.length) +
                                (view.isLoadingMore ? 1 : 0),
                            itemBuilder: (context, index) {
                              if (index == 0) {
                                return const TransactionSearchField();
                              }
                              if (index == 1) {
                                return const SizedBox(height: AppSpacing.s2);
                              }
                              if (index == 2) return const _FilterBar();
                              if (index == 3) {
                                return const SizedBox(height: AppSpacing.s2);
                              }
                              final itemIndex = index - 4;
                              if (view.transactions.isEmpty) {
                                return const AppEmptyState(
                                  icon: AppLucideIcons.inbox,
                                  title: 'لا توجد عمليات في هذه الفترة',
                                  subtitle:
                                      'غيّر الفترة أو أضف رسالة بنك جديدة من زر +.',
                                );
                              }
                              if (itemIndex >= sections.length) {
                                return const Padding(
                                  padding:
                                      EdgeInsets.all(AppSpacing.cardPadding),
                                  child: Center(
                                      child: CircularProgressIndicator()),
                                );
                              }
                              final section = sections[itemIndex];
                              return Padding(
                                padding: const EdgeInsets.only(
                                    bottom: AppSpacing.s4),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    _DateHeader(
                                      label: Formatters.dateGroupLabel(
                                          section.day, context),
                                    ),
                                    const SizedBox(height: AppSpacing.s2),
                                    MaliCard(
                                      style: MaliSurfaceStyle.floating,
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 4),
                                      child: Column(
                                        children: [
                                          for (final tx in section.transactions)
                                            txRow(tx),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        )
                      : ListView(
                          padding: const EdgeInsets.fromLTRB(
                            AppSpacing.gutter,
                            AppSpacing.s3,
                            AppSpacing.gutter,
                            120,
                          ),
                          children: [
                            billsAsync.when(
                              skipLoadingOnReload: true,
                              loading: () => const Padding(
                                padding: EdgeInsets.all(AppSpacing.s5),
                                child:
                                    Center(child: CircularProgressIndicator()),
                              ),
                              error: (error, _) => const Text('حدث خطأ'),
                              data: (bills) => _BillsTab(
                                view: bills,
                                currencyLabel: currencyLabel,
                                // F-027 — the display currency must come from
                                // the user's base currency, never from
                                // `bills.first`, which made the total depend on
                                // list ORDER and silently dropped every bill in
                                // another currency.
                                baseCurrency: ref
                                        .watch(baseCurrencyProvider)
                                        .valueOrNull ??
                                    'SAR',
                              ),
                            ),
                          ],
                        ),
                ),
              ));
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
    return accountsAsync.dataOrWhen(
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
        return GlassSelector(
          icon: AppLucideIcons.walletCards,
          label: '${account.name} · ${Currency.arabicLabel(account.currency)}',
          onTap: () => _showAccountSheet(context, ref, account.id),
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
      builder: (context) => navySheetTheme(Directionality(
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
                  style: AppTypography.sectionTitle(c.textPrimary),
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
                      ? Icon(AppLucideIcons.checkCircle, color: c.cta)
                      : null,
                  onTap: () async {
                    HapticFeedback.selectionClick();
                    Navigator.of(context).pop();
                    // F-020: viewing an account is UI/filter state only — it
                    // must NOT call setDefault() (persistent preference +
                    // server command). The explicit make-default action lives
                    // in the account form sheet.
                    container.read(activeAccountIdProvider.notifier).state =
                        account.id;
                    container.invalidate(accountsProvider);
                    container.invalidate(baseCurrencyProvider);
                    container.invalidate(transactionsListProvider);
                    container.invalidate(billsViewProvider);
                  },
                ),
            ],
          ),
        ),
      )),
    );
  }
}

class TransactionSearchField extends ConsumerStatefulWidget {
  const TransactionSearchField({super.key});

  @override
  ConsumerState<TransactionSearchField> createState() =>
      TransactionSearchFieldState();
}

class TransactionSearchFieldState
    extends ConsumerState<TransactionSearchField> {
  late final TextEditingController _controller;
  // MALI-029 / rendering — debounce the search so a burst of keystrokes does not
  // re-fetch page 1 + re-filter + re-group the whole list on every character; the
  // field text updates instantly, only the filter query is debounced.
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: ref.read(transactionSearchQueryProvider),
    );
  }

  void _onQueryChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) {
        ref.read(transactionSearchQueryProvider.notifier).state = value;
      }
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
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
      onChanged: _onQueryChanged,
      decoration: InputDecoration(
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        hintText: 'ابحث باسم متجر، تصنيف، مبلغ أو عملة',
        hintStyle: TextStyle(fontSize: 14, color: c.textMuted),
        prefixIconConstraints:
            const BoxConstraints(minWidth: 40, minHeight: 40),
        prefixIcon: const Icon(AppLucideIcons.search, size: 20),
        suffixIconConstraints:
            const BoxConstraints(minWidth: 40, minHeight: 40),
        suffixIcon: query.isEmpty
            ? null
            : IconButton(
                tooltip: 'مسح البحث',
                padding: EdgeInsets.zero,
                iconSize: 20,
                onPressed: () {
                  _searchDebounce?.cancel();
                  _controller.clear();
                  ref.read(transactionSearchQueryProvider.notifier).state = '';
                },
                icon: const Icon(AppLucideIcons.x),
              ),
        filled: true,
        fillColor: c.surface2.withValues(alpha: 0.45),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          borderSide: BorderSide(color: c.border.withValues(alpha: 0.4)),
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
    return GlassSelector(
      icon: AppLucideIcons.calendarDays,
      label: range.label,
      onTap: () {
        HapticFeedback.selectionClick();
        _showRangeSheet(context, ref, range);
      },
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
    return transactionsRangeForPreset(preset, customFallback: range);
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
      builder: (context) => navySheetTheme(StatefulBuilder(
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
                            trailing: const Icon(AppLucideIcons.calendarDays),
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
                            trailing: const Icon(AppLucideIcons.calendarDays),
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
                  const SizedBox(height: AppSpacing.s4),
                ],
              ),
            ),
          );
        },
      )),
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar();

  @override
  Widget build(BuildContext context) {
    return const SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      clipBehavior: Clip.none,
      child: Row(
        children: [
          _KindFilterChips(),
          SizedBox(width: 8),
          _PendingFilterChip(),
          SizedBox(width: 8),
          _CategoryFilterButton(),
        ],
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
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final entry in items.entries)
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 8),
            child: CalmChip(
              label: entry.value,
              selected: filter == entry.key,
              onTap: () => ref
                  .read(transactionKindFilterProvider.notifier)
                  .state = entry.key,
            ),
          ),
      ],
    );
  }
}

/// UX-016 — the missing «قيد المراجعة» filter.
///
/// The pending-only filter already existed and was reachable from exactly two
/// places, both OUTSIDE this screen: the Home banner and a notification tap.
/// On Transactions itself the app showed «1 قيد المراجعة» in the header, told
/// the user to review those items — «راجعها عشان أرصدتك تفضل مظبوطة» — and then
/// offered only الكل / مصروفات / دخل / تحويلات / التصنيف. It asked for a review
/// it gave no way to start. Fine at the QA's 34 rows; impossible at 500.
///
/// A separate toggle rather than a fifth kind chip, because pending is a
/// STATUS and the others are kinds: «مصروفات» and «قيد المراجعة» are a
/// meaningful combination, and making it a fifth kind would have made them
/// mutually exclusive. That also matches the existing provider, which ANDs
/// `pendingOnly` with the kind filter rather than replacing it.
class _PendingFilterChip extends ConsumerWidget {
  const _PendingFilterChip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(transactionsPendingFilterProvider);
    return CalmChip(
      label: 'قيد المراجعة',
      selected: active,
      onTap: () => ref.read(transactionsPendingFilterProvider.notifier).state =
          !active,
    );
  }
}

/// Opens a category picker; shows the selected category (icon + name) or a
/// neutral "التصنيف" placeholder when no category filter is active.
class _CategoryFilterButton extends ConsumerWidget {
  const _CategoryFilterButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final selectedId = ref.watch(transactionCategoryFilterProvider);
    final catalog = ref.watch(categoryCatalogProvider).valueOrNull;
    final selected = catalog?.byId(selectedId);
    final active = selectedId != null;

    return Material(
      color: active ? c.cta.withValues(alpha: 0.12) : c.surfaceElevated,
      borderRadius: BorderRadius.circular(AppRadius.pill),
      child: InkWell(
        onTap: () => _showCategoryFilterSheet(context, ref),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: Border.all(
              color: active ? c.cta.withValues(alpha: 0.3) : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CategoryGlyph(
                  name: selected?.iconName ?? 'shapes',
                  size: 15,
                  color: active ? c.cta : c.textSecondary),
              const SizedBox(width: 6),
              Text(
                selected?.nameAr ?? 'التصنيف',
                style: AppTypography.caption(active ? c.cta : c.textSecondary)
                    .copyWith(fontWeight: FontWeight.bold),
              ),
              if (active) ...[
                const SizedBox(width: 4),
                GestureDetector(
                  onTap: () => ref
                      .read(transactionCategoryFilterProvider.notifier)
                      .state = null,
                  child: Icon(AppLucideIcons.x, size: 14, color: c.cta),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showCategoryFilterSheet(
      BuildContext context, WidgetRef ref) async {
    final catalog = await ref.read(categoryCatalogProvider.future);
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => navySheetTheme(_CategoryFilterSheet(catalog: catalog)),
    );
  }
}

class _CategoryFilterSheet extends ConsumerWidget {
  const _CategoryFilterSheet({required this.catalog});

  final CategoryCatalog catalog;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final selectedId = ref.watch(transactionCategoryFilterProvider);
    // قايمة رأسية بدل شبكة حبوب مبعثرة: كل تصنيف في سطر بعرض واحد —
    // التايل، الاسم، وعلامة صح على المختار.
    return AppSheetScaffold(
      title: 'تصفية حسب التصنيف',
      scrollable: true,
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
        child: Container(
          decoration: BoxDecoration(
            color: c.surfaceElevated,
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: c.divider),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              _CategoryFilterRow(
                label: 'كل التصنيفات',
                selected: selectedId == null,
                leading: AppAvatar.icon(
                  icon: AppLucideIcons.shapes,
                  color: c.primary,
                  size: AppSpacing.avatarSm,
                ),
                onTap: () {
                  ref.read(transactionCategoryFilterProvider.notifier).state =
                      null;
                  Navigator.of(context).pop();
                },
              ),
              for (final cat in catalog.all) ...[
                Divider(height: 1, thickness: 1, color: c.divider),
                _CategoryFilterRow(
                  label: cat.nameAr,
                  selected: selectedId == cat.id,
                  leading: AppAvatar.category(
                    category: cat,
                    size: AppSpacing.avatarSm,
                  ),
                  onTap: () {
                    ref.read(transactionCategoryFilterProvider.notifier).state =
                        cat.id;
                    Navigator.of(context).pop();
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _CategoryFilterRow extends StatelessWidget {
  const _CategoryFilterRow({
    required this.label,
    required this.selected,
    required this.leading,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final Widget leading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: selected ? c.primary.withValues(alpha: 0.12) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.s3, vertical: AppSpacing.s2),
          child: Row(
            children: [
              leading,
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: selected
                      ? AppTypography.subhead(c.textMain)
                      : AppTypography.callout(c.textMain),
                ),
              ),
              if (selected)
                Icon(AppLucideIcons.check, size: 18, color: c.primary),
            ],
          ),
        ),
      ),
    );
  }
}

class _BillsTab extends StatefulWidget {
  const _BillsTab({
    required this.view,
    required this.currencyLabel,
    required this.baseCurrency,
  });

  final BillsView view;
  final String currencyLabel;
  final String baseCurrency;

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
    // F-027 — this used `monthlyEquivalentsTotalMoney`, which applies NO status
    // filter, so a paused subscription was still billed into the total here
    // while the Subscriptions screen (using `subscriptionMonthlyTotalMoney`)
    // correctly excluded it. Two surfaces, one label, different numbers.
    //
    // It also derived the target currency from `bills.first`, so the total
    // depended on list ORDER and every bill in a different currency was silently
    // dropped from it — with no indication to the user. The base currency is now
    // passed in explicitly.
    final monthlyTotal = _type == BillType.subscription
        ? subscriptionMonthlyTotalMoney(bills, widget.baseCurrency).toDouble()
        : monthlyEquivalentsTotalMoney(
            bills.where((b) => b.status == BillStatus.active),
            widget.baseCurrency,
          ).toDouble();
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
          icon: AppLucideIcons.plus,
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
        const SizedBox(height: AppSpacing.s4),
        TextButton.icon(
          onPressed: () => _showBillsHelp(context, _type),
          icon: const Icon(AppLucideIcons.helpCircle, size: 18),
          label: const Text('اعرف أكثر عن الفواتير'),
        ),
        const SizedBox(height: AppSpacing.s3),
        if (bills.isEmpty)
          AppEmptyState(
            icon: _type == BillType.subscription
                ? AppLucideIcons.repeat
                : AppLucideIcons.receipt,
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
      builder: (context) => navySheetTheme(Directionality(
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
                style: AppTypography.cardTitle(c.textMain),
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
      )),
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
    // سطح ink زي زرار «إضافة اشتراك» — الأزرق محفوظ للهيدر والأكسنت.
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s4),
      decoration: BoxDecoration(
        color: c.ink,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: c.onInk.withValues(alpha: 0.12)),
        boxShadow: [
          BoxShadow(
            color: c.ink.withValues(alpha: 0.20),
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
                style: AppTypography.caption(c.onInk.withValues(alpha: 0.72)),
              ),
              const Spacer(),
              Icon(
                isSubscription ? AppLucideIcons.repeat : AppLucideIcons.receipt,
                color: c.onInk.withValues(alpha: 0.72),
                size: 18,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${Formatters.amount(monthlyTotal)} $currencyLabel',
            style: AppTypography.title1(c.onInk)
                .copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: AppSpacing.s4),
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.s3, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.card),
              border: Border.all(color: c.onInk.withValues(alpha: 0.18)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: _HeroMetric(value: '$activeCount', label: 'نشط'),
                ),
                _Divider(color: c.onInk.withValues(alpha: 0.25)),
                Expanded(
                  child: _HeroMetric(
                    value:
                        '${Formatters.integer(monthlyTotal * 12)} $currencyLabel',
                    label: 'سنويًا',
                  ),
                ),
                if (isSubscription) ...[
                  _Divider(color: c.onInk.withValues(alpha: 0.25)),
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
    final c = context.colors;
    return Column(
      children: [
        Text(value, style: AppTypography.bodyStrong(c.onInk)),
        const SizedBox(height: 2),
        Text(
          label,
          style: AppTypography.caption(c.onInk.withValues(alpha: 0.72)),
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
                            ),
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
                          Icon(AppLucideIcons.banknote,
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
                AppAvatar.brand(name: suggestion.name),
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
                      '${Formatters.amount(suggestion.estimatedAmountMoney.toDouble())} $currencyLabel/شهر',
                      style: AppTypography.caption(c.textMain).copyWith(
                        fontWeight: FontWeight.bold,
                      ),
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
      padding: const EdgeInsets.only(
          top: AppSpacing.s2, bottom: AppSpacing.s2, right: 4),
      child: Text(
        label,
        textAlign: TextAlign.start,
        style: AppTypography.caption(c.textMuted)
            .copyWith(fontWeight: FontWeight.w600),
      ),
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
    // Shared design-system header — edit CalmPageHeader once, every screen
    // that uses it updates.
    return CalmPageHeader(
      // شرائح متعددة: الأزرق ميمتدّش تحت (هيغطّي المحتوى) — الذوبان جوّه.
      meltOverflow: 0,
      title: tab == 0 ? 'العمليات' : 'الفواتير والاشتراكات',
      subtitle:
          tab == 0 ? 'إجمالي مصروفات الفترة' : 'إجمالي الصرف الشهري النشط',
      leading: Navigator.of(context).canPop()
          ? const BackButton(color: Colors.white)
          : null,
      trailing: _AddButton(onTap: onAdd),
      amount: Formatters.amount(tab == 0 ? expenseTotal : monthlyTotal),
      currency: currencyLabel,
      metrics: tab == 0
          ? [
              CalmMetric(label: 'عملية للفترة', value: '$transactionsCount'),
              CalmMetric(label: 'قيد المراجعة', value: '$pendingCount'),
              CalmMetric(
                label: 'إجمالي المصروف',
                value: '${Formatters.amount(expenseTotal)} $currencyLabel',
              ),
            ]
          : [
              CalmMetric(label: 'اشتراك نشط', value: '$subsCount'),
              CalmMetric(label: 'قسط جاري', value: '$instsCount'),
              CalmMetric(
                label: 'المجموع سنوياً',
                value: '${Formatters.amount(monthlyTotal * 12)} $currencyLabel',
              ),
            ],
    );
  }
}

// ─── Smart Inbox ─────────────────────────────────────────────────────────────

class _SmartInboxBanner extends ConsumerWidget {
  const _SmartInboxBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(smartInboxItemsProvider).valueOrNull ?? const [];
    if (items.isEmpty) return const SizedBox.shrink();
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s3),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _SmartInboxSheet.show(context),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: c.cta.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: c.cta.withValues(alpha: 0.22)),
          ),
          child: Row(
            children: [
              Icon(AppLucideIcons.sparkles, size: 17, color: c.cta),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'صندوق المراجعة الذكي · ${items.length}',
                  style: AppTypography.caption(c.textMain)
                      .copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              Icon(AppLucideIcons.chevronLeft, size: 18, color: c.cta),
            ],
          ),
        ),
      ),
    );
  }
}

class _SmartInboxSheet extends ConsumerWidget {
  const _SmartInboxSheet();

  static Future<void> show(BuildContext context) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        backgroundColor: context.colors.surface,
        builder: (_) => navySheetTheme(const Directionality(
          textDirection: TextDirection.rtl,
          child: _SmartInboxSheet(),
        )),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(smartInboxItemsProvider).valueOrNull ?? const [];
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.58,
      maxChildSize: 0.9,
      builder: (_, controller) => ListView.separated(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        itemCount: items.length + 1,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'صندوق المراجعة الذكي',
                style: AppTypography.sectionTitle(context.colors.textMain),
              ),
            );
          }
          return _SmartInboxCard(item: items[index - 1]);
        },
      ),
    );
  }
}

class _SmartInboxCard extends ConsumerWidget {
  const _SmartInboxCard({required this.item});
  final SmartInboxItemEntity item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(item.title, style: AppTypography.bodyStrong(c.textMain)),
          if (item.body?.isNotEmpty == true) ...[
            const SizedBox(height: 5),
            Text(item.body!, style: AppTypography.caption(c.textMuted)),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              if (item.transactionId != null)
                TextButton(
                  onPressed: () => TransactionDetailsScreen.showSheet(
                    context,
                    item.transactionId!,
                  ),
                  child: const Text('راجع العملية'),
                ),
              const Spacer(),
              IconButton(
                tooltip: 'إخفاء',
                icon: const Icon(AppLucideIcons.x),
                onPressed: () async {
                  await ref.read(smartInboxRepositoryProvider).dismiss(item.id);
                  ref.invalidate(smartInboxItemsProvider);
                },
              ),
            ],
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
              Icon(AppLucideIcons.copy, size: 16, color: c.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${dupes.length} ${dupes.length == 1 ? 'عملية مشبوهة' : 'عمليات مشبوهة'} — اضغط للمراجعة',
                  style: AppTypography.caption(c.accent)
                      .copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              Icon(AppLucideIcons.chevronLeft, size: 16, color: c.accent),
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
    builder: (_) => navySheetTheme(Directionality(
      textDirection: TextDirection.rtl,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        child: _SuspectedDuplicateCard(dupe: dupe),
      ),
    )),
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
      builder: (_) => navySheetTheme(const Directionality(
        textDirection: TextDirection.rtl,
        child: _SuspectedDuplicatesSheet(),
      )),
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
                      style: AppTypography.sectionTitle(c.textMain)),
                ),
                // NEW (Phase J §13) — «تجاهل الكل» dismissed the ENTIRE review
                // queue on one tap: no count, no confirmation, no undo. It is
                // the same shape as UX-027 and F-017 — the most destructive
                // action being the easiest to reach — and it is worse here
                // because it is a bulk action whose size the user cannot see
                // from the button.
                //
                // It discards duplicate FLAGS rather than transactions, so no
                // money is lost; what is lost is the queue that would have
                // caught a genuine double charge. The confirmation states the
                // count and what dismissing actually means.
                TextButton(
                  onPressed: () async {
                    final proceed = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: Text('تجاهل ${dupes.length} تنبيه؟'),
                        content: const Text(
                          'هتتشال كل تنبيهات التكرار المعروضة. العمليات نفسها '
                          'مش هتتأثر، لكن مش هينفع تراجعها من هنا تاني.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(false),
                            child: const Text('إلغاء'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(true),
                            child: Text('تجاهل الكل',
                                style: TextStyle(color: ctx.colors.danger)),
                          ),
                        ],
                      ),
                    );
                    if (proceed != true) return;
                    final repo = ref.read(suspectedDuplicateRepositoryProvider);
                    for (final d in dupes) {
                      await repo.delete(d.id);
                    }
                    ref.invalidate(suspectedDuplicatesProvider);
                    if (context.mounted) Navigator.of(context).pop();
                  },
                  child: Text('تجاهل الكل (${dupes.length})',
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
              Icon(AppLucideIcons.copy, size: 18, color: c.warning),
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
                  icon: const Icon(AppLucideIcons.pencil, size: 16),
                  label: const Text('تعديل العملية'),
                ),
              ),
              const SizedBox(width: AppSpacing.s2),
              Expanded(
                child: TextButton.icon(
                  onPressed: existing == null
                      ? null
                      : () => _changeCategory(context, ref, existing),
                  icon: const Icon(AppLucideIcons.shapes, size: 16),
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
