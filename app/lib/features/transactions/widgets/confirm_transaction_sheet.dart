import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/app_lucide_icons.dart';
import '../../../core/utils/currency.dart';
import '../../../core/utils/formatters.dart';
import '../../../domain/entities/transaction_entity.dart';
import '../../common/app_sheet_scaffold.dart';
import '../../common/app_category_chip.dart';
import '../../common/app_button.dart';
import '../../common/category_catalog.dart';
import '../../dashboard/dashboard_providers.dart';
import '../manual_transaction_sheet.dart';
import '../transactions_providers.dart';
import 'change_category_sheet.dart';

Future<void> showConfirmTransactionSheet(
  BuildContext context,
  String transactionId,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _ConfirmSheet(transactionId: transactionId),
  );
}

class _ConfirmSheet extends ConsumerStatefulWidget {
  const _ConfirmSheet({required this.transactionId});

  final String transactionId;

  @override
  ConsumerState<_ConfirmSheet> createState() => _ConfirmSheetState();
}

class _ConfirmSheetState extends ConsumerState<_ConfirmSheet> {
  String? _selectedCategoryKey;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final txAsync = ref.watch(transactionByIdProvider(widget.transactionId));
    final catalogAsync = ref.watch(categoryCatalogProvider);

    final tx = txAsync.valueOrNull;
    final catalog = catalogAsync.valueOrNull;
    if (tx == null || catalog == null) {
      return const SizedBox(
          height: 200, child: Center(child: CircularProgressIndicator()));
    }
    
    final categoryKey = _selectedCategoryKey ?? tx.categoryId;
    final category = catalog.byId(categoryKey);
    final isNewMerchant = tx.rawMerchant != null;

    return AppSheetScaffold(
      title: 'مراجعة العملية',
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Amount + Badge
          Text('${Formatters.amount(tx.amount)} ${tx.currency}',
              style: AppTypography.amountHero(c.textMain)),
          const SizedBox(height: AppSpacing.s2),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: c.accent.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(AppLucideIcons.sparkles, size: 14, color: c.accent),
                const SizedBox(width: 6),
                Text('قيد المراجعة',
                    style: AppTypography.caption(c.accent)
                        .copyWith(fontWeight: FontWeight.w700)),
              ],
            ),
          ),
          if (tx.rawMerchant != null) ...[
            const SizedBox(height: AppSpacing.s4),
            Text(tx.rawMerchant!,
                style: AppTypography.headline(c.textMain)),
          ],
          
          const SizedBox(height: AppSpacing.s4),
          
          // Inline Category Quick-Pick
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text('التصنيف:', style: AppTypography.caption(c.textLight)),
          ),
          const SizedBox(height: AppSpacing.s2),
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final cat in catalog.all.where((it) => it.key != 'income' && it.key != 'all_expenses'))
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: AppCategoryChip(
                      label: cat.nameAr,
                      icon: AppLucideIcons.tag,
                      color: cat.key == categoryKey ? c.primary : c.textLight,
                      selected: cat.key == categoryKey,
                      onTap: () {
                        setState(() {
                          _selectedCategoryKey = cat.key;
                        });
                        // Update transaction category quietly
                        ref.read(transactionRepositoryProvider).updateCategory(
                          transactionId: tx.id,
                          categoryId: cat.key,
                        ).then((_) {
                          ref.invalidate(transactionByIdProvider(tx.id));
                        });
                      },
                    ),
                  ),
              ],
            ),
          ),
          
          const SizedBox(height: AppSpacing.s4),
          
          // Account & Date Inline Row
          Container(
            padding: const EdgeInsets.all(AppSpacing.s3),
            decoration: BoxDecoration(
              color: c.surface2.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: c.border),
            ),
            child: Row(
              children: [
                Icon(AppLucideIcons.calendarDays, size: 18, color: c.textLight),
                const SizedBox(width: AppSpacing.s2),
                Expanded(
                  child: Text(
                    '${Formatters.fullDate(tx.occurredAt, context)} · ${Formatters.time(tx.occurredAt)}',
                    style: AppTypography.caption(c.textMain),
                  ),
                ),
                if (tx.cardLast4 != null) ...[
                  Container(width: 1, height: 16, color: c.border, margin: const EdgeInsets.symmetric(horizontal: 8)),
                  Text('بطاقة ${tx.cardLast4}', style: AppTypography.caption(c.textLight)),
                ],
              ],
            ),
          ),
          
          ref.watch(accountsProvider).maybeWhen(
            data: (accounts) {
              if (accounts.length < 2) return const SizedBox.shrink();
              final value = accounts.any((a) => a.id == tx.accountId)
                  ? tx.accountId
                  : accounts.first.id;
              return Padding(
                padding: const EdgeInsets.only(top: AppSpacing.s3),
                child: DropdownButtonFormField<String>(
                  value: value,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: 'الحساب',
                    prefixIcon: const Icon(AppLucideIcons.walletCards),
                    filled: true,
                    fillColor: c.surface2.withValues(alpha: 0.5),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide(color: c.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide(color: c.border),
                    ),
                  ),
                  items: [
                    for (final account in accounts)
                      DropdownMenuItem(
                        value: account.id,
                        child: Text(
                          '${account.name} · ${Currency.arabicLabel(account.currency)}',
                        ),
                      ),
                  ],
                  onChanged: (id) async {
                    if (id == null) return;
                    await ref
                        .read(transactionRepositoryProvider)
                        .updateAccount(
                          transactionId: tx.id,
                          accountId: id,
                        );
                    ref.invalidate(transactionByIdProvider(widget.transactionId));
                    ref.invalidate(dashboardDataProvider);
                  },
                ),
              );
            },
            orElse: () => const SizedBox.shrink(),
          ),
          
          const SizedBox(height: AppSpacing.s5),
          
          AppButton(
            label: 'تأكيد العملية',
            onPressed: () async {
              if (tx.status == TransactionStatus.pending) {
                await ref.read(confirmTransactionUseCaseProvider)(tx.id);
              }
              refreshTransactions(ref);
              ref.invalidate(dashboardDataProvider);
              if (context.mounted) Navigator.of(context).pop();
            },
            isPrimary: true,
          ),
          const SizedBox(height: AppSpacing.s2),
          AppButton(
            label: 'تعديل التفاصيل',
            onPressed: () async {
              await ManualTransactionSheet.show(
                context,
                transaction: tx,
              );
              if (!context.mounted) return;
              ref.invalidate(transactionByIdProvider(widget.transactionId));
              refreshTransactions(ref);
              ref.invalidate(dashboardDataProvider);
            },
            isPrimary: false,
          ),
        ],
      ),
    );
  }
}
