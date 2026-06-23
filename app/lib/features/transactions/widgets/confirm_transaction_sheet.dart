import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/currency.dart';
import '../../../core/utils/formatters.dart';
import '../../../domain/entities/transaction_entity.dart';
import '../../common/app_sheet_scaffold.dart';
import '../../common/category_catalog.dart';
import '../../common/widgets.dart';
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

class _ConfirmSheet extends ConsumerWidget {
  const _ConfirmSheet({required this.transactionId});

  final String transactionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final txAsync = ref.watch(transactionByIdProvider(transactionId));
    final catalogAsync = ref.watch(categoryCatalogProvider);

    final tx = txAsync.valueOrNull;
    final catalog = catalogAsync.valueOrNull;
    if (tx == null || catalog == null) {
      return const SizedBox(
          height: 200, child: Center(child: CircularProgressIndicator()));
    }
    final category = catalog.byId(tx.categoryId);
    final isNewMerchant = tx.rawMerchant != null;

    return AppSheetScaffold(
      title: 'عملية جديدة',
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${Formatters.amount(tx.amount)} ${tx.currency}',
              style: AppTypography.amountHero(c.textMain)),
          if (tx.rawMerchant != null) ...[
            const SizedBox(height: 4),
            Text(tx.rawMerchant!,
                style: AppTypography.headline(c.textMain)),
          ],
          const SizedBox(height: AppSpacing.s4),
          // التصنيف المقترح (قابل للتغيير)
          InkWell(
            onTap: () => showChangeCategorySheet(context, tx, catalog),
            borderRadius: BorderRadius.circular(16),
            child: Container(
              padding: const EdgeInsets.all(AppSpacing.s3),
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.05)
                    : c.surface2.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: Colors.white
                      .withValues(alpha: isDark ? 0.08 : 0.4),
                ),
              ),
              child: Row(
                children: [
                  CategoryAvatar(category: category, size: 40),
                  const SizedBox(width: AppSpacing.s3),
                  Expanded(
                    child: Text(category?.nameAr ?? 'غير مصنّف',
                        style: AppTypography.bodyStrong(c.textMain)),
                  ),
                  Text('تغيير',
                      style: AppTypography.subhead(c.primary)),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s3),
          Text(
            '${Formatters.fullDate(tx.occurredAt, context)} · ${Formatters.time(tx.occurredAt)}'
            '${tx.cardLast4 != null ? ' · بطاقة ${tx.cardLast4}' : ''}',
            style: AppTypography.footnote(c.textLight),
          ),
          if (isNewMerchant) ...[
            const SizedBox(height: AppSpacing.s3),
            Text('متجر جديد — سنتذكّره لك',
                style: AppTypography.caption(c.primary)),
          ],
          ref.watch(accountsProvider).maybeWhen(
                data: (accounts) {
                  if (accounts.length < 2) {
                    return const SizedBox.shrink();
                  }
                  final value =
                      accounts.any((a) => a.id == tx.accountId)
                          ? tx.accountId
                          : accounts.first.id;
                  return Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.s4),
                    child: DropdownButtonFormField<String>(
                      value: value,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'الحساب',
                        prefixIcon:
                            Icon(Icons.account_balance_wallet_outlined),
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
                        ref.invalidate(
                            transactionByIdProvider(transactionId));
                        ref.invalidate(dashboardDataProvider);
                      },
                    ),
                  );
                },
                orElse: () => const SizedBox.shrink(),
              ),
          const SizedBox(height: AppSpacing.s5),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: OutlinedButton.icon(
              onPressed: () async {
                await ManualTransactionSheet.show(
                  context,
                  transaction: tx,
                );
                if (!context.mounted) return;
                ref.invalidate(transactionByIdProvider(transactionId));
                refreshTransactions(ref);
                ref.invalidate(dashboardDataProvider);
              },
              icon: const Icon(Icons.edit_outlined),
              label: const Text('تعديل التفاصيل'),
            ),
          ),
          const SizedBox(height: AppSpacing.s2),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: FilledButton(
              onPressed: () async {
                if (tx.status == TransactionStatus.pending) {
                  await ref.read(
                      confirmTransactionUseCaseProvider)(tx.id);
                }
                refreshTransactions(ref);
                ref.invalidate(dashboardDataProvider);
                if (context.mounted) Navigator.of(context).pop();
              },
              style: FilledButton.styleFrom(
                backgroundColor: c.primary,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
              ),
              child: Text('تأكيد',
                  style: AppTypography.bodyStrong(Colors.white)),
            ),
          ),
        ],
      ),
    );
  }
}
