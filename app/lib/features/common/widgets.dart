import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/transaction_entity.dart';
import 'category_catalog.dart';

/// دائرة أيقونة تصنيف بلون التصنيف الخفيف.
class CategoryAvatar extends StatelessWidget {
  const CategoryAvatar({super.key, required this.category, this.size = 44});

  final CategoryView? category;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = category?.color ?? c.textLight;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Icon(
        category?.icon ?? AppLucideIcons.shapes,
        color: color,
        size: size * 0.46,
      ),
    );
  }
}

/// صف عملية في القوائم.
class TransactionRow extends StatelessWidget {
  const TransactionRow({
    super.key,
    required this.transaction,
    required this.category,
    this.onTap,
  });

  final TransactionEntity transaction;
  final CategoryView? category;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isIncome = transaction.type == TransactionTypeEntity.income ||
        transaction.type == TransactionTypeEntity.refund;
    final amountColor = isIncome ? c.success : c.textMain;
    final pending = transaction.status == TransactionStatus.pending;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.s2),
        child: Row(
          children: [
            CategoryAvatar(category: category),
            const SizedBox(width: AppSpacing.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          transaction.rawMerchant ??
                              category?.nameAr ??
                              'عملية',
                          style: AppTypography.bodyStrong(c.textMain),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (pending) ...[
                        const SizedBox(width: AppSpacing.s2),
                        Icon(
                          AppLucideIcons.alertTriangle,
                          size: 15,
                          color: c.accent,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${category?.nameAr ?? '—'} · ${Formatters.time(transaction.occurredAt)}',
                    style: AppTypography.caption(c.textLight),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.s2),
            Text(
              '${Formatters.signed(transaction.amount, isExpense: !isIncome)} ${transaction.currency}',
              style: AppTypography.bodyStrong(amountColor),
            ),
          ],
        ),
      ),
    );
  }
}
