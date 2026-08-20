import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/glass_selector.dart';
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
    // The mockup `.selectors` row: two glass selectors side by side, gap 10.
    return Row(
      children: [
        if (showAccount) ...[
          Expanded(child: _AccountPicker(onChanged: onAccountChanged)),
          if (showRange) const SizedBox(width: 10),
        ],
        if (showRange)
          Expanded(child: _DateRangeChips(onChanged: onRangeChanged)),
      ],
    );
  }
}

class _AccountPicker extends ConsumerWidget {
  const _AccountPicker({this.onChanged});

  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // valueOrNull (not maybeWhen/when) so the chip keeps showing the current
    // account while accountsProvider is reloading — otherwise a reload collapses
    // it to SizedBox.shrink() and back, which is the account-switch flicker.
    final accounts = ref.watch(accountsProvider).valueOrNull;
    final selectedId = ref.watch(activeAccountIdProvider);
    if (accounts == null || accounts.isEmpty) return const SizedBox.shrink();
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
                      ? Icon(AppLucideIcons.checkCircle, color: c.cta)
                      : null,
                  onTap: () async {
                    HapticFeedback.selectionClick();
                    Navigator.of(context).pop();
                    container.read(activeAccountIdProvider.notifier).state =
                        account.id;
                    await container
                        .read(accountRepositoryProvider)
                        .setDefault(account.id);
                    // No explicit invalidate: setDefault ticks dbRevision and
                    // the active-account change already rebuilds accounts/
                    // baseCurrency, and invalidating would blank them (flicker).
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

    return GlassSelector(
      icon: AppLucideIcons.calendarDays,
      label: range.label,
      onTap: () {
        HapticFeedback.selectionClick();
        _showRangeSheet(context, ref, range);
      },
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
