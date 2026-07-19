import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/account_entity.dart';
import '../transactions/transactions_providers.dart';
import 'app_sheet_scaffold.dart';

class AccountRangeControls extends ConsumerWidget {
  const AccountRangeControls({
    super.key,
    this.showAccount = true,
    this.showRange = true,
    this.onAccountChanged,
    this.onRangeChanged,
  });

  final bool showAccount;
  final bool showRange;
  final VoidCallback? onAccountChanged;
  final VoidCallback? onRangeChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!showAccount && !showRange) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showAccount) ...[
          _AccountPicker(onChanged: onAccountChanged),
          if (showRange) const SizedBox(height: AppSpacing.s3),
        ],
        if (showRange) _DateRangeChips(onChanged: onRangeChanged),
      ],
    );
  }
}

class _AccountPicker extends ConsumerWidget {
  const _AccountPicker({this.onChanged});

  final VoidCallback? onChanged;

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
                constraints: const BoxConstraints(maxWidth: 280),
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
                    Flexible(
                      child: Text(
                        '${account.name} · ${Currency.arabicLabel(account.currency)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.caption(c.textPrimary)
                            .copyWith(fontWeight: FontWeight.w900),
                      ),
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
                    onChanged?.call();
                  },
                ),
            ],
          ),
        ),
      )),
    );
  }
}

class _DateRangeChips extends ConsumerWidget {
  const _DateRangeChips({this.onChanged});

  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final range = ref.watch(transactionsDateRangeProvider);
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

  String _label(TransactionsDatePreset preset) => switch (preset) {
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
    if (preset == TransactionsDatePreset.custom) {
      throw StateError('Pick custom range');
    }
    return transactionsRangeForPreset(preset);
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
                          label: Text(_label(preset)),
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
                            onChanged?.call();
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
                            onChanged?.call();
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
      )),
    );
  }
}
