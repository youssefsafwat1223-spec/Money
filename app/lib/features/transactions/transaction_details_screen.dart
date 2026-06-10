import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/transaction_entity.dart';
import '../common/category_catalog.dart';
import '../common/widgets.dart';
import 'transactions_providers.dart';
import 'widgets/change_category_sheet.dart';

class TransactionDetailsScreen extends ConsumerWidget {
  const TransactionDetailsScreen({super.key, required this.transactionId});

  final String transactionId;

  static const _typeLabels = {
    TransactionTypeEntity.payment: 'شراء',
    TransactionTypeEntity.withdrawal: 'سحب نقدي',
    TransactionTypeEntity.transfer: 'تحويل',
    TransactionTypeEntity.refund: 'استرداد',
    TransactionTypeEntity.income: 'دخل',
    TransactionTypeEntity.unknown: 'غير محدد',
  };

  static const _sourceLabels = {
    TransactionSourceEntity.bank: 'بنك',
    TransactionSourceEntity.card: 'بطاقة',
    TransactionSourceEntity.wallet: 'محفظة',
    TransactionSourceEntity.unknown: 'غير محدد',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final txAsync = ref.watch(transactionByIdProvider(transactionId));
    final catalog = ref.watch(categoryCatalogProvider).valueOrNull;

    return Scaffold(
      appBar: AppBar(title: const Text('تفاصيل العملية')),
      body: txAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('حدث خطأ: $e')),
        data: (tx) {
          if (tx == null) {
            return const Center(child: Text('العملية غير موجودة'));
          }
          final category = catalog?.byId(tx.categoryId);
          return ListView(
            padding: const EdgeInsets.all(AppSpacing.gutter),
            children: [
              Center(
                child: Column(
                  children: [
                    CategoryAvatar(category: category, size: 64),
                    const SizedBox(height: AppSpacing.s3),
                    Text('${Formatters.amount(tx.amount)} ${tx.currency}',
                        style: AppTypography.amountHero(c.textMain)),
                    if (tx.rawMerchant != null)
                      Text(tx.rawMerchant!,
                          style: AppTypography.headline(c.textMain)),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.s6),
              _row(context, 'التصنيف', category?.nameAr ?? 'غير مصنّف',
                  trailing: TextButton(
                    onPressed: catalog == null
                        ? null
                        : () => showChangeCategorySheet(context, tx, catalog),
                    child:
                        Text('تغيير', style: AppTypography.subhead(c.primary)),
                  )),
              _row(context, 'النوع', _typeLabels[tx.type] ?? '—'),
              _row(context, 'المصدر',
                  '${_sourceLabels[tx.source] ?? '—'}${tx.cardLast4 != null ? ' · ${tx.cardLast4}' : ''}'),
              _row(context, 'التاريخ',
                  '${Formatters.fullDate(tx.occurredAt)} · ${Formatters.time(tx.occurredAt)}'),
              if (tx.balanceAfter != null)
                _row(context, 'الرصيد بعد',
                    '${Formatters.amount(tx.balanceAfter!)} ${tx.currency}'),
              if (tx.status == TransactionStatus.pending)
                _row(context, 'الحالة', 'غير مؤكدة'),
              const SizedBox(height: AppSpacing.s4),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text('النص الأصلي',
                    style: AppTypography.subhead(c.textLight)),
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(AppSpacing.s3),
                    decoration: BoxDecoration(
                      color: c.surface2,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                    child: Text(tx.rawMessage,
                        style: AppTypography.footnote(c.textMain)),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _row(BuildContext context, String label, String value,
      {Widget? trailing}) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.s3),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(label, style: AppTypography.subhead(c.textLight)),
          ),
          Expanded(
            child: Text(value, style: AppTypography.body(c.textMain)),
          ),
          if (trailing != null) trailing,
        ],
      ),
    );
  }
}
