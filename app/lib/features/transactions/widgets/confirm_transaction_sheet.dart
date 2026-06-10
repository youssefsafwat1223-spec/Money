import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../domain/entities/transaction_entity.dart';
import '../../common/category_catalog.dart';
import '../../common/widgets.dart';
import '../../dashboard/dashboard_providers.dart';
import '../transactions_providers.dart';
import 'change_category_sheet.dart';

Future<void> showConfirmTransactionSheet(
  BuildContext context,
  String transactionId,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
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

    return Container(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter, AppSpacing.s3, AppSpacing.gutter, AppSpacing.s6),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
                color: c.border, borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(height: AppSpacing.s4),
          Text('عملية جديدة', style: AppTypography.subhead(c.textLight)),
          const SizedBox(height: AppSpacing.s2),
          Text('${Formatters.amount(tx.amount)} ${tx.currency}',
              style: AppTypography.amountHero(c.textMain)),
          if (tx.rawMerchant != null) ...[
            const SizedBox(height: 4),
            Text(tx.rawMerchant!, style: AppTypography.headline(c.textMain)),
          ],
          const SizedBox(height: AppSpacing.s4),
          // التصنيف المقترح (قابل للتغيير)
          InkWell(
            onTap: () => showChangeCategorySheet(context, tx, catalog),
            borderRadius: BorderRadius.circular(AppRadius.md),
            child: Container(
              padding: const EdgeInsets.all(AppSpacing.s3),
              decoration: BoxDecoration(
                color: c.surface2,
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: Border.all(color: c.border),
              ),
              child: Row(
                children: [
                  CategoryAvatar(category: category, size: 40),
                  const SizedBox(width: AppSpacing.s3),
                  Expanded(
                    child: Text(category?.nameAr ?? 'غير مصنّف',
                        style: AppTypography.bodyStrong(c.textMain)),
                  ),
                  Text('تغيير', style: AppTypography.subhead(c.primary)),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s3),
          Text(
            '${Formatters.fullDate(tx.occurredAt)} · ${Formatters.time(tx.occurredAt)}'
            '${tx.cardLast4 != null ? ' · بطاقة ${tx.cardLast4}' : ''}',
            style: AppTypography.footnote(c.textLight),
          ),
          if (isNewMerchant) ...[
            const SizedBox(height: AppSpacing.s3),
            Text('متجر جديد — سنتذكّره لك',
                style: AppTypography.caption(c.primary)),
          ],
          const SizedBox(height: AppSpacing.s5),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 54,
                  child: FilledButton(
                    onPressed: () async {
                      if (tx.status == TransactionStatus.pending) {
                        await ref
                            .read(confirmTransactionUseCaseProvider)(tx.id);
                      }
                      refreshTransactions(ref);
                      ref.invalidate(dashboardDataProvider);
                      if (context.mounted) Navigator.of(context).pop();
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: c.primary,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppRadius.md)),
                    ),
                    child: Text('تأكيد',
                        style: AppTypography.bodyStrong(Colors.white)),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
